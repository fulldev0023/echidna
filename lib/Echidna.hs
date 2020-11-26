{-# LANGUAGE FlexibleContexts #-}

module Echidna where

import Control.Lens (view, (^.), to)
import Data.Has (Has(..))
import Control.Monad.Catch (MonadCatch(..))
import Control.Monad.Reader (MonadReader, MonadIO, liftIO, when)
import Control.Monad.Random (MonadRandom)
import Data.Map.Strict (keys)
import Data.Text (pack)
import Data.Maybe (isJust, fromJust)

import Data.List (nub)
import qualified Data.HashMap.Strict as H

import EVM (env, contracts, VM)
import EVM.ABI (AbiValue(AbiAddress))
import EVM.Solidity (SourceCache, SolcContract)

import Echidna.ABI
import Echidna.Config
import Echidna.Solidity
import Echidna.Types.Campaign
import Echidna.Types.Random
import Echidna.Types.Tx
import Echidna.Types.World
import Echidna.Processor
import Echidna.RPC (loadEtheno, extractFromEtheno)
import Echidna.Output.Corpus

import qualified Data.List.NonEmpty as NE

-- | This function is used to prepare, process, compile and initialize smart contracts for testing.
-- It takes:
-- * A config record
-- * A list of contract files paths for the smart contract code
-- * A contract name (if any)
-- * A seed used during the random generation
-- and returns:
-- * A VM with the contract deployed and ready for testing
-- * A World with all the required data for generating random transctions
-- * A list of Echidna tests to check
-- * A prepopulated dictionary (if any)
-- * A list of transaction sequences to initialize the corpus
prepareContract :: (MonadCatch m, MonadRandom m, MonadReader x m, MonadIO m, MonadFail m,
                    Has TxConf x, Has SolConf x)
                => EConfig -> NE.NonEmpty FilePath -> Maybe String -> Seed -> m (VM, SourceCache, [SolcContract], World, [SolTest], Maybe GenDict, [[Tx]])
prepareContract cfg fs c g = do
  ctxs <- liftIO $ loadTxs cd

  -- compile and load contracts
  (cs, sc) <- Echidna.Solidity.contracts fs
  ads <- addresses
  p <- loadSpecified (pack <$> c) (cs, sc)

  -- run processors
  ca <- view (hasLens . cryticArgs)
  si <- runSlither (NE.head fs) ca
  when (null si) $ liftIO $ putStrLn "WARNING: slither failed to run or extracted no information at all"

  -- filter extracted constants
  let extractedConstants = filterConstantValue si

  -- load tests
  (v, w, ts) <- prepareForTest p c si
  let ads' = AbiAddress <$> v ^. env . EVM.contracts . to keys

  -- get signatures
  let sigs = concat $ map (NE.toList . snd) $ H.toList $ w ^. highSignatureMap

  -- load transactions from test sample (if any)
  liftIO $ putStrLn "Reading test samples and de-duplicating dataset"
  es <- liftIO $ if (isJust tf) then loadEtheno (fromJust tf) else return []
  let stxs = concat $ extractFromEtheno es sigs

  -- load transactions from test sample (if any)
  liftIO $ putStrLn "Reading test samples and de-duplicating dataset"
  es' <- liftIO $ if (isJust it) then loadEtheno (fromJust it) else return []
  let itxs = extractFromEtheno es' sigs

  let txs = nub $ ctxs ++ itxs ++ [stxs]
  liftIO $ putStrLn ("Done. Processed a dataset with " ++ show (length txs) ++ " sequences of transactions")
  
  -- start ui and run tests
  return (v, sc, cs, w, ts, Just $ mkGenDict df (extractedConstants ++ timeConstants ++ largeConstants ++ NE.toList ads ++ ads') [] g (returnTypes cs), txs)
  where cd = cfg ^. cConf . corpusDir
        tf = cfg ^. cConf . testSamples
        it = cfg ^. sConf . initialize
        df = cfg ^. cConf . dictFreq
