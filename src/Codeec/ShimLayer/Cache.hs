{-# LANGUAGE ScopedTypeVariables, EmptyDataDecls, TemplateHaskell, DataKinds, OverloadedStrings, DoAndIfThenElse  #-}

module Codeec.ShimLayer.Cache (
  CacheManager,

  initCacheManager,
  getContext,
  addHotLocation,
  writeEffect,
  doesCacheInclude,
  waitForCacheRefresh,
  fetchUpdates,
  includedTxns,
  doesCacheIncludeTxns,
  fetchTxns,
  snapshotCache,
  getInclTxnsAt
) where

import Control.Concurrent
import Control.Concurrent.MVar
import Data.ByteString hiding (map, pack, putStrLn, foldl, length, filter)
import Control.Lens
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Map.Lens
import Control.Monad (forever, when, replicateM, foldM)
import Data.Maybe (fromJust)
import Database.Cassandra.CQL
import Control.Monad.State
import System.IO
import Control.Applicative ((<$>))
import Data.Tuple.Select

import Codeec.Types
import Codeec.ShimLayer.Types
import Codeec.DBDriver
import Codeec.ShimLayer.UpdateFetcher

makeLenses ''CacheManager

initCacheManager :: Pool -> IO CacheManager
initCacheManager pool = do
  cache <- newMVar M.empty
  cursor <- newMVar M.empty
  nearestDeps <- newMVar M.empty
  lastGC <- newMVar M.empty
  seenTxns <- newMVar (S.empty, M.empty)
  hwm <- newMVar M.empty
  hotLocs <- newMVar S.empty
  sem <- newEmptyMVar
  blockedList <- newMVar []
  let cm = CacheManager cache cursor nearestDeps lastGC seenTxns hwm hotLocs
                        sem blockedList pool
  forkIO $ cacheMgrCore cm
  forkIO $ signalGenerator sem
  return $ cm
  where
    signalGenerator semMVar = forever $ do
      isEmpty <- isEmptyMVar semMVar
      if isEmpty
      then tryPutMVar semMVar ()
      else return True
      threadDelay 1000000 -- 1 second

getInclTxnsAt :: CacheManager -> ObjType -> Key -> IO (S.Set TxnID)
getInclTxnsAt cm ot k = do
  inclTxns <- readMVar $ cm^.includedTxnsMVar
  case M.lookup (ot,k) $ sel2 inclTxns of
    Nothing -> return S.empty
    Just s -> return s

addHotLocation :: CacheManager -> ObjType -> Key -> IO ()
addHotLocation cm ot k = do
  hotLocs <- takeMVar $ cm^.hotLocsMVar
  putMVar (cm^.hotLocsMVar) $ S.insert (ot,k) hotLocs

cacheMgrCore :: CacheManager -> IO ()
cacheMgrCore cm = forever $ do
  takeMVar $ cm^.semMVar
  -- Woken up. Read the current list of hot locations, and empty the MVar.
  locs <- takeMVar $ cm^.hotLocsMVar
  putMVar (cm^.hotLocsMVar) S.empty
  -- Fetch updates
  fetchUpdates cm ONE $ S.toList locs
  -- Wakeup threads that are waiting for the cache to be refreshed
  blockedList <- takeMVar $ cm^.blockedMVar
  putMVar (cm^.blockedMVar) []
  mapM_ (\mv -> putMVar mv ()) blockedList

-- Returns the set of effects at the location and a set of nearest dependencies
-- for this location.
getContext :: CacheManager -> ObjType -> Key -> IO ([Effect], S.Set Addr)
getContext cm ot k = do
  cache <- takeMVar $ cm^.cacheMVar
  deps <- takeMVar $ cm^.depsMVar
  putMVar (cm^.cacheMVar) cache
  putMVar (cm^.depsMVar) deps
  let v1 = case M.lookup (ot,k) cache of
             Nothing -> []
             Just s -> Prelude.map (\(a,e) -> e) (S.toList s)
  let v2 = case M.lookup (ot,k) deps of {Nothing -> S.empty; Just s -> s}
  return (v1, v2)

writeEffect :: CacheManager -> ObjType -> Key -> Addr -> Effect -> S.Set Addr
            -> Consistency -> Maybe TxnID -> IO ()
writeEffect cm ot k addr eff deps const mbtxnid = do
  let Addr sid sqn = addr
  -- Does cache include the previous effect?
  isPrevEffectAvailable <- doesCacheInclude cm ot k sid (sqn - 1)
  let isTxn = case mbtxnid of {Nothing -> False; otherwise -> True}
  -- Only write to cache if the previous effect is available in the cache. This
  -- maintains the cache to be a causally consistent cut of the updates. But do
  -- not update cache if the effect is in a transaction. This prevents
  -- uncommitted effects from being made visible.
  when ((not isTxn) && (sqn == 1 || isPrevEffectAvailable)) $ do
    cache <- takeMVar $ cm^.cacheMVar
    cursor <- takeMVar $ cm^.cursorMVar
    -- curDeps may be different from the deps seen before the operation was performed.
    curDeps <- takeMVar $ cm^.depsMVar
    -- Update cache
    putMVar (cm^.cacheMVar) $ M.insertWith S.union (ot,k) (S.singleton (addr, eff)) cache
    -- Update cursor
    let cursorAtKey = case M.lookup (ot,k) cursor of {Nothing -> M.empty; Just m -> m}
    let newCursorAtKey = M.insert sid sqn cursorAtKey
    putMVar (cm^.cursorMVar) $ M.insert (ot,k) newCursorAtKey cursor
    -- Update dependence
    putMVar (cm^.depsMVar) $ M.insertWith S.union (ot,k) (S.singleton addr) curDeps
  -- Write to database
  runCas (cm^.pool) $ cqlInsert ot const k (sid, sqn, deps, EffectVal eff, mbtxnid)

doesCacheInclude :: CacheManager -> ObjType -> Key -> SessID -> SeqNo -> IO Bool
doesCacheInclude cm ot k sid sqn = do
  cursor <- readMVar $ cm^.cursorMVar
  case M.lookup (ot,k) cursor of
    Nothing -> return False
    Just cursorAtKey ->
      case M.lookup sid cursorAtKey of
        Nothing -> return False
        Just curSqn -> return $ (==) sqn curSqn

waitForCacheRefresh :: CacheManager -> ObjType -> Key -> IO ()
waitForCacheRefresh cm ot k = do
  hotLocs <- takeMVar $ cm^.hotLocsMVar
  blockedList <- takeMVar $ cm^.blockedMVar
  mv <- newEmptyMVar
  putMVar (cm^.hotLocsMVar) $ S.insert (ot,k) hotLocs
  putMVar (cm^.blockedMVar) $ mv:blockedList
  takeMVar mv

includedTxns :: CacheManager -> IO (S.Set TxnID)
includedTxns cm = do
  txns <- readMVar (cm^.includedTxnsMVar)
  return $ sel1 txns

doesCacheIncludeTxns :: CacheManager -> S.Set TxnID -> IO Bool
doesCacheIncludeTxns cm deps = do
  incl <- includedTxns cm
  return $ deps `S.isSubsetOf` incl

fetchTxns :: CacheManager -> S.Set TxnID -> IO ()
fetchTxns cm deps = do
  incl <- includedTxns cm
  let diffSet = S.difference deps incl
  objs <- foldM (\acc txid -> do
            objs <- getObjs txid
            return $ S.union acc objs) S.empty $ S.toList diffSet
  fetchUpdates cm ONE (S.toList objs)
  where
    getObjs txid = do
      res <- runCas (cm^.pool) $ readTxn txid
      case res of
        Nothing -> return $ S.empty
        Just s -> return $ S.map (\(TxnDep ot k _ _) -> (ot,k)) s

snapshotCache :: CacheManager -> IO CacheMap
snapshotCache cm = do
  readMVar $ cm^.cacheMVar
