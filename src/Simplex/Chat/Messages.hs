{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}

module Simplex.Chat.Messages where

import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as J
import qualified Data.Attoparsec.ByteString.Char8 as A
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy.Char8 as LB
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeLatin1, encodeUtf8)
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (TimeZone, ZonedTime, utcToZonedTime)
import Data.Type.Equality
import Data.Typeable (Typeable)
import Database.SQLite.Simple.FromField (FromField (..))
import Database.SQLite.Simple.ToField (ToField (..))
import GHC.Generics (Generic)
import Simplex.Chat.Protocol
import Simplex.Chat.Types
import Simplex.Chat.Util (eitherToMaybe, safeDecodeUtf8)
import Simplex.Messaging.Agent.Protocol (AgentErrorType, AgentMsgId, MsgMeta (..))
import Simplex.Messaging.Agent.Store.SQLite (fromTextField_)
import Simplex.Messaging.Encoding.String
import Simplex.Messaging.Parsers (dropPrefix, enumJSON, sumTypeJSON)
import Simplex.Messaging.Protocol (MsgBody)
import Simplex.Messaging.Util ((<$?>))

data ChatType = CTDirect | CTGroup | CTContactRequest
  deriving (Show, Generic)

instance ToJSON ChatType where
  toJSON = J.genericToJSON . enumJSON $ dropPrefix "CT"
  toEncoding = J.genericToEncoding . enumJSON $ dropPrefix "CT"

data ChatInfo (c :: ChatType) where
  DirectChat :: Contact -> ChatInfo 'CTDirect
  GroupChat :: GroupInfo -> ChatInfo 'CTGroup
  ContactRequest :: UserContactRequest -> ChatInfo 'CTContactRequest

deriving instance Show (ChatInfo c)

data JSONChatInfo
  = JCInfoDirect {contact :: Contact}
  | JCInfoGroup {groupInfo :: GroupInfo}
  | JCInfoContactRequest {contactRequest :: UserContactRequest}
  deriving (Generic)

instance ToJSON JSONChatInfo where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "JCInfo"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "JCInfo"

instance ToJSON (ChatInfo c) where
  toJSON = J.toJSON . jsonChatInfo
  toEncoding = J.toEncoding . jsonChatInfo

jsonChatInfo :: ChatInfo c -> JSONChatInfo
jsonChatInfo = \case
  DirectChat c -> JCInfoDirect c
  GroupChat g -> JCInfoGroup g
  ContactRequest g -> JCInfoContactRequest g

data ChatItem (c :: ChatType) (d :: MsgDirection) = ChatItem
  { chatDir :: CIDirection c d,
    meta :: CIMeta d,
    content :: CIContent d
  }
  deriving (Show, Generic)

instance ToJSON (ChatItem c d) where
  toJSON = J.genericToJSON J.defaultOptions
  toEncoding = J.genericToEncoding J.defaultOptions

data CIDirection (c :: ChatType) (d :: MsgDirection) where
  CIDirectSnd :: CIDirection 'CTDirect 'MDSnd
  CIDirectRcv :: CIDirection 'CTDirect 'MDRcv
  CIGroupSnd :: CIDirection 'CTGroup 'MDSnd
  CIGroupRcv :: GroupMember -> CIDirection 'CTGroup 'MDRcv

deriving instance Show (CIDirection c d)

data JSONCIDirection
  = JCIDirectSnd
  | JCIDirectRcv
  | JCIGroupSnd
  | JCIGroupRcv {groupMember :: GroupMember}
  deriving (Generic, Show)

instance FromJSON JSONCIDirection where
  parseJSON = J.genericParseJSON . sumTypeJSON $ dropPrefix "JCI"

instance ToJSON JSONCIDirection where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "JCI"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "JCI"

instance ToJSON (CIDirection c d) where
  toJSON = J.toJSON . jsonCIDirection
  toEncoding = J.toEncoding . jsonCIDirection

jsonCIDirection :: CIDirection c d -> JSONCIDirection
jsonCIDirection = \case
  CIDirectSnd -> JCIDirectSnd
  CIDirectRcv -> JCIDirectRcv
  CIGroupSnd -> JCIGroupSnd
  CIGroupRcv m -> JCIGroupRcv m

