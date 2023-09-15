{-# LANGUAGE QuasiQuotes #-}

module Simplex.Chat.Migrations.M20230915_remote_profiles where

import Database.SQLite.Simple (Query)
import Database.SQLite.Simple.QQ (sql)

m20230915_remote_profiles :: Query
m20230915_remote_profiles =
  [sql|
CREATE TABLE remote_devices (
  remote_device_id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_name TEXT NOT NULL,
  device_status TEXT NOT NULL,
  device_public_key BLOB NOT NULL,
  local_private_key BLOB NOT NULL,
  local_public_key BLOB NOT NULL,
  created_at TEXT NOT NULL DEFAULT(datetime('now')),
  updated_at TEXT NOT NULL DEFAULT(datetime('now'))
);
|]

down_m20230915_remote_profiles :: Query
down_m20230915_remote_profiles =
  [sql|
DROP TABLE remote_devices;
|]
