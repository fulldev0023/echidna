module Main where

import Control.Lens hiding (argument)
import Control.Monad.Reader (runReaderT)
import Data.Text (pack)
import Options.Applicative
import System.Exit (exitWith, exitSuccess, ExitCode(..))

import Echidna.ABI
import Echidna.Config
import Echidna.Solidity
import Echidna.Campaign
import Echidna.UI

data Options = Options
  { filePath         :: FilePath
  , selectedContract :: Maybe String
  , configFilepath   :: Maybe FilePath
  }

options :: Parser Options
options = Options <$> argument str (metavar "FILE"
                        <> help "Solidity file to analyze")
                  <*> optional (argument str $ metavar "CONTRACT"
                        <> help "Contract to analyze")
                  <*> optional (option str $ long "config"
                        <> help "Config file")

opts :: ParserInfo Options
opts = info (options <**> helper) $ fullDesc
  <> progDesc "EVM property-based testing framework"
  <> header "Echidna"

main :: IO ()
main = do Options f c conf <- execParser opts
          cfg <- maybe (pure defaultConfig) parseConfig conf
          res <- flip runReaderT cfg $ do
            cs       <- contracts f
            (v,w,ts) <- loadSpecified (pack . (f ++) . (':' :) <$> c) cs >>= prepareForTest
            view tests <$> ui v w ts (Just $ mkGenDict 0.15 (extractConstants cs) [])
          if any (/= Passed) $ snd <$> res then exitWith $ ExitFailure 1 else exitSuccess
