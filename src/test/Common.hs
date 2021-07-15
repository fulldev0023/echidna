module Common
  ( testConfig
  , runContract
  , testContract
  , testContractV
  , solcV
  , testContract'
  , checkConstructorConditions
  , solnFor
  , solved
  , passed
  , solvedLen
  , solvedWith
  , solvedWithout
  , solvedUsing
  , getGas
  , gasInRange
  , countCorpus
  , coverageEmpty
  ) where

import Prelude hiding (lookup)

import Test.Tasty (TestTree)
import Test.Tasty.HUnit (testCase, assertBool)

import Control.Lens (view, set, (.~), (^.))
import Control.Monad.Reader (runReaderT)
import Control.Monad.Random (getRandom)
import Control.Monad.State.Strict (evalStateT)
import Data.Function ((&))
import Data.List.NonEmpty (NonEmpty(..))
import Data.List.Split (splitOn)
import Data.Map (lookup, empty)
import Data.Maybe (isJust)
import Data.Text (Text, pack)
import Data.SemVer (Version, version, fromText)
import System.Process (readProcess)

import Echidna (prepareContract)
import Echidna.Campaign (campaign)
import Echidna.Config (EConfig, _econfig, parseConfig, defaultConfig, sConf, cConf)
import Echidna.Solidity (loadSolTests, quiet)
import Echidna.Test (checkETest)
import Echidna.Types.Campaign (Campaign, testLimit, shrinkLimit, tests, gasInfo, corpus, coverage)
import Echidna.Types.Signature (ContractName)
import Echidna.Types.Test
import Echidna.Types.Tx (Tx(..), TxCall(..), call)
import Echidna.Types.World (eventMap)

testConfig :: EConfig
testConfig = defaultConfig & sConf . quiet .~ True
                           & cConf . testLimit .~ 10000
                           & cConf . shrinkLimit .~ 4000

type SolcVersion = Version
type SolcVersionComp = Version -> Bool

solcV :: (Int, Int, Int) -> SolcVersion
solcV (x,y,z) = version x y z [] []

withSolcVersion :: Maybe SolcVersionComp -> IO () -> IO ()
withSolcVersion Nothing t = t
withSolcVersion (Just f) t = do
  sv <- readProcess "solc" ["--version"] ""
  let (_:sv':_) = splitOn "Version: " sv
  let (sv'':_) = splitOn "+" sv'
  case fromText $ pack sv'' of
    Right v' -> if f v' then t else assertBool "skip" True
    Left e   -> error $ show e

runContract :: FilePath -> Maybe ContractName -> EConfig -> IO Campaign
runContract f c cfg =
  flip runReaderT cfg $ do
    g <- getRandom
    (v, _, _, w, ts, d, txs) <- prepareContract cfg (f :| []) c g
    -- start ui and run tests
    campaign (pure ()) v w ts d txs

testContract :: FilePath -> Maybe FilePath -> [(String, Campaign -> Bool)] -> TestTree
testContract fp cfg = testContract' fp Nothing Nothing cfg True

testContractV :: FilePath -> Maybe SolcVersionComp -> Maybe FilePath -> [(String, Campaign -> Bool)] -> TestTree
testContractV fp v cfg = testContract' fp Nothing v cfg True

testContract' :: FilePath -> Maybe ContractName -> Maybe SolcVersionComp -> Maybe FilePath -> Bool -> [(String, Campaign -> Bool)] -> TestTree
testContract' fp n v cfg s as = testCase fp $ withSolcVersion v $ do
  c <- set (sConf . quiet) True <$> maybe (pure testConfig) (fmap _econfig . parseConfig) cfg
  let c' = c & sConf . quiet .~ True
             & (if s then cConf . testLimit .~ 10000 else id)
             & (if s then cConf . shrinkLimit .~ 4000 else id)
  res <- runContract fp n c'
  mapM_ (\(t,f) -> assertBool t $ f res) as

checkConstructorConditions :: FilePath -> String -> TestTree
checkConstructorConditions fp as = testCase fp $ do
  r <- flip runReaderT testConfig $ do
    (v, w, t) <- loadSolTests (fp :| []) Nothing
    let em = w ^. eventMap
    mapM (\u -> evalStateT (checkETest em u) v) t
  mapM_ (\(BoolValue b,_,_) -> assertBool as b) r


getResult :: Text -> Campaign -> Maybe EchidnaTest
getResult n c = 
  case filter findTest $ view tests c of
    []  -> Nothing
    [x] -> Just x
    _   -> error "found more than one tests"

  where findTest test = case view testType test of
                          PropertyTest t _      -> t == n
                          AssertionTest (t,_) _ -> t == n
                          CallTest t _          -> t == n
                          _                     -> False 

solnFor :: Text -> Campaign -> Maybe [Tx]
solnFor n c = case getResult n c of
  Just t -> if null $ t ^. testReproducer then Nothing else Just $ t ^. testReproducer 
  _      -> Just []

solved :: Text -> Campaign -> Bool
solved t = isJust . solnFor t

passed :: Text -> Campaign -> Bool
passed n c = case getResult n c of
  Just t | isPassed t -> True
  Just t | isOpen t   -> True
  Nothing             -> error ("no test was found with name: " ++ show n)
  _                   -> False

solvedLen :: Int -> Text -> Campaign -> Bool
solvedLen i t = (== Just i) . fmap length . solnFor t

solvedUsing :: Text -> Text -> Campaign -> Bool
solvedUsing f t = maybe False (any $ matchCall . view call) . solnFor t
                 where matchCall (SolCall (f',_)) = f' == f
                       matchCall _                = False

-- NOTE: this just verifies a call was found in the solution. Doesn't care about ordering/seq length
solvedWith :: TxCall -> Text -> Campaign -> Bool
solvedWith tx t = maybe False (any $ (== tx) . view call) . solnFor t

solvedWithout :: TxCall -> Text -> Campaign -> Bool
solvedWithout tx t = maybe False (all $ (/= tx) . view call) . solnFor t

getGas :: Text -> Campaign -> Maybe (Int, [Tx])
getGas t = lookup t . view gasInfo

gasInRange :: Text -> Int -> Int -> Campaign -> Bool
gasInRange t l h c = case getGas t c of
  Just (g, _) -> g >= l && g <= h
  _           -> False

countCorpus :: Int -> Campaign -> Bool
countCorpus n c = length (view corpus c) == n

coverageEmpty :: Campaign -> Bool
coverageEmpty c = view coverage c == empty
