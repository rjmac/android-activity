{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving, StandaloneDeriving, FlexibleInstances, MultiParamTypeClasses, FlexibleContexts, TypeFamilies, UndecidableInstances, FunctionalDependencies, RankNTypes, RecursiveDo, ScopedTypeVariables, OverloadedStrings #-}
module Focus.JS.App where

import Control.Lens ((^?), _Right)
import Control.Monad.Exception
import Control.Monad.Reader
import Control.Monad.Ref
import Data.Aeson
import qualified Data.ByteString.Lazy as LBS
import Data.Map (Map)
import Data.Monoid
import Data.Text (Text)
import Focus.Account
import Focus.Api
import Focus.App
import Focus.AppendMap (AppendMap (..))
import qualified Focus.AppendMap as AppendMap
import Focus.JS.Request
import Focus.JS.WebSocket
import Focus.Request
import Focus.Sign
import Focus.WebSocket
import Reflex.Dom hiding (MonadWidget, webSocket)
import Reflex.Host.Class

class (Monoid q, Query q) => MonadQuery t q m | m -> q t where
  tellQueryDyn :: Dynamic t q -> m ()
  askQueryResult :: m (Dynamic t (QueryResult q))
  queryDyn :: Dynamic t q -> m (Dynamic t (QueryResult q))

newtype QueryT t q m a = QueryT { unQueryT :: DynamicWriterT t q (ReaderT (Dynamic t (QueryResult q)) m) a } deriving (Functor, Applicative, Monad, MonadException, MonadFix, MonadIO, MonadHold t, MonadSample t, MonadAtomicRef)

instance MonadTrans (QueryT t q) where
  lift = QueryT . lift . lift

instance PostBuild t m => PostBuild t (QueryT t q m) where
  getPostBuild = lift getPostBuild

instance (MonadAsyncException m) => MonadAsyncException (QueryT t q m) where
  mask f = QueryT $ mask $ \unMask -> unQueryT $ f $ QueryT . unMask . unQueryT

instance TriggerEvent t m => TriggerEvent t (QueryT t q m) where
  newTriggerEvent = lift newTriggerEvent
  newTriggerEventWithOnComplete = lift newTriggerEventWithOnComplete
  newEventWithLazyTriggerWithOnComplete = lift . newEventWithLazyTriggerWithOnComplete

instance (Monad m, Monoid q, Query q, Reflex t) => MonadQuery t q (QueryT t q m) where
  tellQueryDyn = QueryT . tellDyn
  askQueryResult = QueryT ask
  queryDyn q = do
    tellQueryDyn q
    r <- askQueryResult
    return $ zipDynWith crop q r

instance (Monad m, MonadQuery t q m) => MonadQuery t q (ReaderT r m) where
  tellQueryDyn = lift . tellQueryDyn
  askQueryResult = lift askQueryResult
  queryDyn = lift . queryDyn

instance PerformEvent t m => PerformEvent t (QueryT t q m) where
  type Performable (QueryT t q m) = Performable m
  performEvent_ = lift . performEvent_
  performEvent = lift . performEvent

instance HasJS x m => HasJS x (QueryT t q m) where
  type JSM (QueryT t q m) = JSM m
  liftJS = lift . liftJS

instance (Deletable t m, MonadFix m, MonadHold t m, Monoid q) => Deletable t (QueryT t q m) where
  deletable e = QueryT . deletable e . unQueryT

instance (DomBuilder t m, MonadFix m, MonadHold t m, Monoid q) => DomBuilder t (QueryT t q m) where
  type DomBuilderSpace (QueryT t q m) = DomBuilderSpace m
  textNode = QueryT . textNode
  element t e = QueryT . element t (fmap1 unQueryT e) . unQueryT
  placeholder = QueryT . placeholder . fmap1 unQueryT
  inputElement = QueryT . inputElement . fmap1 unQueryT
  textAreaElement = QueryT . textAreaElement . fmap1 unQueryT
  placeRawElement = QueryT . placeRawElement
  selectElement e = QueryT . selectElement (fmap1 unQueryT e) . unQueryT
  wrapRawElement r c = QueryT $ wrapRawElement r (fmap1 unQueryT c)

instance MonadRef m => MonadRef (QueryT t q m) where
  type Ref (QueryT t q m) = Ref m
  newRef = QueryT . newRef
  readRef = QueryT . readRef
  writeRef r = QueryT . writeRef r

instance HasWebView m => HasWebView (QueryT t q m) where
  type WebViewPhantom (QueryT t q m) = WebViewPhantom m
  askWebView = QueryT askWebView

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger t (QueryT t q m) where
  newEventWithTrigger = QueryT . newEventWithTrigger
  newFanEventWithTrigger a = QueryT . lift $ newFanEventWithTrigger a

runQueryT :: (MonadFix m, MonadHold t m, Monoid q, Reflex t) => QueryT t q m a -> Dynamic t (QueryResult q) -> m (a, Dynamic t q)
runQueryT (QueryT a) = runReaderT (runDynamicWriterT a)

mapQuery :: QueryMorphism q q' -> q -> q'
mapQuery = _queryMorphism_mapQuery

mapQueryResult :: QueryMorphism q q' -> QueryResult q' -> QueryResult q
mapQueryResult = _queryMorphism_mapQueryResult

withQueryT :: (MonadFix m, MonadHold t m, Monoid q, Monoid q', Query q', Reflex t)
           => QueryMorphism q q' 
           -> QueryT t q m a
           -> QueryT t q' m a
withQueryT f a = do
  r' <- askQueryResult
  (result, q) <- lift $ runQueryT a $ mapQueryResult f <$> r'
  tellQueryDyn $ mapQuery f <$> q
  return result

type FocusWidgetInternal app t m = QueryT t (ViewSelector app ()) (RequestT t (AppRequest app)  m)

newtype FocusWidget app t m a = FocusWidget { unFocusWidget :: FocusWidgetInternal app t m a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadFix, MonadException)

instance MonadTrans (FocusWidget app t) where
  lift = FocusWidget . lift . lift

instance HasJS x m => HasJS x (FocusWidget app t m) where
  type JSM (FocusWidget app t m) = JSM m
  liftJS = lift . liftJS

deriving instance (HasEnv app, MonadFix (WidgetHost m), MonadWidget' t m, Request (PublicRequest app), Request (PrivateRequest app)) => MonadRequest t (AppRequest app) (FocusWidget app t m)

instance PerformEvent t m => PerformEvent t (FocusWidget app t m) where
  type Performable (FocusWidget app t m) = Performable m
  performEvent_ = lift . performEvent_
  performEvent = lift . performEvent

instance TriggerEvent t m => TriggerEvent t (FocusWidget app t m) where
  newTriggerEvent = lift newTriggerEvent
  newTriggerEventWithOnComplete = lift newTriggerEventWithOnComplete
  newEventWithLazyTriggerWithOnComplete = lift . newEventWithLazyTriggerWithOnComplete

instance (HasView app, DomBuilder t m, MonadHold t m, Ref (Performable m) ~ Ref m, MonadFix m, MonadAtomicRef m) => DomBuilder t (FocusWidget app t m) where
  type DomBuilderSpace (FocusWidget app t m) = DomBuilderSpace m
  textNode = liftTextNode
  element elementTag cfg (FocusWidget child) = FocusWidget $ element elementTag (fmap1 unFocusWidget cfg) child
  placeholder cfg = FocusWidget $ placeholder $ fmap1 unFocusWidget cfg
  inputElement cfg = FocusWidget $ inputElement $ fmap1 unFocusWidget cfg
  textAreaElement cfg = FocusWidget $ textAreaElement $ fmap1 unFocusWidget cfg
  selectElement cfg (FocusWidget child) = FocusWidget $ selectElement (fmap1 unFocusWidget cfg) child
  placeRawElement = FocusWidget . placeRawElement
  wrapRawElement e cfg = FocusWidget $ wrapRawElement e $ fmap1 unFocusWidget cfg

instance (HasView app, Deletable t m, MonadHold t m, MonadFix m) => Deletable t (FocusWidget app t m) where
  deletable delete (FocusWidget child) = FocusWidget $ deletable delete child

instance PostBuild t m => PostBuild t (FocusWidget app t m) where
  getPostBuild = lift getPostBuild

instance MonadRef m => MonadRef (FocusWidget app t m) where
  type Ref (FocusWidget app t m) = Ref m
  newRef = FocusWidget . newRef
  readRef = FocusWidget . readRef
  writeRef r = FocusWidget . writeRef r

instance MonadHold t m => MonadHold t (FocusWidget app t m) where
  hold a = FocusWidget . hold a
  holdDyn a = FocusWidget . holdDyn a
  holdIncremental a = FocusWidget . holdIncremental a

instance MonadSample t m => MonadSample t (FocusWidget app t m) where
  sample = FocusWidget . sample

instance HasWebView m => HasWebView (FocusWidget app t m) where
  type WebViewPhantom (FocusWidget app t m) = WebViewPhantom m
  askWebView = FocusWidget askWebView

instance MonadReflexCreateTrigger t m => MonadReflexCreateTrigger t (FocusWidget app t m) where
  newEventWithTrigger = FocusWidget . newEventWithTrigger
  newFanEventWithTrigger a = FocusWidget . lift $ newFanEventWithTrigger a

instance MonadRequest t req m => MonadRequest t req (QueryT t q m) where
  requesting = lift . requesting

-- class ( MonadWidget' t m
--       , MonadFix (WidgetHost m)
--       , MonadRequest t (AppRequest app) m
--       , HasFocus app
--       ) => MonadFocusWidget app t m | m -> app t where
--   askEnv :: m (Env app t)
--   tellInterest :: Dynamic t (ViewSelector app ()) -> m ()
--   getView :: m (Dynamic t (View app))

-- | This synonym adds constraints to MonadFocusWidget that are only available on the frontend, and not via backend rendering.
type MonadFocusFrontendWidget app t m =
    ( MonadFocusWidget app t m
    , DomBuilderSpace m ~ GhcjsDomSpace
    , MonadAsyncException m
    , MonadAsyncException (Performable m)
    )

class (HasView app) => HasEnv app where
  data Env app :: * -> *
  getToken :: Env app t -> Dynamic t (Maybe (Signed AuthToken)) -- This is a Maybe to handle logged-out interactions
  getViews :: Env app t -> Dynamic t (Map (Signed AuthToken) (View app))

class (HasRequest app, HasView app) => HasFocus app


class ( MonadWidget' t m
      , MonadFix (WidgetHost m)
      , MonadRequest t (AppRequest app) m
      , HasFocus app
      , MonadQuery t (ViewSelector app ()) m
      ) => MonadFocusWidget app t m | m -> app t

instance ( MonadWidget' t m
         , MonadFix (WidgetHost m)
         , MonadRequest t (AppRequest app) m
         , HasFocus app
         , MonadQuery t (ViewSelector app ()) m
         ) => MonadFocusWidget app t m 

--instance ( HasFocus app
--         , MonadFix (WidgetHost m)
--         , MonadWidget' t m
--         , MonadAtomicRef m
--         , MonadRequest t (AppRequest app) (FocusWidget app t m)
--         ) => MonadFocusWidget app t (FocusWidget app t m) where
--  askEnv = FocusWidget $ lift ask
--  tellInterest is = do
--    token <- asksEnv getToken
--    tellDyn $ zipDynWith (\mt is' -> maybe mempty (\t -> AppendMap (Map.singleton t is')) mt) token is
--  getView = do
--    token <- asksEnv getToken
--    views <- asksEnv getViews
--    return $ zipDynWith (maybe (const emptyView) (\t -> maybe emptyView id . Map.lookup t)) token views