data CChatItem c = forall d. MsgDirectionI d => CChatItem (SMsgDirection d) (ChatItem c d)

deriving instance Show (CChatItem c)

instance ToJSON (CChatItem c) where
  toJSON (CChatItem _ ci) = J.toJSON ci
  toEncoding (CChatItem _ ci) = J.toEncoding ci

chatItemId' :: ChatItem c d -> ChatItemId
chatItemId' ChatItem {meta = CIMeta {itemId}} = itemId

data ChatDirection (c :: ChatType) (d :: MsgDirection) where
  CDDirectSnd :: Contact -> ChatDirection 'CTDirect 'MDSnd
  CDDirectRcv :: Contact -> ChatDirection 'CTDirect 'MDRcv
  CDGroupSnd :: GroupInfo -> ChatDirection 'CTGroup 'MDSnd
  CDGroupRcv :: GroupInfo -> GroupMember -> ChatDirection 'CTGroup 'MDRcv

data NewChatItem d = NewChatItem
  { createdByMsgId :: Maybe MessageId,
    itemSent :: SMsgDirection d,
    itemTs :: ChatItemTs,
    itemContent :: CIContent d,
    itemText :: Text,
    itemStatus :: CIStatus d,
    createdAt :: UTCTime
  }
  deriving (Show)

-- | type to show one chat with messages
data Chat c = Chat {chatInfo :: ChatInfo c, chatItems :: [CChatItem c]}
  deriving (Show, Generic)

instance ToJSON (Chat c) where
  toJSON = J.genericToJSON J.defaultOptions
  toEncoding = J.genericToEncoding J.defaultOptions

data AChat = forall c. AChat (SChatType c) (Chat c)

deriving instance Show AChat

instance ToJSON AChat where
  toJSON (AChat _ c) = J.toJSON c
  toEncoding (AChat _ c) = J.toEncoding c

-- | type to show a mix of messages from multiple chats
data AChatItem = forall c d. AChatItem (SChatType c) (SMsgDirection d) (ChatInfo c) (ChatItem c d)

deriving instance Show AChatItem

instance ToJSON AChatItem where
  toJSON (AChatItem _ _ chat item) = J.toJSON $ JSONAnyChatItem chat item
  toEncoding (AChatItem _ _ chat item) = J.toEncoding $ JSONAnyChatItem chat item

data JSONAnyChatItem c d = JSONAnyChatItem {chatInfo :: ChatInfo c, chatItem :: ChatItem c d}
  deriving (Generic)

instance ToJSON (JSONAnyChatItem c d) where
  toJSON = J.genericToJSON J.defaultOptions
  toEncoding = J.genericToEncoding J.defaultOptions

data CIMeta (d :: MsgDirection) = CIMeta
  { itemId :: ChatItemId,
    itemTs :: ChatItemTs,
    itemText :: Text,
    itemStatus :: CIStatus d,
    localItemTs :: ZonedTime,
    createdAt :: UTCTime
  }
  deriving (Show, Generic)

mkCIMeta :: ChatItemId -> Text -> CIStatus d -> TimeZone -> ChatItemTs -> UTCTime -> CIMeta d
mkCIMeta itemId itemText itemStatus tz itemTs createdAt =
  let localItemTs = utcToZonedTime tz itemTs
   in CIMeta {itemId, itemTs, itemText, itemStatus, localItemTs, createdAt}

instance ToJSON (CIMeta d) where toEncoding = J.genericToEncoding J.defaultOptions

data CIStatus (d :: MsgDirection) where
  CISSndNew :: CIStatus 'MDSnd
  CISSndSent :: CIStatus 'MDSnd
  CISSndErrorAuth :: CIStatus 'MDSnd
  CISSndError :: AgentErrorType -> CIStatus 'MDSnd
  CISRcvNew :: CIStatus 'MDRcv
  CISRcvRead :: CIStatus 'MDRcv

deriving instance Show (CIStatus d)

ciStatusNew :: forall d. MsgDirectionI d => CIStatus d
ciStatusNew = case msgDirection @d of
  SMDSnd -> CISSndNew
  SMDRcv -> CISRcvNew

