{-# LANGUAGE FlexibleContexts, KindSignatures, LambdaCase, StrictData #-}

module Echidna.Exec (
    ExecEnv(..)
  , checkETest
  , eCommand
  , eCommandCoverage
  , ePropertySeq
  , ePropertySeqCoverage
  , execCall
  , execCallCoverage
  , fuzz
  , mutateGoodInputs
  , module Echidna.Internal.Runner
  ) where

import Control.Concurrent.MVar    (MVar, takeMVar, putMVar)
import Control.Concurrent.Chan    (Chan, writeChan, readChan)
import Control.Lens               ((^.), (.=), use)
import Control.Monad              (forM_, replicateM, forever)
import Control.Monad.Catch        (MonadCatch)
import Control.Monad.IO.Class     (MonadIO, liftIO)
import Control.Monad.State.Strict (MonadState, StateT, evalState, evalStateT, execState, runState)
import Control.Monad.Reader       (MonadReader, ReaderT, runReaderT, ask)
import Data.IORef                 (IORef, modifyIORef', newIORef, readIORef)
import Data.List                  (intercalate)
import Data.Maybe                 (listToMaybe)
import Data.Set                   (Set, insert, union, size, difference)
import Data.Text                  (Text)
import Data.Typeable              (Typeable)
import Data.Vector                (fromList)

import qualified Control.Monad.State.Strict as S

import Hedgehog
import Hedgehog.Gen               (sample, sequential)
import Hedgehog.Internal.State    (Action(..))
import Hedgehog.Internal.Property (PropertyConfig(..), mapConfig)
import Hedgehog.Range             (linear)

import EVM          (VM, VMResult(..), calldata, exec1, pc, result, stack, state)
import EVM.ABI      (AbiValue(..), abiCalldata, abiValueType, encodeAbiValue)
import EVM.Concrete (Blob(..))
import EVM.Exec     (exec)

import Echidna.ABI (SolCall, SolSignature, displayAbiCall, encodeSig, genInteractions)
import Echidna.Internal.Runner

  
data ExecEnv = ExecEnv
  { coverage :: Coverage --Cumulative coverage accross all tests
  , recent   :: [Int] -- Coverage for previous 10 tests
  , avg      :: Float -- Moving average of coverage for prior tests
  }  

type Coverage    = Set Int      
type CoverageRef = IORef Coverage

--This doesn't do anything right now... but it will be a thread that processes inputs
--deemed interesting from a channel
mutateGoodInputs :: Chan [SolSignature] -> IO ()
mutateGoodInputs c = forever $ do
  input <- readChan c
  return ()

updateExecEnv :: ExecEnv -> Coverage -> ExecEnv
updateExecEnv ExecEnv{coverage = c, recent = r, avg = a} cov = ExecEnv { coverage = c', recent = r', avg = a'}
  where c' = union c cov
        r' = (size cov) : (take 5 r)
        a' = fromIntegral $ (sum r) `div` (length r)

-- Use to determine if input is worth handing off to the "good input" pool for mutation
-- Currently just sees if current input has higher than avg new pc's
isInteresting :: ExecEnv -> Coverage -> Bool
isInteresting e c = if fromIntegral (size new) > avg e then True else False
  where new = coverage e `difference` c

execCallUsing :: MonadState VM m => m VMResult -> SolCall -> m VMResult
execCallUsing m (t,vs) = cleanUp >> (state . calldata .= cd >> m) where
  cd = B . abiCalldata (encodeSig t $ abiValueType <$> vs) $ fromList vs

  cleanUp = sequence_ [result .= Nothing, state . pc .= 0, state . stack .= mempty]


execCall :: MonadState VM m => SolCall -> m VMResult
execCall = execCallUsing exec


execCallCoverage :: (MonadState VM m, MonadReader CoverageRef m, MonadIO m) => SolCall -> m VMResult
execCallCoverage = execCallUsing (go mempty) where
  go c = use result >>= \case
    Just x -> do ref <- ask
                 liftIO $ modifyIORef' ref (union c)
                 return x
    _      -> do current <- use $ state . pc
                 S.state (runState exec1)
                 go $ insert current c


fuzz :: MonadIO m
     => Int                 -- Call sequence length
     -> Int                 -- Number of iterations
     -> [SolSignature]      -- Type signatures to call
     -> VM                  -- Initial state
     -> (VM -> m Bool)      -- Predicate to fuzz for violations of
     -> m (Maybe [SolCall]) -- Call sequence to violate predicate (if found)
fuzz l n ts v p = do
  callseqs <- replicateM n (replicateM l . sample $ genInteractions ts)
  results <- zip callseqs <$> mapM run callseqs
  return $ listToMaybe [cs | (cs, passed) <- results, not passed]
    where run cs = p $ execState (forM_ cs execCall) v


checkETest :: VM -> Text -> Bool
checkETest v t = case evalState (execCall (t, [])) v of
  VMSuccess (B s) -> s == encodeAbiValue (AbiBool True)
  _               -> False


newtype VMState (v :: * -> *) =
  VMState VM
 
instance Show (VMState v) where
  show (VMState v) = "EVM state, current result: " ++ show (v ^. result)
 
newtype VMAction (v :: * -> *) = 
  Call SolCall
 
instance Show (VMAction v) where
  show (Call c) = displayAbiCall c

instance HTraversable VMAction where
  htraverse _ (Call b) = pure $ Call b


eCommandUsing :: (MonadGen n, MonadTest m, Typeable a)
              => (VMAction Concrete -> m a)
              -> (VM -> Bool)
              -> [SolSignature]
              -> Command n m VMState
eCommandUsing o p ts = Command (\_ -> pure $ Call <$> genInteractions ts) o
  [ Ensure $ \_ (VMState v) _ _ -> assert $ p v
  , Update $ \(VMState v) (Call c) _ -> VMState $ execState (execCall c) v
  ]
  

eCommand :: (MonadGen n, MonadTest m) => (VM -> Bool) -> [SolSignature] -> Command n m VMState
eCommand = eCommandUsing (\_ -> pure ())


eCommandCoverage :: (MonadGen n, MonadTest m, MonadState VM m, MonadReader CoverageRef m, MonadIO m)
                 => (VM -> Bool) -> [SolSignature] -> Command n m VMState
eCommandCoverage = eCommandUsing $ \(Call c) -> execCallCoverage c

ePropertyUsing :: (MonadCatch m, MonadTest m)
             => Command Gen m VMState
             -> (m () -> PropertyT IO ())
             -> VM          
             -> Int        
             -> Property
ePropertyUsing c f v n = mapConfig (\x -> x {propertyTestLimit = 10000}) . property $
  f . executeSequential (VMState v) =<< forAllWith printCallSeq
  (sequential (linear 1 n) (VMState v) [c]) where
    printCallSeq = ("Call sequence: " ++) . intercalate "\n               " .
      map showCall . sequentialActions
    showCall (Action i _ _ _ _ _) = show i ++ ";"


ePropertySeq :: (VM -> Bool)   -- Predicate to fuzz for violations of
             -> [SolSignature] -- Type signatures to fuzz
             -> VM             -- Initial state
             -> Int            -- Max actions to execute
             -> Property
ePropertySeq p ts = ePropertyUsing (eCommand p ts) id             


ePropertySeqCoverage :: MVar ExecEnv
                     -> Chan [SolSignature]
                     -> (VM -> Bool)
                     -> [SolSignature]
                     -> VM
                     -> Int
                     -> Property
ePropertySeqCoverage execEnvRef goodInputs p ts v = ePropertyUsing (eCommandCoverage p ts) writeCoverage v where
  writeCoverage :: MonadIO m => ReaderT CoverageRef (StateT VM m) a -> m a
  writeCoverage m = do
    threadCovRef <- liftIO $ newIORef mempty
    let s = runReaderT m threadCovRef
    a          <- evalStateT s v
    threadCov  <- liftIO $ readIORef threadCovRef
    execEnv    <- liftIO $ takeMVar execEnvRef
    liftIO $ if isInteresting execEnv threadCov then writeChan goodInputs ts else return ()
    liftIO $ putMVar execEnvRef (updateExecEnv execEnv threadCov)
    return a
  

-- Should work, but missing instance MonadBaseControl b m => MonadBaseControl b (PropertyT m)
-- ePropertyPar :: VM                  -- Initial state
             -- -> [(Text, [AbiType])] -- Type signatures to fuzz
             -- -> (VM -> Bool)        -- Predicate to fuzz for violations of
             -- -> Int                 -- Max size
             -- -> Int                 -- Max post-prefix size
             -- -> Property
-- ePropertyPar v ts p n m = withRetries 10 . property $ executeParallel (Current v) =<<
--   forAll (parallel (linear 1 n) (linear 1 m) (Current v) [eCommand v ts p])
