{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Focus.Backend.Listen.Session where

import Control.Concurrent
import Control.Monad
import Data.Functor.Identity
import Data.Maybe
import Data.Pool
import Data.Time

import Database.Groundhog.Postgresql
import Focus.Backend.DB
import Focus.Backend.DB.PsqlSimple
import Focus.Backend.DB.Groundhog
import Focus.Backend.Schema.TH
import Focus.Schema

data Session = Session { _session_timestamp :: UTCTime }

instance HasId Session

mkFocusPersist (Just "migrateSession") [groundhog|
  - entity: Session
|]

makeDefaultKeyIdInt64 ''Session 'SessionKey

handleStoppedSession :: Pool Postgresql
                   -> (Id Session -> FocusPersist ())
                   -> IO ()
handleStoppedSession db cleanup = do
  continue <- fmap isJust . runDb (Identity db) $ do
    now <- getTime
    let timeLimit = addUTCTime (10*60) now
    dead <- fmap (fmap toId . listToMaybe) . project AutoKeyField $ (Session_timestampField <. timeLimit) `limitTo` 1
    forM dead $ \deadId -> cleanup deadId >> execute [sql| DELETE FROM "Session" WHERE id = ? |] (Only deadId)
  when continue $ handleStoppedSession db cleanup

superviseSessions :: Pool Postgresql
                  -> (Id Session -> FocusPersist ())
                  -> IO (IO ())
superviseSessions db cleanup = return . killThread <=< forkIO . forever $ handleStoppedSession db cleanup >> threadDelay (60*1000000)

heartbeat :: Pool Postgresql
          -> Id Session
          -> IO (IO ())
heartbeat db session = return . killThread <=< forkIO . forever $ do
    runDb (Identity db) $ do
      now <- getTime
      update [Session_timestampField =. now] (AutoKeyField ==. fromId session)
    threadDelay (10*1000000)