instance ToJSON (CIStatus d) where
  toJSON = J.toJSON . jsonCIStatus
  toEncoding = J.toEncoding . jsonCIStatus

instance MsgDirectionI d => ToField (CIStatus d) where toField = toField . decodeLatin1 . strEncode

instance FromField ACIStatus where fromField = fromTextField_ $ eitherToMaybe . strDecode . encodeUtf8

data ACIStatus = forall d. MsgDirectionI d => ACIStatus (SMsgDirection d) (CIStatus d)

instance MsgDirectionI d => StrEncoding (CIStatus d) where
  strEncode = \case
    CISSndNew -> "snd_new"
    CISSndSent -> "snd_sent"
    CISSndErrorAuth -> "snd_error_auth"
    CISSndError e -> "snd_error " <> strEncode e
    CISRcvNew -> "rcv_new"
    CISRcvRead -> "rcv_read"
  strP = (\(ACIStatus _ st) -> checkDirection st) <$?> strP

instance StrEncoding ACIStatus where
  strEncode (ACIStatus _ s) = strEncode s
  strP =
    A.takeTill (== ' ') >>= \case
      "snd_new" -> pure $ ACIStatus SMDSnd CISSndNew
      "snd_sent" -> pure $ ACIStatus SMDSnd CISSndSent
      "snd_error_auth" -> pure $ ACIStatus SMDSnd CISSndErrorAuth
      "snd_error" -> ACIStatus SMDSnd <$> (A.space *> strP)
      "rcv_new" -> pure $ ACIStatus SMDRcv CISRcvNew
      "rcv_read" -> pure $ ACIStatus SMDRcv CISRcvRead
      _ -> fail "bad status"

data JSONCIStatus
  = JCISSndNew
  | JCISSndSent
  | JCISSndErrorAuth
  | JCISSndError {agentError :: AgentErrorType}
  | JCISRcvNew
  | JCISRcvRead
  deriving (Show, Generic)

instance ToJSON JSONCIStatus where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "JCIS"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "JCIS"

jsonCIStatus :: CIStatus d -> JSONCIStatus
jsonCIStatus = \case
  CISSndNew -> JCISSndNew
  CISSndSent -> JCISSndSent
  CISSndErrorAuth -> JCISSndErrorAuth
  CISSndError e -> JCISSndError e
  CISRcvNew -> JCISRcvNew
  CISRcvRead -> JCISRcvRead

type ChatItemId = Int64

data ChatPagination
  = CPLast Int
  | CPAfter ChatItemId Int
  | CPBefore ChatItemId Int
  deriving (Show)

type ChatItemTs = UTCTime

data CIContent (d :: MsgDirection) where
  CISndMsgContent :: MsgContent -> CIContent 'MDSnd
  CIRcvMsgContent :: MsgContent -> CIContent 'MDRcv
  CISndFileInvitation :: FileTransferId -> FilePath -> CIContent 'MDSnd
  CIRcvFileInvitation :: RcvFileTransfer -> CIContent 'MDRcv

deriving instance Show (CIContent d)

ciContentToText :: CIContent d -> Text
ciContentToText = \case
  CISndMsgContent mc -> msgContentText mc
  CIRcvMsgContent mc -> msgContentText mc
  CISndFileInvitation fId fPath -> "you sent file #" <> T.pack (show fId) <> ": " <> T.pack fPath
  CIRcvFileInvitation RcvFileTransfer {fileInvitation = FileInvitation {fileName}} -> "file " <> T.pack fileName

instance ToField (CIContent d) where
  toField = toField . safeDecodeUtf8 . LB.toStrict . J.encode

instance ToJSON (CIContent d) where
  toJSON = J.toJSON . jsonCIContent
  toEncoding = J.toEncoding . jsonCIContent

data ACIContent = forall d. ACIContent (SMsgDirection d) (CIContent d)

instance FromJSON ACIContent where
  parseJSON = fmap aciContentJSON . J.parseJSON

instance FromField ACIContent where fromField = fromTextField_ $ J.decode . LB.fromStrict . encodeUtf8

data JSONCIContent
  = JCISndMsgContent {msgContent :: MsgContent}
  | JCIRcvMsgContent {msgContent :: MsgContent}
  | JCISndFileInvitation {fileId :: FileTransferId, filePath :: FilePath}
  | JCIRcvFileInvitation {rcvFileTransfer :: RcvFileTransfer}
  deriving (Generic)

