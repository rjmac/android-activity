{-# LANGUAGE ScopedTypeVariables, GeneralizedNewtypeDeriving, LambdaCase, TemplateHaskell, KindSignatures, OverloadedStrings #-}
module Focus.Client where

import Control.Arrow ((&&&))
import Control.Concurrent
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Reader
import Control.Monad.Trans.Maybe
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as LBSC8
import Data.Int
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Data.Text (Text)
import Debug.Trace.LocationTH
import System.Timeout

import Network.Socket
import Network.WebSockets hiding (ClientApp, Request)

import Focus.Account
import Focus.Api
import Focus.AppendMap
import Focus.Request
import Focus.Sign
import Focus.WebSocket

newtype RequestId = RequestId { _unTestId :: Int64 }
  deriving (Eq, Ord, Num, Show, Read, ToJSON, FromJSON)

data ClientEnv s p v = 
  ClientEnv { _clientEnv_websocket :: Connection
            , _clientEnv_token :: MVar (Maybe (Signed AuthToken))
            , _clientEnv_nextId :: MVar RequestId
            , _clientEnv_pending :: MVar (Map RequestId (MVar (Either String Value)))
            , _clientEnv_currentView :: MVar (Maybe v)
            , _clientEnv_currentSelector :: MVar s
            , _clientEnv_patcher :: MVar (s -> p -> Maybe v -> v)
            }

newtype ClientApp select patch view (pub :: * -> *) (priv :: * -> *) a = ClientApp { _runClientApp :: ReaderT (ClientEnv select patch view) IO a }
  deriving (Functor, Applicative, Monad, MonadReader (ClientEnv select patch view), MonadIO)

runClientApp :: (Monoid select, FromJSON patch) => (select -> patch -> Maybe view -> view) -> ClientApp select patch view pub priv a -> IO a
runClientApp patcher (ClientApp m) = withSocketsDo $ runClient "localhost" 8000 url $ \conn -> do
  nextId <- newMVar 1
  pending <- newMVar Map.empty
  authRef <- newMVar Nothing
  viewRef <- newMVar Nothing
  selRef <- newMVar mempty
  patcherRef <- newMVar patcher
  let env = ClientEnv { _clientEnv_websocket = conn
                      , _clientEnv_token = authRef
                      , _clientEnv_nextId = nextId
                      , _clientEnv_pending = pending
                      , _clientEnv_currentView = viewRef
                      , _clientEnv_currentSelector = selRef
                      , _clientEnv_patcher = patcherRef
                      }
  lid <- forkIO (listener env)
  a <- runReaderT m env
  --TODO: Is this ok? What about pending messages in the pipe?
  killThread lid
  sendClose conn ("Bye! ;) ;) ;)" :: Text)
  return a
 where url = "/listen?token"

requestWithTimeout :: forall select patch view rsp pub priv. (ToJSON rsp, FromJSON rsp, Request pub, Request priv) => Maybe Int64 -> ApiRequest pub priv rsp -> ClientApp select patch view pub priv (Maybe (Either String rsp))
requestWithTimeout mtime req = ClientApp $ do
  conn <- asks _clientEnv_websocket
  (next, pending) <- asks (_clientEnv_nextId &&& _clientEnv_pending)
  liftIO $ do
    rid <- modifyMVar next $ \s -> return (s+1, s)
    em <- newEmptyMVar
    modifyMVar_ pending $ return . Map.insertWith ($failure "duplicate request id") rid em
    let payload :: WebSocketData (Maybe (Signed AuthToken)) Value (SomeRequest (ApiRequest pub priv))
        payload = WebSocketData_Api (toJSON rid) (SomeRequest req)
    sendTextData conn $ encode payload
    let decodeOrBust r = case fromJSON r of
          Error _ -> $failure $ "response failed to parse: " <> LBSC8.unpack (encode r)
          Success r' -> r'
    mrsp <- fmap decodeOrBust <$> readMVar em & case mtime of
      Nothing -> fmap Just
      Just t -> timeout (fromIntegral t) --TODO: #115797377
    modifyMVar_ pending $ return . Map.delete rid
    return mrsp

privateWithTimeout :: (ToJSON rsp, FromJSON rsp, Request pub, Request priv) => Maybe Int64 -> priv rsp -> ClientApp select patch view pub priv (Maybe (Either String rsp))
privateWithTimeout mt req = do
  maRef <- asks _clientEnv_token
  ma <- liftIO (readMVar maRef)
  case ma of
    Nothing -> $failure $ "attempted to make private request without authentication: " <> LBSC8.unpack (encode (requestToJSON req))
    Just auth -> requestWithTimeout mt (ApiRequest_Private auth req)

publicWithTimeout :: (ToJSON rsp, FromJSON rsp, Request pub, Request priv) => Maybe Int64 -> pub rsp -> ClientApp select patch view pub priv (Maybe (Either String rsp))
publicWithTimeout mt req = requestWithTimeout mt (ApiRequest_Public req)

private :: (ToJSON rsp, FromJSON rsp, Request pub, Request priv) => priv rsp -> ClientApp select patch view pub priv (Either String rsp)
private req = do
  Just rsp <- privateWithTimeout Nothing req
  return rsp

public :: (ToJSON rsp, FromJSON rsp, Request pub, Request priv) => pub rsp -> ClientApp select patch view pub priv (Either String rsp)
public req = do
  Just rsp <- publicWithTimeout Nothing req
  return rsp

select :: forall select patch view pub priv. ToJSON select => select -> ClientApp select patch view pub priv (Maybe view)
select s = do
  env <- ask
  let conn = _clientEnv_websocket env
      sr = _clientEnv_currentSelector env
      vr = _clientEnv_currentView env
      tr = _clientEnv_token env
  _ <- liftIO $ tryTakeMVar vr
  _ <- liftIO $ swapMVar sr s
  mtoken <- liftIO $ readMVar tr
  case mtoken of
    Nothing -> return Nothing
    Just token -> do
      let payload :: WebSocketData (Signed AuthToken) select Value
          payload = WebSocketData_Listen (AppendMap $ Map.singleton token s)
      liftIO $ sendTextData conn $ encode payload
      liftIO (readMVar vr)

setToken :: Maybe (Signed AuthToken) -> ClientApp select patch view pub priv ()
setToken token = do
  mv <- asks _clientEnv_token
  liftIO $ modifyMVar_ mv (\_ -> return token)

listener :: forall select patch view. (Monoid select, FromJSON patch) => ClientEnv select patch view -> IO ()
listener env = forever $ runMaybeT $ do
  raw <- lift $ receiveData conn
  (mma :: Either String (WebSocketData (Signed AuthToken) patch (Either String Value))) <- MaybeT . return $ decodeValue' raw
  ma <- MaybeT . return . either (\_ -> Nothing) Just $ mma
  case ma of
    WebSocketData_Listen nmap -> lift $ withMVar token $ \case
        Nothing -> return ()
        Just t -> do
          withMVar selectorRef $ \s -> 
            withMVar patcherRef $ \patcher -> do
              mv <- fmap join $ tryTakeMVar viewRef
              putMVar viewRef $ do
                p <- nmap ^. at t
                return (patcher s p mv)
    WebSocketData_Api rid' eea -> do
      rid <- parseToMaybeT $ fromJSON rid'
      mp <- MaybeT $ tryReadMVar pending
      mv <- MaybeT . return $ Map.lookup rid mp
      lift (putMVar mv eea)
 where 
   conn = _clientEnv_websocket env
   token = _clientEnv_token env
   pending = _clientEnv_pending env
   patcherRef = _clientEnv_patcher env
   viewRef = _clientEnv_currentView env
   selectorRef = _clientEnv_currentSelector env
   parseToMaybeT r = MaybeT . return $ case r of
     Error _ -> Nothing
     Success r' -> Just r'
