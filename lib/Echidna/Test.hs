{-# LANGUAGE FlexibleContexts #-}

module Echidna.Test where

import Prelude hiding (Word)

import Control.Lens
import Control.Monad ((<=<))
import Control.Monad.Catch (MonadThrow)
import Control.Monad.Random.Strict (MonadRandom, getRandomR, uniform, uniformMay)
import Control.Monad.Reader.Class (MonadReader)
import Control.Monad.State.Strict (MonadState(get, put), gets)
import Data.Foldable (traverse_)
import Data.Has (Has(..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.DoubleWord (Int256)
import EVM (Error(..), VMResult(..), VM, calldata, result, tx, state, substate, selfdestructs)
import EVM.ABI (AbiValue(..), AbiType(..), encodeAbiValue, decodeAbiValue, )
import EVM.Types (Addr)

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS

import qualified Data.Text as T

import Echidna.ABI
import Echidna.Events (Events, EventMap, extractEvents)
import Echidna.Exec
import Echidna.Transaction
import Echidna.Types.Buffer (viewBuffer)
import Echidna.Types.Test
import Echidna.Types.Signature (SolSignature)
import Echidna.Types.Tx (Tx, TxConf, basicTx, TxResult(..), getResult, propGas, src)

--- | Possible responses to a call to an Echidna test: @true@, @false@, @REVERT@, and ???.
data CallRes = ResFalse | ResTrue | ResRevert | ResOther
  deriving (Eq, Show)

--- | Given a 'VMResult', classify it assuming it was the result of a call to an Echidna test.
classifyRes :: VMResult -> CallRes
classifyRes (VMSuccess b) | viewBuffer b == Just (encodeAbiValue (AbiBool True))  = ResTrue
                          | viewBuffer b == Just (encodeAbiValue (AbiBool False)) = ResFalse
                          | otherwise                                             = ResOther
classifyRes Reversion = ResRevert
classifyRes _         = ResOther


getResultFromVM :: VM -> TxResult
getResultFromVM vm =
  case (vm ^. result) of
    Just r -> getResult r
    Nothing -> error "getResultFromVM failed"

createTest :: TestType -> EchidnaTest
createTest m =  EchidnaTest (Open (-1)) m v [] Stop []   
                where v = case m of 
                           PropertyTest _ _     -> BoolValue True
                           OptimizationTest _ _ -> IntValue minBound
                           _                    -> NoValue

assertPanicTest :: EchidnaTest
assertPanicTest = createTest $ CallTest "Assertion failure detector" (checkPanicEvent "1")

integerOverflowTest :: EchidnaTest
integerOverflowTest = createTest $ CallTest "Integer overflow detector" (checkPanicEvent "17")

isAssertionMode :: TestMode -> Bool
isAssertionMode "assertion" = True
isAssertionMode _           = False

isExplorationMode :: TestMode -> Bool
isExplorationMode "exploration" = True
isExplorationMode _             = False

createTests :: TestMode -> [Text] -> Addr -> [SolSignature] -> [EchidnaTest]
createTests m ts r ss = case m of
  "exploration" -> [createTest Exploration]
  "property"    -> map (\t -> createTest (PropertyTest t r)) ts ++ [sdt]
  "optimization" -> map (\t -> createTest (OptimizationTest t r)) ts
  "assertion"   -> (map (\s -> createTest (AssertionTest s r)) $ drop 1 ss) ++ [createTest (CallTest "AssertionFailed(..)" checkAssertionEvent), assertPanicTest, integerOverflowTest, sdt]
  _             -> error "Invalid test mode"
 where sdt = createTest (CallTest "Target contract is not self-destructed" $ checkSelfDestructedTarget r)
       sdat =  createTest (CallTest "No contract can be self-destructed" $ checkAnySelfDestructed)

updateOpenTest :: EchidnaTest -> [Tx] -> Int -> (TestValue, Events, TxResult) -> EchidnaTest
updateOpenTest test txs i (BoolValue False,es,r) = test { _testState = Large (-1), _testReproducer = txs, _testEvents = es, _testResult = r } 
updateOpenTest test _   i (BoolValue True,_,_)   = test { _testState = Open (i + 1) } 


updateOpenTest test txs i (IntValue v',es,r) = if v' > v then test { _testState = Open (i + 1), _testReproducer = txs, _testValue = IntValue v', _testEvents = es, _testResult = r } 
                                                         else test { _testState = Open (i + 1) }
                                                where v = case (test ^. testValue) of
                                                           IntValue x -> x
                                                           _          -> error "Invalid type of value for optimization" 


updateOpenTest test _ _ _                       = error "Invalid type of test"

-- | Given a 'SolTest', evaluate it and see if it currently passes.
checkETest :: (MonadReader x m, Has TestConf x, Has TxConf x, MonadState y m, Has VM y, MonadThrow m)
           => EventMap -> EchidnaTest -> m (TestValue, Events, TxResult)

checkETest em t = case (t ^. testType) of
                  Exploration           -> return (BoolValue True, [], Stop) -- These values are never used
                  PropertyTest n a      -> checkProperty em (n, a)
                  OptimizationTest n a  -> checkOptimization em (n, a) 
                  AssertionTest n a     -> checkAssertion em (n, a)
                  CallTest _ f          -> checkCall em f
                  _                     -> error "unhandled test"

checkProperty :: (MonadReader x m, Has TestConf x, Has TxConf x, MonadState y m, Has VM y, MonadThrow m)
           => EventMap -> (Text, Addr) -> m (TestValue, Events, TxResult)
checkProperty em t = do
    r <- use (hasLens . result)
    case r of
      Just (VMSuccess _) -> checkProperty' em t
      _                  -> return (BoolValue True, [], Stop) -- These values are never used

-- | Given a property test, evaluate it and see if it currently passes.
checkProperty' :: (MonadReader x m, Has TestConf x, Has TxConf x, MonadState y m, Has VM y, MonadThrow m)
           => EventMap -> (Text, Addr) -> m (TestValue, Events, TxResult)
checkProperty' em (f,a) = do
  TestConf p s <- view hasLens
  vm <- get -- save EVM state
  -- Our test is a regular user-defined test, we exec it and check the result
  g <- view (hasLens . propGas)
  _  <- execTx $ basicTx f [] (s a) a g (0, 0)
  vm' <- use hasLens
  b  <- gets $ p f . getter
  put vm -- restore EVM state
  pure $ (BoolValue b, extractEvents em vm', getResultFromVM vm')

--- | TODO.
getIntFromResult :: Maybe VMResult -> TestValue
getIntFromResult (Just (VMSuccess b)) = case (viewBuffer b) of
                           Nothing -> error "invalid decode of buffer"
                           Just bs -> case (decodeAbiValue (AbiIntType 256) $ LBS.fromStrict bs) of
                                        AbiInt 256 n -> IntValue $ n
                                        _            -> error "invalid decode of int256"
getIntFromResult _ = IntValue minBound

-- | Given a property test, evaluate it and see if it currently passes.
checkOptimization :: (MonadReader x m, Has TestConf x, Has TxConf x, MonadState y m, Has VM y, MonadThrow m)
           => EventMap -> (Text, Addr) -> m (TestValue, Events, TxResult)
checkOptimization em (f,a) = do
  TestConf p s <- view hasLens
  vm <- get -- save EVM state
  -- Our test is a regular user-defined test, we exec it and check the result
  g <- view (hasLens . propGas)
  _  <- execTx $ basicTx f [] (s a) a g (0, 0)
  vm' <- use hasLens
  put vm -- restore EVM state
  pure $ (getIntFromResult (vm' ^. result), extractEvents em vm', getResultFromVM vm')


checkAssertion :: (MonadReader x m, Has TestConf x, Has TxConf x, MonadState y m, Has VM y, MonadThrow m)
           => EventMap -> (SolSignature, Addr) -> m (TestValue, Events, TxResult)
checkAssertion em (s, _) =
  -- To check these tests, we're going to need a couple auxilary functions:
  --   * matchR[eturn] checks if we just tried to exec 0xfe, which means we failed an assert
  --   * matchC[alldata] checks if we just executed the function we thought we did, based on calldata
  let matchR (Just (VMFailure (UnrecognizedOpcode 0xfe))) = False
      matchR _                                            = True
      matchC sig b = case viewBuffer b of
        Just cd -> not . BS.isPrefixOf (BS.take 4 (abiCalldata (encodeSig sig) mempty)) $ cd
        Nothing -> False 
  in do
    vm' <- use hasLens
    let correctFn = matchC s $ vm' ^. state . calldata . _1
        ret = matchR $ vm' ^. result
    pure $ (BoolValue $ correctFn || ret, extractEvents em vm', getResultFromVM vm')

checkCall :: (MonadReader x m, Has TestConf x, Has TxConf x, MonadState y m, Has VM y, MonadThrow m)
           => EventMap -> (EventMap -> VM -> Bool) -> m (TestValue, Events, TxResult)
checkCall em f = do 
  vm <- use hasLens
  pure $ (BoolValue $ f em vm, extractEvents em vm, getResultFromVM vm)

checkAssertionEvent :: EventMap -> VM -> Bool
checkAssertionEvent em vm = 
  let es = extractEvents em vm
  in null es || not (any (T.isPrefixOf "AssertionFailed(") es)

checkSelfDestructedTarget :: Addr -> EventMap -> VM -> Bool
checkSelfDestructedTarget a _ vm =
  let sd = vm ^. tx ^. substate ^. selfdestructs 
  in not $ a `elem` sd


checkAnySelfDestructed :: EventMap -> VM -> Bool
checkAnySelfDestructed _ vm =
  let sd = vm ^. tx ^. substate ^. selfdestructs 
  in (length sd) == 0

checkPanicEvent :: T.Text -> EventMap -> VM -> Bool
checkPanicEvent n em vm = 
  let es = extractEvents em vm
  in null es || not (any (T.isPrefixOf ("Panic(" <> n <> ")")) es)

--checkErrorEvent :: EventMap -> VM -> Bool
--checkErrorEvent em vm = 
--  let es = extractEvents em vm
--  in null es || not (any (T.isPrefixOf "Error(") es)