instance FromJSON JSONCIContent where
  parseJSON = J.genericParseJSON . sumTypeJSON $ dropPrefix "JCI"

instance ToJSON JSONCIContent where
  toJSON = J.genericToJSON . sumTypeJSON $ dropPrefix "JCI"
  toEncoding = J.genericToEncoding . sumTypeJSON $ dropPrefix "JCI"

jsonCIContent :: CIContent d -> JSONCIContent
jsonCIContent = \case
  CISndMsgContent mc -> JCISndMsgContent mc
  CIRcvMsgContent mc -> JCIRcvMsgContent mc
  CISndFileInvitation fId fPath -> JCISndFileInvitation fId fPath
  CIRcvFileInvitation ft -> JCIRcvFileInvitation ft

aciContentJSON :: JSONCIContent -> ACIContent
aciContentJSON = \case
  JCISndMsgContent mc -> ACIContent SMDSnd $ CISndMsgContent mc
  JCIRcvMsgContent mc -> ACIContent SMDRcv $ CIRcvMsgContent mc
  JCISndFileInvitation fId fPath -> ACIContent SMDSnd $ CISndFileInvitation fId fPath
  JCIRcvFileInvitation ft -> ACIContent SMDRcv $ CIRcvFileInvitation ft

data SChatType (c :: ChatType) where
  SCTDirect :: SChatType 'CTDirect
  SCTGroup :: SChatType 'CTGroup
  SCTContactRequest :: SChatType 'CTContactRequest

deriving instance Show (SChatType c)

instance TestEquality SChatType where
  testEquality SCTDirect SCTDirect = Just Refl
  testEquality SCTGroup SCTGroup = Just Refl
  testEquality _ _ = Nothing

class ChatTypeI (c :: ChatType) where
  chatType :: SChatType c

instance ChatTypeI 'CTDirect where chatType = SCTDirect

instance ChatTypeI 'CTGroup where chatType = SCTGroup

data NewMessage = NewMessage
  { direction :: MsgDirection,
    cmEventTag :: CMEventTag,
    msgBody :: MsgBody
  }
  deriving (Show)

data PendingGroupMessage = PendingGroupMessage
  { msgId :: MessageId,
    cmEventTag :: CMEventTag,
    msgBody :: MsgBody,
    introId_ :: Maybe Int64
  }

type MessageId = Int64

data MsgDirection = MDRcv | MDSnd
  deriving (Show, Generic)

instance FromJSON MsgDirection where
  parseJSON = J.genericParseJSON . enumJSON $ dropPrefix "MD"

instance ToJSON MsgDirection where
  toJSON = J.genericToJSON . enumJSON $ dropPrefix "MD"
  toEncoding = J.genericToEncoding . enumJSON $ dropPrefix "MD"

instance ToField MsgDirection where toField = toField . msgDirectionInt

data SMsgDirection (d :: MsgDirection) where
  SMDRcv :: SMsgDirection 'MDRcv
  SMDSnd :: SMsgDirection 'MDSnd

deriving instance Show (SMsgDirection d)

instance TestEquality SMsgDirection where
  testEquality SMDRcv SMDRcv = Just Refl
  testEquality SMDSnd SMDSnd = Just Refl
  testEquality _ _ = Nothing

instance ToField (SMsgDirection d) where toField = toField . msgDirectionInt . toMsgDirection

toMsgDirection :: SMsgDirection d -> MsgDirection
toMsgDirection = \case
  SMDRcv -> MDRcv
  SMDSnd -> MDSnd

class MsgDirectionI (d :: MsgDirection) where
  msgDirection :: SMsgDirection d

instance MsgDirectionI 'MDRcv where msgDirection = SMDRcv

instance MsgDirectionI 'MDSnd where msgDirection = SMDSnd

msgDirectionInt :: MsgDirection -> Int
msgDirectionInt = \case
  MDRcv -> 0
  MDSnd -> 1

msgDirectionIntP :: Int64 -> Maybe MsgDirection
msgDirectionIntP = \case
  0 -> Just MDRcv
  1 -> Just MDSnd
  _ -> Nothing

