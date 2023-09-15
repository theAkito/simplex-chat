{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module Simplex.Chat.Controller where

import Control.Concurrent (ThreadId)
import Control.Concurrent.Async (Async)
import Control.Exception
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Control.Monad.Reader
import Crypto.Random (ChaChaDRG)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.:?))
import qualified Data.Aeson as J
import qualified Data.Aeson.Types as JT
import qualified Data.Attoparsec.ByteString.Char8 as A
import Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import Data.Char (ord)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.String
import Data.Text (Text)
import Data.Time (NominalDiffTime)
import Data.Time.Clock (UTCTime)
import Data.Version (showVersion)
import GHC.Generics (Generic)
import Language.Haskell.TH (Exp, Q, runIO)
import Numeric.Natural
import qualified Paths_simplex_chat as SC
import Simplex.Chat.Call
import Simplex.Chat.Markdown (MarkdownList)
import Simplex.Chat.Messages
import Simplex.Chat.Messages.CIContent
import Simplex.Chat.Protocol
import Simplex.Chat.Store (AutoAccept, StoreError, UserContactLink, UserMsgReceiptSettings)
import Simplex.Chat.Types
import Simplex.Chat.Types.Preferences
import Simplex.Messaging.Agent (AgentClient, SubscriptionsInfo)
import Simplex.Messaging.Agent.Client (AgentLocks, ProtocolTestFailure)
import Simplex.Messaging.Agent.Env.SQLite (AgentConfig, NetworkConfig)
import Simplex.Messaging.Agent.Lock
import Simplex.Messaging.Agent.Protocol
import Simplex.Messaging.Agent.Store.SQLite (MigrationConfirmation, SQLiteStore, UpMigration)
import Simplex.Messaging.Agent.Store.SQLite.DB (SlowQueryStats (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Crypto.File (CryptoFile (..))
import qualified Simplex.Messaging.Crypto.File as CF
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Notifications.Protocol (DeviceToken (..), NtfTknStatus)
import Simplex.Messaging.Parsers (dropPrefix, enumJSON, parseAll, parseString, sumTypeJSON)
import Simplex.Messaging.Protocol (AProtoServerWithAuth, AProtocolType, CorrId, MsgFlags, NtfServer, ProtoServerWithAuth, ProtocolTypeI, QueueId, SProtocolType, SubscriptionMode (..), UserProtocol, XFTPServerWithAuth)
import Simplex.Messaging.TMap (TMap)
import Simplex.Messaging.Transport (simplexMQVersion)
import Simplex.Messaging.Transport.Client (TransportHost)
import Simplex.Messaging.Util (allFinally, catchAllErrors, tryAllErrors, (<$$>))
import Simplex.Messaging.Version
import System.IO (Handle)
import System.Mem.Weak (Weak)
import UnliftIO.STM

versionNumber :: String
versionNumber = showVersion SC.version

versionString :: String -> String
versionString ver = "SimpleX Chat v" <> ver

updateStr :: String
updateStr = "To update run: curl -o- https://raw.githubusercontent.com/simplex-chat/simplex-chat/master/install.sh | bash"

simplexmqCommitQ :: Q Exp
simplexmqCommitQ = do
  s <- either (const "") B.unpack . A.parseOnly commitHashP <$> runIO (B.readFile "./cabal.project")
  [|fromString s|]
  where
    commitHashP :: A.Parser ByteString
    commitHashP =
      A.manyTill' A.anyChar "location: https://github.com/simplex-chat/simplexmq.git"
        *> A.takeWhile (== ' ')
        *> A.endOfLine
        *> A.takeWhile (== ' ')
        *> "tag: "
        *> A.takeWhile (A.notInClass " \r\n")

coreVersionInfo :: String -> CoreVersionInfo
coreVersionInfo simplexmqCommit =
  CoreVersionInfo
    { version = versionNumber,
      simplexmqVersion = simplexMQVersion,
      simplexmqCommit
    }

data ChatConfig = ChatConfig
  { agentConfig :: AgentConfig,
    chatVRange :: VersionRange,
    confirmMigrations :: MigrationConfirmation,
    defaultServers :: DefaultAgentServers,
    tbqSize :: Natural,
    fileChunkSize :: Integer,
    xftpDescrPartSize :: Int,
    inlineFiles :: InlineFilesConfig,
    autoAcceptFileSize :: Integer,
    xftpFileConfig :: Maybe XFTPFileConfig, -- Nothing - XFTP is disabled
    tempDir :: Maybe FilePath,
    showReactions :: Bool,
    showReceipts :: Bool,
    subscriptionEvents :: Bool,
    hostEvents :: Bool,
    logLevel :: ChatLogLevel,
    testView :: Bool,
    initialCleanupManagerDelay :: Int64,
    cleanupManagerInterval :: NominalDiffTime,
    cleanupManagerStepDelay :: Int64,
    ciExpirationInterval :: Int64 -- microseconds
  }

data DefaultAgentServers = DefaultAgentServers
  { smp :: NonEmpty SMPServerWithAuth,
    ntf :: [NtfServer],
    xftp :: NonEmpty XFTPServerWithAuth,
    netCfg :: NetworkConfig
  }

data InlineFilesConfig = InlineFilesConfig
  { offerChunks :: Integer,
    sendChunks :: Integer,
    totalSendChunks :: Integer,
    receiveChunks :: Integer,
    receiveInstant :: Bool
  }

defaultInlineFilesConfig :: InlineFilesConfig
defaultInlineFilesConfig =
  InlineFilesConfig
    { offerChunks = 15, -- max when chunks are offered / received with the option - limited to 255 on the encoding level
      sendChunks = 6, -- max per file when chunks will be sent inline without acceptance
      totalSendChunks = 30, -- max per conversation when chunks will be sent inline without acceptance
      receiveChunks = 8, -- max when chunks are accepted
      receiveInstant = True -- allow receiving instant files, within receiveChunks limit
    }

data ActiveTo = ActiveNone | ActiveC ContactName | ActiveG GroupName
  deriving (Eq)

chatActiveTo :: ChatName -> ActiveTo
chatActiveTo (ChatName cType name) = case cType of
  CTDirect -> ActiveC name
  CTGroup -> ActiveG name
  _ -> ActiveNone

data ChatDatabase = ChatDatabase {chatStore :: SQLiteStore, agentStore :: SQLiteStore}

data ChatController = ChatController
  { satellideId :: TVar (Maybe SatIdentityId),
    currentUser :: TVar (Maybe User),
    activeTo :: TVar ActiveTo,
    firstTime :: Bool,
    smpAgent :: AgentClient,
    agentAsync :: TVar (Maybe (Async (), Maybe (Async ()))),
    chatStore :: SQLiteStore,
    chatStoreChanged :: TVar Bool, -- if True, chat should be fully restarted
    idsDrg :: TVar ChaChaDRG,
    inputQ :: TBQueue String,
    outputQ :: TBQueue (Maybe CorrId, ChatResponse),
    notifyQ :: TBQueue Notification,
    sendNotification :: Notification -> IO (),
    subscriptionMode :: TVar SubscriptionMode,
    chatLock :: Lock,
    sndFiles :: TVar (Map Int64 Handle),
    rcvFiles :: TVar (Map Int64 Handle),
    currentCalls :: TMap ContactId Call,
    config :: ChatConfig,
    filesFolder :: TVar (Maybe FilePath), -- path to files folder for mobile apps,
    expireCIThreads :: TMap UserId (Maybe (Async ())),
    expireCIFlags :: TMap UserId Bool,
    cleanupManagerAsync :: TVar (Maybe (Async ())),
    timedItemThreads :: TMap (ChatRef, ChatItemId) (TVar (Maybe (Weak ThreadId))),
    showLiveItems :: TVar Bool,
    userXFTPFileConfig :: TVar (Maybe XFTPFileConfig),
    tempDirectory :: TVar (Maybe FilePath),
    logFilePath :: Maybe FilePath
  }

data HelpSection = HSMain | HSFiles | HSGroups | HSContacts | HSMyAddress | HSIncognito | HSMarkdown | HSMessages | HSSettings | HSDatabase
  deriving (Show, Generic)

instance ToJSON HelpSection where
  toJSON = J.genericToJSON . enumJSON $ dropPrefix "HS"
  toEncoding = J.genericToEncoding . enumJSON $ dropPrefix "HS"

data ChatCommand
  = ShowActiveUser
  | CreateActiveUser NewUser
  | ListUsers
  | APISetActiveUser UserId (Maybe UserPwd)
  | SetActiveUser UserName (Maybe UserPwd)
  | SetAllContactReceipts Bool
  | APISetUserContactReceipts UserId UserMsgReceiptSettings
  | SetUserContactReceipts UserMsgReceiptSettings
  | APISetUserGroupReceipts UserId UserMsgReceiptSettings
  | SetUserGroupReceipts UserMsgReceiptSettings
  | APIHideUser UserId UserPwd
  | APIUnhideUser UserId UserPwd
  | APIMuteUser UserId
  | APIUnmuteUser UserId
  | HideUser UserPwd
  | UnhideUser UserPwd
  | MuteUser
  | UnmuteUser
  | APIDeleteUser UserId Bool (Maybe UserPwd)
  | DeleteUser UserName Bool (Maybe UserPwd)
  | StartChat {subscribeConnections :: Bool, enableExpireChatItems :: Bool, startXFTPWorkers :: Bool}
  | APIStopChat
  | APIActivateChat
  | APISuspendChat {suspendTimeout :: Int}
  | ResubscribeAllConnections
  | SetTempFolder FilePath
  | SetFilesFolder FilePath
  | APISetXFTPConfig (Maybe XFTPFileConfig)
  | APIExportArchive ArchiveConfig
  | ExportArchive
  | APIImportArchive ArchiveConfig
  | APIDeleteStorage
  | APIStorageEncryption DBEncryptionConfig
  | ExecChatStoreSQL Text
  | ExecAgentStoreSQL Text
  | SlowSQLQueries
  | APIGetChats {userId :: UserId, pendingConnections :: Bool}
  | APIGetChat ChatRef ChatPagination (Maybe String)
  | APIGetChatItems ChatPagination (Maybe String)
  | APIGetChatItemInfo ChatRef ChatItemId
  | APISendMessage {chatRef :: ChatRef, liveMessage :: Bool, ttl :: Maybe Int, composedMessage :: ComposedMessage}
  | APIUpdateChatItem {chatRef :: ChatRef, chatItemId :: ChatItemId, liveMessage :: Bool, msgContent :: MsgContent}
  | APIDeleteChatItem ChatRef ChatItemId CIDeleteMode
  | APIDeleteMemberChatItem GroupId GroupMemberId ChatItemId
  | APIChatItemReaction {chatRef :: ChatRef, chatItemId :: ChatItemId, add :: Bool, reaction :: MsgReaction}
  | APIChatRead ChatRef (Maybe (ChatItemId, ChatItemId))
  | APIChatUnread ChatRef Bool
  | APIDeleteChat ChatRef
  | APIClearChat ChatRef
  | APIAcceptContact IncognitoEnabled Int64
  | APIRejectContact Int64
  | APISendCallInvitation ContactId CallType
  | SendCallInvitation ContactName CallType
  | APIRejectCall ContactId
  | APISendCallOffer ContactId WebRTCCallOffer
  | APISendCallAnswer ContactId WebRTCSession
  | APISendCallExtraInfo ContactId WebRTCExtraInfo
  | APIEndCall ContactId
  | APIGetCallInvitations
  | APICallStatus ContactId WebRTCCallStatus
  | APIUpdateProfile UserId Profile
  | APISetContactPrefs ContactId Preferences
  | APISetContactAlias ContactId LocalAlias
  | APISetConnectionAlias Int64 LocalAlias
  | APIParseMarkdown Text
  | APIGetNtfToken
  | APIRegisterToken DeviceToken NotificationsMode
  | APIVerifyToken DeviceToken C.CbNonce ByteString
  | APIDeleteToken DeviceToken
  | APIGetNtfMessage {nonce :: C.CbNonce, encNtfInfo :: ByteString}
  | APIAddMember GroupId ContactId GroupMemberRole
  | APIJoinGroup GroupId
  | APIMemberRole GroupId GroupMemberId GroupMemberRole
  | APIRemoveMember GroupId GroupMemberId
  | APILeaveGroup GroupId
  | APIListMembers GroupId
  | APIUpdateGroupProfile GroupId GroupProfile
  | APICreateGroupLink GroupId GroupMemberRole
  | APIGroupLinkMemberRole GroupId GroupMemberRole
  | APIDeleteGroupLink GroupId
  | APIGetGroupLink GroupId
  | APIGetUserProtoServers UserId AProtocolType
  | GetUserProtoServers AProtocolType
  | APISetUserProtoServers UserId AProtoServersConfig
  | SetUserProtoServers AProtoServersConfig
  | APITestProtoServer UserId AProtoServerWithAuth
  | TestProtoServer AProtoServerWithAuth
  | APISetChatItemTTL UserId (Maybe Int64)
  | SetChatItemTTL (Maybe Int64)
  | APIGetChatItemTTL UserId
  | GetChatItemTTL
  | APISetNetworkConfig NetworkConfig
  | APIGetNetworkConfig
  | ReconnectAllServers
  | APISetChatSettings ChatRef ChatSettings
  | APIContactInfo ContactId
  | APIGroupInfo GroupId
  | APIGroupMemberInfo GroupId GroupMemberId
  | APISwitchContact ContactId
  | APISwitchGroupMember GroupId GroupMemberId
  | APIAbortSwitchContact ContactId
  | APIAbortSwitchGroupMember GroupId GroupMemberId
  | APISyncContactRatchet ContactId Bool
  | APISyncGroupMemberRatchet GroupId GroupMemberId Bool
  | APIGetContactCode ContactId
  | APIGetGroupMemberCode GroupId GroupMemberId
  | APIVerifyContact ContactId (Maybe Text)
  | APIVerifyGroupMember GroupId GroupMemberId (Maybe Text)
  | APIEnableContact ContactId
  | APIEnableGroupMember GroupId GroupMemberId
  | SetShowMessages ChatName Bool
  | SetSendReceipts ChatName (Maybe Bool)
  | ContactInfo ContactName
  | ShowGroupInfo GroupName
  | GroupMemberInfo GroupName ContactName
  | SwitchContact ContactName
  | SwitchGroupMember GroupName ContactName
  | AbortSwitchContact ContactName
  | AbortSwitchGroupMember GroupName ContactName
  | SyncContactRatchet ContactName Bool
  | SyncGroupMemberRatchet GroupName ContactName Bool
  | GetContactCode ContactName
  | GetGroupMemberCode GroupName ContactName
  | VerifyContact ContactName (Maybe Text)
  | VerifyGroupMember GroupName ContactName (Maybe Text)
  | EnableContact ContactName
  | EnableGroupMember GroupName ContactName
  | ChatHelp HelpSection
  | Welcome
  | APIAddContact UserId IncognitoEnabled
  | AddContact IncognitoEnabled
  | APISetConnectionIncognito Int64 IncognitoEnabled
  | APIConnect UserId IncognitoEnabled (Maybe AConnectionRequestUri)
  | Connect IncognitoEnabled (Maybe AConnectionRequestUri)
  | ConnectSimplex IncognitoEnabled -- UserId (not used in UI)
  | DeleteContact ContactName
  | ClearContact ContactName
  | APIListContacts UserId
  | ListContacts
  | APICreateMyAddress UserId
  | CreateMyAddress
  | APIDeleteMyAddress UserId
  | DeleteMyAddress
  | APIShowMyAddress UserId
  | ShowMyAddress
  | APISetProfileAddress UserId Bool
  | SetProfileAddress Bool
  | APIAddressAutoAccept UserId (Maybe AutoAccept)
  | AddressAutoAccept (Maybe AutoAccept)
  | AcceptContact IncognitoEnabled ContactName
  | RejectContact ContactName
  | SendMessage ChatName Text
  | SendLiveMessage ChatName Text
  | SendMessageQuote {contactName :: ContactName, msgDir :: AMsgDirection, quotedMsg :: Text, message :: Text}
  | SendMessageBroadcast Text -- UserId (not used in UI)
  | DeleteMessage ChatName Text
  | DeleteMemberMessage GroupName ContactName Text
  | EditMessage {chatName :: ChatName, editedMsg :: Text, message :: Text}
  | UpdateLiveMessage {chatName :: ChatName, chatItemId :: ChatItemId, liveMessage :: Bool, message :: Text}
  | ReactToMessage {add :: Bool, reaction :: MsgReaction, chatName :: ChatName, reactToMessage :: Text}
  | APINewGroup UserId GroupProfile
  | NewGroup GroupProfile
  | AddMember GroupName ContactName GroupMemberRole
  | JoinGroup GroupName
  | MemberRole GroupName ContactName GroupMemberRole
  | RemoveMember GroupName ContactName
  | LeaveGroup GroupName
  | DeleteGroup GroupName
  | ClearGroup GroupName
  | ListMembers GroupName
  | APIListGroups UserId (Maybe ContactId) (Maybe String)
  | ListGroups (Maybe ContactName) (Maybe String)
  | UpdateGroupNames GroupName GroupProfile
  | ShowGroupProfile GroupName
  | UpdateGroupDescription GroupName (Maybe Text)
  | ShowGroupDescription GroupName
  | CreateGroupLink GroupName GroupMemberRole
  | GroupLinkMemberRole GroupName GroupMemberRole
  | DeleteGroupLink GroupName
  | ShowGroupLink GroupName
  | SendGroupMessageQuote {groupName :: GroupName, contactName_ :: Maybe ContactName, quotedMsg :: Text, message :: Text}
  | LastChats (Maybe Int) -- UserId (not used in UI)
  | LastMessages (Maybe ChatName) Int (Maybe String) -- UserId (not used in UI)
  | LastChatItemId (Maybe ChatName) Int -- UserId (not used in UI)
  | ShowChatItem (Maybe ChatItemId) -- UserId (not used in UI)
  | ShowChatItemInfo ChatName Text
  | ShowLiveItems Bool
  | SendFile ChatName FilePath
  | SendImage ChatName FilePath
  | ForwardFile ChatName FileTransferId
  | ForwardImage ChatName FileTransferId
  | SendFileDescription ChatName FilePath
  | ReceiveFile {fileId :: FileTransferId, storeEncrypted :: Bool, fileInline :: Maybe Bool, filePath :: Maybe FilePath}
  | SetFileToReceive {fileId :: FileTransferId, storeEncrypted :: Bool}
  | CancelFile FileTransferId
  | FileStatus FileTransferId
  | ShowProfile -- UserId (not used in UI)
  | UpdateProfile ContactName Text -- UserId (not used in UI)
  | UpdateProfileImage (Maybe ImageData) -- UserId (not used in UI)
  | ShowProfileImage
  | SetUserFeature AChatFeature FeatureAllowed -- UserId (not used in UI)
  | SetContactFeature AChatFeature ContactName (Maybe FeatureAllowed)
  | SetGroupFeature AGroupFeature GroupName GroupFeatureEnabled
  | SetUserTimedMessages Bool -- UserId (not used in UI)
  | SetContactTimedMessages ContactName (Maybe TimedMessagesEnabled)
  | SetGroupTimedMessages GroupName (Maybe Int)
  | QuitChat
  | ShowVersion
  | DebugLocks
  | GetAgentStats
  | ResetAgentStats
  | GetAgentSubs
  | GetAgentSubsDetails
  | SatRequestIdentity -- Client wants to connect
  | SatIdentityRecord Text -- Host UI got OOB data
  | SatIdentityConfirm -- Host UI confirmed connection
  | SatIdentityReject -- Host UI rejected connection
  | SatTakeover -- Host wants to temporary disconnect satellite to unblock its own UI
  | SatTerminateIdentity -- Client wants to dispose session
  | SatIdentityDeregister -- Host wants to dispose session
  deriving (Show)

data ChatResponse
  = CRActiveUser {user :: User}
  | CRUsersList {users :: [UserInfo]}
  | CRChatStarted
  | CRChatRunning
  | CRChatStopped
  | CRChatSuspended
  | CRApiChats {user :: User, chats :: [AChat]}
  | CRChats {chats :: [AChat]}
  | CRApiChat {user :: User, chat :: AChat}
  | CRChatItems {user :: User, chatItems :: [AChatItem]}
  | CRChatItemInfo {user :: User, chatItem :: AChatItem, chatItemInfo :: ChatItemInfo}
  | CRChatItemId User (Maybe ChatItemId)
  | CRApiParsedMarkdown {formattedText :: Maybe MarkdownList}
  | CRUserProtoServers {user :: User, servers :: AUserProtoServers}
  | CRServerTestResult {user :: User, testServer :: AProtoServerWithAuth, testFailure :: Maybe ProtocolTestFailure}
  | CRChatItemTTL {user :: User, chatItemTTL :: Maybe Int64}
  | CRNetworkConfig {networkConfig :: NetworkConfig}
  | CRContactInfo {user :: User, contact :: Contact, connectionStats :: ConnectionStats, customUserProfile :: Maybe Profile}
  | CRGroupInfo {user :: User, groupInfo :: GroupInfo, groupSummary :: GroupSummary}
  | CRGroupMemberInfo {user :: User, groupInfo :: GroupInfo, member :: GroupMember, connectionStats_ :: Maybe ConnectionStats}
  | CRContactSwitchStarted {user :: User, contact :: Contact, connectionStats :: ConnectionStats}
  | CRGroupMemberSwitchStarted {user :: User, groupInfo :: GroupInfo, member :: GroupMember, connectionStats :: ConnectionStats}
  | CRContactSwitchAborted {user :: User, contact :: Contact, connectionStats :: ConnectionStats}
  | CRGroupMemberSwitchAborted {user :: User, groupInfo :: GroupInfo, member :: GroupMember, connectionStats :: ConnectionStats}
  | CRContactSwitch {user :: User, contact :: Contact, switchProgress :: SwitchProgress}
  | CRGroupMemberSwitch {user :: User, groupInfo :: GroupInfo, member :: GroupMember, switchProgress :: SwitchProgress}
  | CRContactRatchetSyncStarted {user :: User, contact :: Contact, connectionStats :: ConnectionStats}
  | CRGroupMemberRatchetSyncStarted {user :: User, groupInfo :: GroupInfo, member :: GroupMember, connectionStats :: ConnectionStats}
  | CRContactRatchetSync {user :: User, contact :: Contact, ratchetSyncProgress :: RatchetSyncProgress}
  | CRGroupMemberRatchetSync {user :: User, groupInfo :: GroupInfo, member :: GroupMember, ratchetSyncProgress :: RatchetSyncProgress}
  | CRContactVerificationReset {user :: User, contact :: Contact}
  | CRGroupMemberVerificationReset {user :: User, groupInfo :: GroupInfo, member :: GroupMember}
  | CRContactCode {user :: User, contact :: Contact, connectionCode :: Text}
  | CRGroupMemberCode {user :: User, groupInfo :: GroupInfo, member :: GroupMember, connectionCode :: Text}
  | CRConnectionVerified {user :: User, verified :: Bool, expectedCode :: Text}
  | CRNewChatItem {user :: User, chatItem :: AChatItem}
  | CRChatItemStatusUpdated {user :: User, chatItem :: AChatItem}
  | CRChatItemUpdated {user :: User, chatItem :: AChatItem}
  | CRChatItemNotChanged {user :: User, chatItem :: AChatItem}
  | CRChatItemReaction {user :: User, added :: Bool, reaction :: ACIReaction}
  | CRChatItemDeleted {user :: User, deletedChatItem :: AChatItem, toChatItem :: Maybe AChatItem, byUser :: Bool, timed :: Bool}
  | CRChatItemDeletedNotFound {user :: User, contact :: Contact, sharedMsgId :: SharedMsgId}
  | CRBroadcastSent {user :: User, msgContent :: MsgContent, successes :: Int, failures :: Int, timestamp :: UTCTime}
  | CRMsgIntegrityError {user :: User, msgError :: MsgErrorType}
  | CRCmdAccepted {corr :: CorrId}
  | CRCmdOk {user_ :: Maybe User}
  | CRChatHelp {helpSection :: HelpSection}
  | CRWelcome {user :: User}
  | CRGroupCreated {user :: User, groupInfo :: GroupInfo}
  | CRGroupMembers {user :: User, group :: Group}
  | CRContactsList {user :: User, contacts :: [Contact]}
  | CRUserContactLink {user :: User, contactLink :: UserContactLink}
  | CRUserContactLinkUpdated {user :: User, contactLink :: UserContactLink}
  | CRContactRequestRejected {user :: User, contactRequest :: UserContactRequest}
  | CRUserAcceptedGroupSent {user :: User, groupInfo :: GroupInfo, hostContact :: Maybe Contact}
  | CRUserDeletedMember {user :: User, groupInfo :: GroupInfo, member :: GroupMember}
  | CRGroupsList {user :: User, groups :: [(GroupInfo, GroupSummary)]}
  | CRSentGroupInvitation {user :: User, groupInfo :: GroupInfo, contact :: Contact, member :: GroupMember}
  | CRFileTransferStatus User (FileTransfer, [Integer]) -- TODO refactor this type to FileTransferStatus
  | CRFileTransferStatusXFTP User AChatItem
  | CRUserProfile {user :: User, profile :: Profile}
  | CRUserProfileNoChange {user :: User}
  | CRUserPrivacy {user :: User, updatedUser :: User}
  | CRVersionInfo {versionInfo :: CoreVersionInfo, chatMigrations :: [UpMigration], agentMigrations :: [UpMigration]}
  | CRInvitation {user :: User, connReqInvitation :: ConnReqInvitation, connection :: PendingContactConnection}
  | CRConnectionIncognitoUpdated {user :: User, toConnection :: PendingContactConnection}
  | CRSentConfirmation {user :: User}
  | CRSentInvitation {user :: User, customUserProfile :: Maybe Profile}
  | CRContactUpdated {user :: User, fromContact :: Contact, toContact :: Contact}
  | CRContactsMerged {user :: User, intoContact :: Contact, mergedContact :: Contact}
  | CRContactDeleted {user :: User, contact :: Contact}
  | CRChatCleared {user :: User, chatInfo :: AChatInfo}
  | CRUserContactLinkCreated {user :: User, connReqContact :: ConnReqContact}
  | CRUserContactLinkDeleted {user :: User}
  | CRReceivedContactRequest {user :: User, contactRequest :: UserContactRequest}
  | CRAcceptingContactRequest {user :: User, contact :: Contact}
  | CRContactAlreadyExists {user :: User, contact :: Contact}
  | CRContactRequestAlreadyAccepted {user :: User, contact :: Contact}
  | CRLeftMemberUser {user :: User, groupInfo :: GroupInfo}
  | CRGroupDeletedUser {user :: User, groupInfo :: GroupInfo}
  | CRRcvFileDescrReady {user :: User, chatItem :: AChatItem}
  | CRRcvFileAccepted {user :: User, chatItem :: AChatItem}
  | CRRcvFileAcceptedSndCancelled {user :: User, rcvFileTransfer :: RcvFileTransfer}
  | CRRcvFileDescrNotReady {user :: User, chatItem :: AChatItem}
  | CRRcvFileStart {user :: User, chatItem :: AChatItem}
  | CRRcvFileProgressXFTP {user :: User, chatItem :: AChatItem, receivedSize :: Int64, totalSize :: Int64}
  | CRRcvFileComplete {user :: User, chatItem :: AChatItem}
  | CRRcvFileCancelled {user :: User, chatItem :: AChatItem, rcvFileTransfer :: RcvFileTransfer}
  | CRRcvFileSndCancelled {user :: User, chatItem :: AChatItem, rcvFileTransfer :: RcvFileTransfer}
  | CRRcvFileError {user :: User, chatItem :: AChatItem}
  | CRSndFileStart {user :: User, chatItem :: AChatItem, sndFileTransfer :: SndFileTransfer}
  | CRSndFileComplete {user :: User, chatItem :: AChatItem, sndFileTransfer :: SndFileTransfer}
  | CRSndFileRcvCancelled {user :: User, chatItem :: AChatItem, sndFileTransfer :: SndFileTransfer}
  | CRSndFileCancelled {user :: User, chatItem :: AChatItem, fileTransferMeta :: FileTransferMeta, sndFileTransfers :: [SndFileTransfer]}
  | CRSndFileStartXFTP {user :: User, chatItem :: AChatItem, fileTransferMeta :: FileTransferMeta}
  | CRSndFileProgressXFTP {user :: User, chatItem :: AChatItem, fileTransferMeta :: FileTransferMeta, sentSize :: Int64, totalSize :: Int64}
  | CRSndFileCompleteXFTP {user :: User, chatItem :: AChatItem, fileTransferMeta :: FileTransferMeta}
  | CRSndFileCancelledXFTP {user :: User, chatItem :: AChatItem, fileTransferMeta :: FileTransferMeta}
  | CRSndFileError {user :: User, chatItem :: AChatItem}
  | CRUserProfileUpdated {user :: User, fromProfile :: Profile, toProfile :: Profile, updateSummary :: UserProfileUpdateSummary}
  | CRUserProfileImage {user :: User, profile :: Profile}
  | CRContactAliasUpdated {user :: User, toContact :: Contact}
  | CRConnectionAliasUpdated {user :: User, toConnection :: PendingContactConnection}
  | CRContactPrefsUpdated {user :: User, fromContact :: Contact, toContact :: Contact}
  | CRContactConnecting {user :: User, contact :: Contact}
  | CRContactConnected {user :: User, contact :: Contact, userCustomProfile :: Maybe Profile}
  | CRContactAnotherClient {user :: User, contact :: Contact}
  | CRSubscriptionEnd {user :: User, connectionEntity :: ConnectionEntity}
  | CRContactsDisconnected {server :: SMPServer, contactRefs :: [ContactRef]}
  | CRContactsSubscribed {server :: SMPServer, contactRefs :: [ContactRef]}
  | CRContactSubError {user :: User, contact :: Contact, chatError :: ChatError}
  | CRContactSubSummary {user :: User, contactSubscriptions :: [ContactSubStatus]}
  | CRUserContactSubSummary {user :: User, userContactSubscriptions :: [UserContactSubStatus]}
  | CRHostConnected {protocol :: AProtocolType, transportHost :: TransportHost}
  | CRHostDisconnected {protocol :: AProtocolType, transportHost :: TransportHost}
  | CRGroupInvitation {user :: User, groupInfo :: GroupInfo}
  | CRReceivedGroupInvitation {user :: User, groupInfo :: GroupInfo, contact :: Contact, fromMemberRole :: GroupMemberRole, memberRole :: GroupMemberRole}
  | CRUserJoinedGroup {user :: User, groupInfo :: GroupInfo, hostMember :: GroupMember}
  | CRJoinedGroupMember {user :: User, groupInfo :: GroupInfo, member :: GroupMember}
  | CRJoinedGroupMemberConnecting {user :: User, groupInfo :: GroupInfo, hostMember :: GroupMember, member :: GroupMember}
  | CRMemberRole {user :: User, groupInfo :: GroupInfo, byMember :: GroupMember, member :: GroupMember, fromRole :: GroupMemberRole, toRole :: GroupMemberRole}
  | CRMemberRoleUser {user :: User, groupInfo :: GroupInfo, member :: GroupMember, fromRole :: GroupMemberRole, toRole :: GroupMemberRole}
  | CRConnectedToGroupMember {user :: User, groupInfo :: GroupInfo, member :: GroupMember, memberContact :: Maybe Contact}
  | CRDeletedMember {user :: User, groupInfo :: GroupInfo, byMember :: GroupMember, deletedMember :: GroupMember}
  | CRDeletedMemberUser {user :: User, groupInfo :: GroupInfo, member :: GroupMember}
  | CRLeftMember {user :: User, groupInfo :: GroupInfo, member :: GroupMember}
  | CRGroupEmpty {user :: User, groupInfo :: GroupInfo}
  | CRGroupRemoved {user :: User, groupInfo :: GroupInfo}
  | CRGroupDeleted {user :: User, groupInfo :: GroupInfo, member :: GroupMember}
  | CRGroupUpdated {user :: User, fromGroup :: GroupInfo, toGroup :: GroupInfo, member_ :: Maybe GroupMember}
  | CRGroupProfile {user :: User, groupInfo :: GroupInfo}
  | CRGroupDescription {user :: User, groupInfo :: GroupInfo} -- only used in CLI
  | CRGroupLinkCreated {user :: User, groupInfo :: GroupInfo, connReqContact :: ConnReqContact, memberRole :: GroupMemberRole}
  | CRGroupLink {user :: User, groupInfo :: GroupInfo, connReqContact :: ConnReqContact, memberRole :: GroupMemberRole}
  | CRGroupLinkDeleted {user :: User, groupInfo :: GroupInfo}
  | CRAcceptingGroupJoinRequest {user :: User, groupInfo :: GroupInfo, contact :: Contact}
  | CRMemberSubError {user :: User, groupInfo :: GroupInfo, member :: GroupMember, chatError :: ChatError}
  | CRMemberSubSummary {user :: User, memberSubscriptions :: [MemberSubStatus]}
  | CRGroupSubscribed {user :: User, groupInfo :: GroupInfo}
  | CRPendingSubSummary {user :: User, pendingSubscriptions :: [PendingSubStatus]}
  | CRSndFileSubError {user :: User, sndFileTransfer :: SndFileTransfer, chatError :: ChatError}
  | CRRcvFileSubError {user :: User, rcvFileTransfer :: RcvFileTransfer, chatError :: ChatError}
  | CRCallInvitation {callInvitation :: RcvCallInvitation}
  | CRCallOffer {user :: User, contact :: Contact, callType :: CallType, offer :: WebRTCSession, sharedKey :: Maybe C.Key, askConfirmation :: Bool}
  | CRCallAnswer {user :: User, contact :: Contact, answer :: WebRTCSession}
  | CRCallExtraInfo {user :: User, contact :: Contact, extraInfo :: WebRTCExtraInfo}
  | CRCallEnded {user :: User, contact :: Contact}
  | CRCallInvitations {callInvitations :: [RcvCallInvitation]}
  | CRUserContactLinkSubscribed -- TODO delete
  | CRUserContactLinkSubError {chatError :: ChatError} -- TODO delete
  | CRNtfTokenStatus {status :: NtfTknStatus}
  | CRNtfToken {token :: DeviceToken, status :: NtfTknStatus, ntfMode :: NotificationsMode}
  | CRNtfMessages {user_ :: Maybe User, connEntity :: Maybe ConnectionEntity, msgTs :: Maybe UTCTime, ntfMessages :: [NtfMsgInfo]}
  | CRNewContactConnection {user :: User, connection :: PendingContactConnection}
  | CRContactConnectionDeleted {user :: User, connection :: PendingContactConnection}
  | CRSQLResult {rows :: [Text]}
  | CRSlowSQLQueries {chatQueries :: [SlowSQLQuery], agentQueries :: [SlowSQLQuery]}
  | CRDebugLocks {chatLockName :: Maybe String, agentLocks :: AgentLocks}
  | CRAgentStats {agentStats :: [[String]]}
  | CRAgentSubs {activeSubs :: Map Text Int, pendingSubs :: Map Text Int, removedSubs :: Map Text [String]}
  | CRAgentSubsDetails {agentSubs :: SubscriptionsInfo}
  | CRConnectionDisabled {connectionEntity :: ConnectionEntity}
  | CRAgentRcvQueueDeleted {agentConnId :: AgentConnId, server :: SMPServer, agentQueueId :: AgentQueueId, agentError_ :: Maybe AgentErrorType}
  | CRAgentConnDeleted {agentConnId :: AgentConnId}
  | CRAgentUserDeleted {agentUserId :: Int64}
  | CRMessageError {user :: User, severity :: Text, errorMessage :: Text}
  | CRChatCmdError {user_ :: Maybe User, chatError :: ChatError}
  | CRChatError {user_ :: Maybe User, chatError :: ChatError}
  | CRArchiveImported {archiveErrors :: [ArchiveError]}
  | CRTimedAction {action :: String, durationMilliseconds :: Int64}
  | CRSatRequestIdentity {identity :: Text}
  | CRSatIdentityRecord {satIdentityId :: Int64, identity :: Text}
  | CRSatIdentityConfirmed{satIdentityId :: Int64}
  | CRSatIdentityRejected{satIdentityId :: Int64}
  | CRSatTookOver{satIdentityId :: Int64}
  | CRSatIdentityDisposed{satIdentityId :: Int64}
  deriving (Show, Generic)

logResponseToFile :: ChatResponse -> Bool
logResponseToFile = \case
  CRContactsDisconnected {} -> True
  CRContactsSubscribed {} -> True
  CRContactSubError {} -> True
  CRMemberSubError {} -> True
  CRSndFileSubError {} -> True
  CRRcvFileSubError {} -> True
  CRHostConnected {} -> True
  CRHostDisconnected {} -> True
  CRConnectionDisabled {} -> True
  CRAgentRcvQueueDeleted {} -> True
  CRAgentConnDeleted {} -> True
  CRAgentUserDeleted {} -> True
  CRChatCmdError {} -> True
  CRChatError {} -> True
  CRMessageError {} -> True
  _ -> False

instance ToJSON ChatResponse where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "CR"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "CR"

newtype UserPwd = UserPwd {unUserPwd :: Text}
  deriving (Eq, Show)

instance FromJSON UserPwd where
  parseJSON v = UserPwd <$> parseJSON v

instance ToJSON UserPwd where
  toJSON (UserPwd p) = toJSON p
  toEncoding (UserPwd p) = toEncoding p

newtype AgentQueueId = AgentQueueId QueueId
  deriving (Eq, Show)

instance StrEncoding AgentQueueId where
  strEncode (AgentQueueId qId) = strEncode qId
  strDecode s = AgentQueueId <$> strDecode s
  strP = AgentQueueId <$> strP

instance ToJSON AgentQueueId where
  toJSON = strToJSON
  toEncoding = strToJEncoding

data ProtoServersConfig p = ProtoServersConfig {servers :: [ServerCfg p]}
  deriving (Show, Generic, FromJSON)

data AProtoServersConfig = forall p. ProtocolTypeI p => APSC (SProtocolType p) (ProtoServersConfig p)

deriving instance Show AProtoServersConfig

data UserProtoServers p = UserProtoServers
  { serverProtocol :: SProtocolType p,
    protoServers :: NonEmpty (ServerCfg p),
    presetServers :: NonEmpty (ProtoServerWithAuth p)
  }
  deriving (Show, Generic)

instance ProtocolTypeI p => ToJSON (UserProtoServers p) where
  toJSON = J.genericToJSON J.defaultOptions
  toEncoding = J.genericToEncoding J.defaultOptions

data AUserProtoServers = forall p. (ProtocolTypeI p, UserProtocol p) => AUPS (UserProtoServers p)

instance ToJSON AUserProtoServers where
  toJSON (AUPS s) = J.genericToJSON J.defaultOptions s
  toEncoding (AUPS s) = J.genericToEncoding J.defaultOptions s

deriving instance Show AUserProtoServers

data ArchiveConfig = ArchiveConfig {archivePath :: FilePath, disableCompression :: Maybe Bool, parentTempDirectory :: Maybe FilePath}
  deriving (Show, Generic, FromJSON)

data DBEncryptionConfig = DBEncryptionConfig {currentKey :: DBEncryptionKey, newKey :: DBEncryptionKey}
  deriving (Show, Generic, FromJSON)

newtype DBEncryptionKey = DBEncryptionKey String
  deriving (Show)

instance IsString DBEncryptionKey where fromString = parseString $ parseAll strP

instance StrEncoding DBEncryptionKey where
  strEncode (DBEncryptionKey s) = B.pack s
  strP = DBEncryptionKey . B.unpack <$> A.takeWhile (\c -> c /= ' ' && ord c >= 0x21 && ord c <= 0x7E)

instance FromJSON DBEncryptionKey where
  parseJSON = strParseJSON "DBEncryptionKey"

data ContactSubStatus = ContactSubStatus
  { contact :: Contact,
    contactError :: Maybe ChatError
  }
  deriving (Show, Generic)

instance ToJSON ContactSubStatus where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

data MemberSubStatus = MemberSubStatus
  { member :: GroupMember,
    memberError :: Maybe ChatError
  }
  deriving (Show, Generic)

instance ToJSON MemberSubStatus where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

data UserContactSubStatus = UserContactSubStatus
  { userContact :: UserContact,
    userContactError :: Maybe ChatError
  }
  deriving (Show, Generic)

instance ToJSON UserContactSubStatus where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

data PendingSubStatus = PendingSubStatus
  { connection :: PendingContactConnection,
    connError :: Maybe ChatError
  }
  deriving (Show, Generic)

instance ToJSON PendingSubStatus where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

data UserProfileUpdateSummary = UserProfileUpdateSummary
  { notChanged :: Int,
    updateSuccesses :: Int,
    updateFailures :: Int,
    changedContacts :: [Contact]
  }
  deriving (Show, Generic)

instance ToJSON UserProfileUpdateSummary where toEncoding = J.genericToEncoding J.defaultOptions

data ComposedMessage = ComposedMessage
  { fileSource :: Maybe CryptoFile,
    quotedItemId :: Maybe ChatItemId,
    msgContent :: MsgContent
  }
  deriving (Show, Generic)

-- This instance is needed for backward compatibility, can be removed in v6.0
instance FromJSON ComposedMessage where
  parseJSON (J.Object v) = do
    fileSource <-
      (v .:? "fileSource") >>= \case
        Nothing -> CF.plain <$$> (v .:? "filePath")
        f -> pure f
    quotedItemId <- v .:? "quotedItemId"
    msgContent <- v .: "msgContent"
    pure ComposedMessage {fileSource, quotedItemId, msgContent}
  parseJSON invalid =
    JT.prependFailure "bad ComposedMessage, " (JT.typeMismatch "Object" invalid)

instance ToJSON ComposedMessage where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

data XFTPFileConfig = XFTPFileConfig
  { minFileSize :: Integer
  }
  deriving (Show, Generic, FromJSON)

defaultXFTPFileConfig :: XFTPFileConfig
defaultXFTPFileConfig = XFTPFileConfig {minFileSize = 0}

instance ToJSON XFTPFileConfig where
  toJSON = J.genericToJSON J.defaultOptions {J.omitNothingFields = True}
  toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

data NtfMsgInfo = NtfMsgInfo {msgTs :: UTCTime, msgFlags :: MsgFlags}
  deriving (Show, Generic)

instance ToJSON NtfMsgInfo where toEncoding = J.genericToEncoding J.defaultOptions

crNtfToken :: (DeviceToken, NtfTknStatus, NotificationsMode) -> ChatResponse
crNtfToken (token, status, ntfMode) = CRNtfToken {token, status, ntfMode}

data SwitchProgress = SwitchProgress
  { queueDirection :: QueueDirection,
    switchPhase :: SwitchPhase,
    connectionStats :: ConnectionStats
  }
  deriving (Show, Generic)

instance ToJSON SwitchProgress where toEncoding = J.genericToEncoding J.defaultOptions

data RatchetSyncProgress = RatchetSyncProgress
  { ratchetSyncStatus :: RatchetSyncState,
    connectionStats :: ConnectionStats
  }
  deriving (Show, Generic)

instance ToJSON RatchetSyncProgress where toEncoding = J.genericToEncoding J.defaultOptions

data ParsedServerAddress = ParsedServerAddress
  { serverAddress :: Maybe ServerAddress,
    parseError :: String
  }
  deriving (Show, Generic)

instance ToJSON ParsedServerAddress where toEncoding = J.genericToEncoding J.defaultOptions

data ServerAddress = ServerAddress
  { serverProtocol :: AProtocolType,
    hostnames :: NonEmpty String,
    port :: String,
    keyHash :: String,
    basicAuth :: String
  }
  deriving (Show, Generic)

instance ToJSON ServerAddress where toEncoding = J.genericToEncoding J.defaultOptions

data TimedMessagesEnabled
  = TMEEnableSetTTL Int
  | TMEEnableKeepTTL
  | TMEDisableKeepTTL
  deriving (Show)

tmeToPref :: Maybe Int -> TimedMessagesEnabled -> TimedMessagesPreference
tmeToPref currentTTL tme = uncurry TimedMessagesPreference $ case tme of
  TMEEnableSetTTL ttl -> (FAYes, Just ttl)
  TMEEnableKeepTTL -> (FAYes, currentTTL)
  TMEDisableKeepTTL -> (FANo, currentTTL)

data ChatLogLevel = CLLDebug | CLLInfo | CLLWarning | CLLError | CLLImportant
  deriving (Eq, Ord, Show)

data CoreVersionInfo = CoreVersionInfo
  { version :: String,
    simplexmqVersion :: String,
    simplexmqCommit :: String
  }
  deriving (Show, Generic)

instance ToJSON CoreVersionInfo where toEncoding = J.genericToEncoding J.defaultOptions

data SendFileMode
  = SendFileSMP (Maybe InlineFileMode)
  | SendFileXFTP
  deriving (Show, Generic)

data SlowSQLQuery = SlowSQLQuery
  { query :: Text,
    queryStats :: SlowQueryStats
  }
  deriving (Show, Generic)

instance ToJSON SlowSQLQuery where toEncoding = J.genericToEncoding J.defaultOptions

data ChatError
  = ChatError {errorType :: ChatErrorType}
  | ChatErrorAgent {agentError :: AgentErrorType, connectionEntity_ :: Maybe ConnectionEntity}
  | ChatErrorStore {storeError :: StoreError}
  | ChatErrorDatabase {databaseError :: DatabaseError}
  | ChatErrorSatellite -- TBD
  deriving (Show, Exception, Generic)

instance ToJSON ChatError where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "Chat"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "Chat"

data ChatErrorType
  = CENoActiveUser
  | CENoConnectionUser {agentConnId :: AgentConnId}
  | CENoSndFileUser {agentSndFileId :: AgentSndFileId}
  | CENoRcvFileUser {agentRcvFileId :: AgentRcvFileId}
  | CEUserUnknown
  | CEActiveUserExists -- TODO delete
  | CEUserExists {contactName :: ContactName}
  | CEDifferentActiveUser {commandUserId :: UserId, activeUserId :: UserId}
  | CECantDeleteActiveUser {userId :: UserId}
  | CECantDeleteLastUser {userId :: UserId}
  | CECantHideLastUser {userId :: UserId}
  | CEHiddenUserAlwaysMuted {userId :: UserId}
  | CEEmptyUserPassword {userId :: UserId}
  | CEUserAlreadyHidden {userId :: UserId}
  | CEUserNotHidden {userId :: UserId}
  | CEChatNotStarted
  | CEChatNotStopped
  | CEChatStoreChanged
  | CEInvalidConnReq
  | CEInvalidChatMessage {connection :: Connection, msgMeta :: Maybe MsgMetaJSON, messageData :: Text, message :: String}
  | CEContactNotReady {contact :: Contact}
  | CEContactDisabled {contact :: Contact}
  | CEConnectionDisabled {connection :: Connection}
  | CEGroupUserRole {groupInfo :: GroupInfo, requiredRole :: GroupMemberRole}
  | CEGroupMemberInitialRole {groupInfo :: GroupInfo, initialRole :: GroupMemberRole}
  | CEContactIncognitoCantInvite
  | CEGroupIncognitoCantInvite
  | CEGroupContactRole {contactName :: ContactName}
  | CEGroupDuplicateMember {contactName :: ContactName}
  | CEGroupDuplicateMemberId
  | CEGroupNotJoined {groupInfo :: GroupInfo}
  | CEGroupMemberNotActive
  | CEGroupMemberUserRemoved
  | CEGroupMemberNotFound
  | CEGroupMemberIntroNotFound {contactName :: ContactName}
  | CEGroupCantResendInvitation {groupInfo :: GroupInfo, contactName :: ContactName}
  | CEGroupInternal {message :: String}
  | CEFileNotFound {message :: String}
  | CEFileSize {filePath :: FilePath}
  | CEFileAlreadyReceiving {message :: String}
  | CEFileCancelled {message :: String}
  | CEFileCancel {fileId :: FileTransferId, message :: String}
  | CEFileAlreadyExists {filePath :: FilePath}
  | CEFileRead {filePath :: FilePath, message :: String}
  | CEFileWrite {filePath :: FilePath, message :: String}
  | CEFileSend {fileId :: FileTransferId, agentError :: AgentErrorType}
  | CEFileRcvChunk {message :: String}
  | CEFileInternal {message :: String}
  | CEFileImageType {filePath :: FilePath}
  | CEFileImageSize {filePath :: FilePath}
  | CEFileNotReceived {fileId :: FileTransferId}
  | CEXFTPRcvFile {fileId :: FileTransferId, agentRcvFileId :: AgentRcvFileId, agentError :: AgentErrorType}
  | CEXFTPSndFile {fileId :: FileTransferId, agentSndFileId :: AgentSndFileId, agentError :: AgentErrorType}
  | CEFallbackToSMPProhibited {fileId :: FileTransferId}
  | CEInlineFileProhibited {fileId :: FileTransferId}
  | CEInvalidQuote
  | CEInvalidChatItemUpdate
  | CEInvalidChatItemDelete
  | CEHasCurrentCall
  | CENoCurrentCall
  | CECallContact {contactId :: Int64}
  | CECallState {currentCallState :: CallStateTag}
  | CEDirectMessagesProhibited {direction :: MsgDirection, contact :: Contact}
  | CEAgentVersion
  | CEAgentNoSubResult {agentConnId :: AgentConnId}
  | CECommandError {message :: String}
  | CEServerProtocol {serverProtocol :: AProtocolType}
  | CEAgentCommandError {message :: String}
  | CEInvalidFileDescription {message :: String}
  | CEConnectionIncognitoChangeProhibited
  | CEInternalError {message :: String}
  | CEException {message :: String}
  deriving (Show, Exception, Generic)

instance ToJSON ChatErrorType where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "CE"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "CE"

data DatabaseError
  = DBErrorEncrypted
  | DBErrorPlaintext
  | DBErrorNoFile {dbFile :: String}
  | DBErrorExport {sqliteError :: SQLiteError}
  | DBErrorOpen {sqliteError :: SQLiteError}
  deriving (Show, Exception, Generic)

instance ToJSON DatabaseError where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "DB"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "DB"

data SQLiteError = SQLiteErrorNotADatabase | SQLiteError String
  deriving (Show, Exception, Generic)

instance ToJSON SQLiteError where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "SQLite"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "SQLite"

throwDBError :: ChatMonad m => DatabaseError -> m ()
throwDBError = throwError . ChatErrorDatabase

type ChatMonad' m = (MonadUnliftIO m, MonadReader ChatController m)

type ChatMonad m = (ChatMonad' m, MonadError ChatError m)

chatReadVar :: ChatMonad' m => (ChatController -> TVar a) -> m a
chatReadVar f = asks f >>= readTVarIO
{-# INLINE chatReadVar #-}

chatWriteVar :: ChatMonad' m => (ChatController -> TVar a) -> a -> m ()
chatWriteVar f value = asks f >>= atomically . (`writeTVar` value)
{-# INLINE chatWriteVar #-}

tryChatError :: ChatMonad m => m a -> m (Either ChatError a)
tryChatError = tryAllErrors mkChatError
{-# INLINE tryChatError #-}

catchChatError :: ChatMonad m => m a -> (ChatError -> m a) -> m a
catchChatError = catchAllErrors mkChatError
{-# INLINE catchChatError #-}

chatFinally :: ChatMonad m => m a -> m b -> m a
chatFinally = allFinally mkChatError
{-# INLINE chatFinally #-}

mkChatError :: SomeException -> ChatError
mkChatError = ChatError . CEException . show
{-# INLINE mkChatError #-}

chatCmdError :: Maybe User -> String -> ChatResponse
chatCmdError user = CRChatCmdError user . ChatError . CECommandError

setActive :: (MonadUnliftIO m, MonadReader ChatController m) => ActiveTo -> m ()
setActive to = asks activeTo >>= atomically . (`writeTVar` to)

unsetActive :: (MonadUnliftIO m, MonadReader ChatController m) => ActiveTo -> m ()
unsetActive a = asks activeTo >>= atomically . (`modifyTVar` unset)
  where
    unset a' = if a == a' then ActiveNone else a'

data ArchiveError
  = AEImport {chatError :: ChatError}
  | AEImportFile {file :: String, chatError :: ChatError}
  deriving (Show, Exception, Generic)

instance ToJSON ArchiveError where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "AE"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "AE"
