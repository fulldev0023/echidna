{-# LANGUAGE FlexibleContexts #-}

module Echidna.Test where

import Prelude hiding (Word)

import Control.Lens
import Control.Monad ((<=<), ap)
import Control.Monad.Catch (MonadThrow)
import Control.Monad.Random.Strict (MonadRandom, getRandomR, uniform, uniformMay)
import Control.Monad.Reader.Class (MonadReader, asks)
import Control.Monad.State.Strict (MonadState(get, put), gets)
import Data.Bool (bool)
import Data.Foldable (traverse_)
import Data.Has (Has(..))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import EVM (Error(..), VMResult(..), VM, calldata, result, state)
import EVM.Types (Addr)

import qualified Data.ByteString as BS

import Echidna.ABI
import Echidna.ABIv2 (abiCalldata2, AbiValue2(..), encodeAbiValue2)
import Echidna.Exec
import Echidna.Solidity
import Echidna.Transaction

-- | Configuration for evaluating Echidna tests.
data TestConf = TestConf { classifier :: Text -> VM -> Bool
                           -- ^ Given a VM state and test name, check if a test just passed (typically
                           -- examining '_result'.)
                         , testSender :: Addr -> Addr
                           -- ^ Given the address of a test, return the address to send test evaluation
                           -- transactions from.
                         }

-- | Possible responses to a call to an Echidna test: @true@, @false@, @REVERT@, and ???.
data CallRes = ResFalse | ResTrue | ResRevert | ResOther deriving (Eq, Show)

-- | Given a 'VMResult', classify it assuming it was the result of a call to an Echidna test.
classifyRes :: VMResult -> CallRes
classifyRes (VMSuccess b) | b == encodeAbiValue2 (AbiBool2 True)  = ResTrue
                          | b == encodeAbiValue2 (AbiBool2 False) = ResFalse
                          | otherwise                             = ResOther

classifyRes Reversion = ResRevert
classifyRes _ = ResOther

-- | Given a 'SolTest', evaluate it and see if it currently passes.
checkETest :: (MonadReader x m, Has TestConf x, Has TxConf x, MonadState y m, Has VM y, MonadThrow m)
           => SolTest -> m Bool
checkETest t = asks getter >>= \(TestConf p s) -> view (hasLens . propGas) >>= \g -> do
  og <- get 
  -- To check these tests, we're going to need a couple auxilary functions:
  --   * matchR[eturn] checks if we just tried to exec 0xfe, which means we failed an assert
  --   * matchC[alldata] checks if we just executed the function we thought we did, based on calldata
  let matchR (Just (VMFailure (UnrecognizedOpcode 0xfe))) = False
      matchR _                                            = True
      matchC sig = not . (BS.isPrefixOf . BS.take 4 $ abiCalldata2 (encodeSig2 sig) mempty)
  res <- case t of
    -- If our test is a regular user-defined test, we exec it and check the result
    Left  (f, a) -> execTx2 (Tx2 (Left (f, [])) (s a) a g 0) >> gets (p f . getter)
    -- If our test is an auto-generated assertion test, we check if we failed an assert on that fn
    Right sig    -> (||) <$> fmap matchR       (use $ hasLens . result)
                         <*> fmap (matchC sig) (use $ hasLens . state . calldata)
  put og
  pure res

-- | Given a call sequence that solves some Echidna test, try to randomly generate a smaller one that
-- still solves that test.
shrinkSeq2 :: ( MonadRandom m, MonadReader x m, MonadThrow m
              , Has SolConf x, Has TestConf x, Has TxConf x, MonadState y m, Has VM y)
           => SolTest -> [Tx2] -> m [Tx2]
shrinkSeq2 t xs = sequence [shorten, shrunk] >>= uniform >>= ap (fmap . flip bool xs) check where
  check xs' = do {og <- get; res <- traverse_ execTx2 xs' >> checkETest t; put og; pure res}
  shrinkSender x = view (hasLens . sender) >>= \l -> case ifind (const (== x ^. src2)) l of
    Nothing     -> pure x
    Just (i, _) -> flip (set src2) x . fromMaybe (x ^. src2) <$> uniformMay (l ^.. folded . indices (< i))
  shrunk = mapM (shrinkSender <=< shrinkTx2) xs
  shorten = (\i -> take i xs ++ drop (i + 1) xs) <$> getRandomR (0, length xs)
