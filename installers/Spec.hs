{-# LANGUAGE OverloadedStrings, NoImplicitPrelude, LambdaCase #-}
module Main where

import Universum hiding (FilePath, fold)
import Test.Hspec
import qualified Data.Text as T
import Filesystem.Path (FilePath, (</>))
import Filesystem.Path.CurrentOS (fromText, encodeString, decodeString)
import System.IO.Temp (getCanonicalTemporaryDirectory)
import Turtle (mktempdir, inproc, strict, ls, fold, writeTextFile, mktree, mkdir, cptree, cp, format)
import Control.Monad.Managed (MonadManaged, runManaged)
import Data.Aeson.Types (Value)
import Data.Aeson.Lens
import qualified Control.Foldl as Fold

import Config
import Types
import qualified MacInstaller as Mac

main :: IO ()
main = hspec $ do
  describe "Utility functions" utilSpec
  describe "MacInstaller build" macBuildSpec
  describe "Config generation" configSpec

macBuildSpec :: Spec
macBuildSpec = do
  describe "The whole thing" $ do
    it "Runs through the whole installer build" $ runManaged $ do
      out <- getTempDir "test-build"
      installersDir <- makeTestInstallersDir
      daedalusBridge <- liftIO getDaedalusBridge

      let opts = Options
                 { oOS = Win64
                 , oBackend = Cardano daedalusBridge
                 , oBuildJob = Just (BuildJob "test")
                 , oCluster = Mainnet
                 , oAppName = "Daedalus"
                 , oOutputDir = out
                 , oTestInstaller = testInstaller False
                 }

      liftIO $ do
        Mac.withDir installersDir $ Mac.main opts

        -- there should be an installer file at the end
        fold (ls out) Fold.length `shouldReturn` 1

  describe "Cardano version file" $ do
    it "Reads it" $ runManaged $ do
      tmp <- getTempDir "test-bridge"
      liftIO $ writeTextFile (tmp </> "version") "1.2.3"
      liftIO $ Mac.readCardanoVersionFile tmp `shouldReturn` "cardano-sl-1.2.3"
    it "Handles missing version file" $ runManaged $ do
      tmp <- getTempDir "test-bridge"
      liftIO $ Mac.readCardanoVersionFile tmp `shouldReturn` "UNKNOWN"

-- | Set up a temporary source/installers directory with everything
-- required for the installer builder. This is so that the installer
-- builder can be tested in a pure environment without any
-- dependencies.
makeTestInstallersDir :: MonadManaged m => m FilePath
makeTestInstallersDir = do
  src <- getTempDir "test-source"
  liftIO $ writeTextFile (src </> "package.json") "{ \"version\": \"0.4.2\" }"
  let installersDir = src </> "installers"
  mkdir installersDir
  cptree "dhall" (installersDir </> "dhall")
  forM ["ca.conf", "server.conf", "client.conf", "build-certificates-unix.sh"] $ \f ->
    cp f (installersDir </> f)
  mktree (installersDir </> "data/scripts")
  pure installersDir

-- | Run a special command to get the cardano-sl.daedalus-bridge path.
getDaedalusBridge :: IO FilePath
getDaedalusBridge = fromText . T.stripEnd <$> strict (inproc "daedalus-bridge" [] empty)

configSpec :: Spec
configSpec = do
  describe "Config file generation" $ do
    it "Generates something" $ do
      dhallTest Win64 Staging Launcher "./dhall" $ \val -> do
        val^.key "reportServer"._String `shouldSatisfy` (T.isInfixOf "iohkdev.io")
        val^.key "configuration".key "key"._String `shouldBe` "mainnet_dryrun_wallet_win64"

type Yuck = Value -> IO ()

dhallTest :: OS -> Cluster -> Config -> FilePath -> Yuck -> IO ()
dhallTest os cluster cfg root yuck =
  forConfigValues (format dfp root) os cluster
  (\cfg' val -> when (cfg == cfg') (yuck val))

getTempDir :: MonadManaged io => Text -> io FilePath
getTempDir template = do
  tmp <- liftIO . fmap decodeString $ getCanonicalTemporaryDirectory
  mktempdir tmp template

utilSpec :: Spec
utilSpec = do
  describe "Daedalus version loading" $ do
    xit "loads the actual version file" $ do
      -- referring to parent directory won't work in nix-build
      Version ver <- getDaedalusVersion "../package.json"
      ver `shouldSatisfy` (not . T.null)

    it "loads a version file" $ do
      packageVersion "{ \"version\": \"1.1.1\" }" `shouldReturn` (Version "1.1.1")

  describe "Package filename generation" $ do
    it "generates a good filename for windows" $ do
      let f = packageFileName Win64 Mainnet (Version "0.4.2") "test-9.9" (Just "job.id")
      f `shouldBe` (fromText "daedalus-0.4.2-test-9.9-mainnet-windows-job.id.exe")