watchViewSelector :: MonadFocusWidget app t m => Dynamic t (ViewSelector app ()) -> m (Dynamic t (View app))
watchViewSelector = queryDyn

-- watchViewSelectorLens :: (Monoid a, MonadFocusWidget app t m) => ASetter a (ViewSelector app ()) c b -> Dynamic t b -> m (Dynamic t (View app))
-- watchViewSelectorLens l sdyn = do
--   s <- mapDyn (\s' -> mempty & l .~ s') sdyn
--   tellInterest s
--   combineDyn cropView s =<< getView
--
-- watchViewSelectorLensSet :: (Monoid a, MonadFocusWidget app t m) => ASetter a (ViewSelector app ()) b (Set.Set c) -> Dynamic t c -> m (Dynamic t (View app))
-- watchViewSelectorLensSet l sdyn = watchViewSelectorLens l =<< mapDyn Set.singleton sdyn

-- asksEnv :: MonadFocusWidget app t m => (Env app t -> a) -> m a
-- asksEnv f = fmap f askEnv
-- 
-- asksView :: MonadFocusWidget app t m => ((View app) -> a) -> m (Dynamic t a)
-- asksView f = fmap f <$> getView


--TODO: HasDocument is still not accounted for
type MonadWidget' t m =
  ( DomBuilder t m
  , MonadFix m
  , MonadHold t m
  , MonadSample t (Performable m)
  , MonadReflexCreateTrigger t m
  , PostBuild t m
  , PerformEvent t m
  , MonadIO m
  , MonadIO (Performable m)
  , TriggerEvent t m
  , HasWebView m
  , HasWebView (Performable m)
  -- , MonadAsyncException m
  -- , MonadAsyncException (Performable m)
  , MonadRef m
  , Ref m ~ Ref IO
  , MonadRef (Performable m)
  , Ref (Performable m) ~ Ref IO
  )