data SndMsgDelivery = SndMsgDelivery
  { connId :: Int64,
    agentMsgId :: AgentMsgId
  }

data RcvMsgDelivery = RcvMsgDelivery
  { connId :: Int64,
    agentMsgId :: AgentMsgId,
    agentMsgMeta :: MsgMeta
  }

data MsgMetaJSON = MsgMetaJSON
  { integrity :: Text,
    rcvId :: Int64,
    rcvTs :: UTCTime,
    serverId :: Text,
    serverTs :: UTCTime,
    sndId :: Int64
  }
  deriving (Eq, Show, FromJSON, Generic)

instance ToJSON MsgMetaJSON where toEncoding = J.genericToEncoding J.defaultOptions {J.omitNothingFields = True}

msgMetaToJson :: MsgMeta -> MsgMetaJSON
msgMetaToJson MsgMeta {integrity, recipient = (rcvId, rcvTs), broker = (serverId, serverTs), sndMsgId = sndId} =
  MsgMetaJSON
    { integrity = (decodeLatin1 . strEncode) integrity,
      rcvId,
      rcvTs,
      serverId = (decodeLatin1 . B64.encode) serverId,
      serverTs,
      sndId
    }

msgMetaJson :: MsgMeta -> Text
msgMetaJson = decodeLatin1 . LB.toStrict . J.encode . msgMetaToJson

data MsgDeliveryStatus (d :: MsgDirection) where
  MDSRcvAgent :: MsgDeliveryStatus 'MDRcv
  MDSRcvAcknowledged :: MsgDeliveryStatus 'MDRcv
  MDSSndPending :: MsgDeliveryStatus 'MDSnd
  MDSSndAgent :: MsgDeliveryStatus 'MDSnd
  MDSSndSent :: MsgDeliveryStatus 'MDSnd
  MDSSndReceived :: MsgDeliveryStatus 'MDSnd
  MDSSndRead :: MsgDeliveryStatus 'MDSnd

data AMsgDeliveryStatus = forall d. AMDS (SMsgDirection d) (MsgDeliveryStatus d)

instance (Typeable d, MsgDirectionI d) => FromField (MsgDeliveryStatus d) where
  fromField = fromTextField_ msgDeliveryStatusT'

instance ToField (MsgDeliveryStatus d) where toField = toField . serializeMsgDeliveryStatus

serializeMsgDeliveryStatus :: MsgDeliveryStatus d -> Text
serializeMsgDeliveryStatus = \case
  MDSRcvAgent -> "rcv_agent"
  MDSRcvAcknowledged -> "rcv_acknowledged"
  MDSSndPending -> "snd_pending"
  MDSSndAgent -> "snd_agent"
  MDSSndSent -> "snd_sent"
  MDSSndReceived -> "snd_received"
  MDSSndRead -> "snd_read"

msgDeliveryStatusT :: Text -> Maybe AMsgDeliveryStatus
msgDeliveryStatusT = \case
  "rcv_agent" -> Just $ AMDS SMDRcv MDSRcvAgent
  "rcv_acknowledged" -> Just $ AMDS SMDRcv MDSRcvAcknowledged
  "snd_pending" -> Just $ AMDS SMDSnd MDSSndPending
  "snd_agent" -> Just $ AMDS SMDSnd MDSSndAgent
  "snd_sent" -> Just $ AMDS SMDSnd MDSSndSent
  "snd_received" -> Just $ AMDS SMDSnd MDSSndReceived
  "snd_read" -> Just $ AMDS SMDSnd MDSSndRead
  _ -> Nothing

msgDeliveryStatusT' :: forall d. MsgDirectionI d => Text -> Maybe (MsgDeliveryStatus d)
msgDeliveryStatusT' s =
  msgDeliveryStatusT s >>= \(AMDS d st) ->
    case testEquality d (msgDirection @d) of
      Just Refl -> Just st
      _ -> Nothing

checkDirection :: forall t d d'. (MsgDirectionI d, MsgDirectionI d') => t d' -> Either String (t d)
checkDirection x = case testEquality (msgDirection @d) (msgDirection @d') of
  Just Refl -> Right x
  Nothing -> Left "bad direction"