runFocusWidget :: forall t m a x app. ( MonadWidget' t m
                                      , HasJS x m
                                      , HasFocus app
                                      , Eq (ViewSelector app ())
                                      )
               => Signed AuthToken
               -> FocusWidget app t m a
               -> m a
runFocusWidget token child = do
  pb <- getPostBuild
  rec (notification, response) <- openWebSocket "/listen" request updatedVS
      ((a, vs), request) <- flip runRequestT response $ runQueryT (withQueryT (singletonQuery token) (unFocusWidget child)) e
      let nubbedVs = uniqDyn vs
          updatedVS = leftmost [updated nubbedVs, tag (current nubbedVs) pb]
      e :: Dynamic t (AppendMap (Signed AuthToken) (QueryResult (ViewSelector app ()))) <- fromNotifications nubbedVs notification
  return a

fromNotifications :: forall m t k vs. (Query vs, MonadHold t m, Reflex t, MonadFix m, Ord k)
                  => Dynamic t (AppendMap k vs)
                  -> Event t (AppendMap k (QueryResult vs))
                  -> m (Dynamic t (AppendMap k (QueryResult vs)))
fromNotifications vs ePatch = do
  views <- foldDyn (\(vs', p) v -> applyAndCrop p vs' v) AppendMap.empty $ attach (current vs) ePatch
  return views
  where
    applyPatch' m0 m1 = AppendMap.mergeWithKey (\_ x y -> Just (x <> y)) id (const AppendMap.empty) m0 m1
    cropView' m0 m1 = AppendMap.mergeWithKey (\_ x y -> Just (cropView x y)) (fmap (\_ -> mempty)) (const AppendMap.empty) m0 m1
    applyAndCrop p vs' v = cropView' vs' $ applyPatch' p v

-- | Open a websocket connection and split resulting incoming traffic into listen notification and api response channels
openWebSocket :: forall t x m vs v.
                 ( Reflex t, MonadIO m, MonadIO (Performable m), PostBuild t m, TriggerEvent t m, PerformEvent t m, HasWebView m, HasJS x m
                 , FromJSON v, ToJSON vs
                 )
              => Text -- ^ URL
              -> Event t [(Data.Aeson.Value, Data.Aeson.Value)] -- ^ Outbound requests
              -> Event t (AppendMap (Signed AuthToken) vs) -- ^ Authenticated listen requests (e.g., ViewSelector updates)
              -> m ( Event t (AppendMap (Signed AuthToken) v)
                   , Event t (Data.Aeson.Value, Either Text Data.Aeson.Value)
                   )
openWebSocket url request updatedVs = do
      (eMessages :: Event t (Either Text (WebSocketData (AppendMap (Signed AuthToken) v) (Either Text Data.Aeson.Value)))) <- liftM (fmapMaybe (decodeValue' . LBS.fromStrict) . _webSocket_recv) $
        webSocket url $ WebSocketConfig $ fmap (map (LBS.toStrict . encode)) $ mconcat
          [ fmap (map (uncurry WebSocketData_Api)) request
          , fmap ((:[]) . WebSocketData_Listen) updatedVs
          ]
      --TODO: Handle parse errors returned by the backend
      let notification = fmapMaybe (^? _Right . _WebSocketData_Listen) eMessages
          response = fmapMaybe (^? _Right . _WebSocketData_Api) eMessages
      return (notification, response)

