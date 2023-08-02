{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Cardano.DbSync.Config.Node (
  NodeConfig (..),
  parseNodeConfig,
  parseSyncPreConfig,
  readByteStringFromFile,
) where

-- Node really should export something like this, but doesn't and it actually seemed to
-- be easier and faster to just parse out the bits we need here.

import qualified Cardano.Chain.Update as Byron
import Cardano.Crypto (RequiresNetworkMagic (..))
import Cardano.DbSync.Config.Types
import Cardano.Prelude
import Data.Aeson (FromJSON (..), Object, (.:), (.:?))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Char8 as BS
import Data.String (String)
import qualified Data.Yaml as Yaml
import qualified Ouroboros.Consensus.Cardano.CanHardFork as Shelley

data NodeConfig = NodeConfig
  { ncProtocol :: !SyncProtocol
  , ncPBftSignatureThreshold :: !(Maybe Double)
  , ncByronGenesisFile :: !GenesisFile
  , ncByronGenesisHash :: !GenesisHashByron
  , ncShelleyGenesisFile :: !GenesisFile
  , ncShelleyGenesisHash :: !GenesisHashShelley
  , ncAlonzoGenesisFile :: !GenesisFile
  , ncAlonzoGenesisHash :: !GenesisHashAlonzo
  , ncRequiresNetworkMagic :: !RequiresNetworkMagic
  , ncByronProtocolVersion :: !Byron.ProtocolVersion
  , -- Shelley hardfok parameters
    ncShelleyHardFork :: !Shelley.TriggerHardFork
  , -- Allegra hardfok parameters
    ncAllegraHardFork :: !Shelley.TriggerHardFork
  , -- Mary hardfok parameters
    ncMaryHardFork :: !Shelley.TriggerHardFork
  , -- Alonzo hardfok parameters
    ncAlonzoHardFork :: !Shelley.TriggerHardFork
  , -- Babbage hardfok parameters
    ncBabbageHardFork :: !Shelley.TriggerHardFork
  , -- Conway hardfok parameters
    ncConwayHardFork :: !Shelley.TriggerHardFork
  }

data NodeConfigParseError
  = NodeConfigParseError String
  | ParseSyncPreConfigError String
  | ReadByteStringFromFileError String
  deriving (Show)

instance Exception NodeConfigParseError

parseNodeConfig :: ByteString -> IO (Either NodeConfigParseError NodeConfig)
parseNodeConfig bs =
  case Yaml.decodeEither' bs of
    Left err -> pure $ Left $ NodeConfigParseError ("Error parsing node config: " <> show err)
    Right nc -> pure $ Right nc

parseSyncPreConfig :: ByteString -> IO (Either NodeConfigParseError SyncPreConfig)
parseSyncPreConfig bs =
  case Yaml.decodeEither' bs of
    Left err -> pure $ Left $ ParseSyncPreConfigError ("Error parseSyncPreConfig: Error parsing config: " <> show err)
    Right res -> pure $ Right res

readByteStringFromFile :: FilePath -> Text -> IO (Either NodeConfigParseError ByteString)
readByteStringFromFile fp cfgType = do
  result <- try (BS.readFile fp) :: IO (Either SomeException BS.ByteString)
  case result of
    Left _ -> pure $ Left $ ReadByteStringFromFileError ("Error Cannot find the " <> show cfgType <> " configuration file at : " <> show fp)
    Right res -> pure $ Right res

-- -------------------------------------------------------------------------------------------------

instance FromJSON NodeConfig where
  parseJSON v =
    Aeson.withObject "NodeConfig" parse v
    where
      parse :: Object -> Parser NodeConfig
      parse o =
        NodeConfig
          <$> (o .: "Protocol")
          <*> (o .:? "PBftSignatureThreshold")
          <*> fmap GenesisFile (o .: "ByronGenesisFile")
          <*> fmap GenesisHashByron (o .: "ByronGenesisHash")
          <*> fmap GenesisFile (o .: "ShelleyGenesisFile")
          <*> fmap GenesisHashShelley (o .: "ShelleyGenesisHash")
          <*> fmap GenesisFile (o .: "AlonzoGenesisFile")
          <*> fmap GenesisHashAlonzo (o .: "AlonzoGenesisHash")
          <*> (o .: "RequiresNetworkMagic")
          <*> parseByronProtocolVersion o
          <*> parseShelleyHardForkEpoch o
          <*> parseAllegraHardForkEpoch o
          <*> parseMaryHardForkEpoch o
          <*> parseAlonzoHardForkEpoch o
          <*> parseBabbageHardForkEpoch o
          <*> parseConwayHardForkEpoch o

      parseByronProtocolVersion :: Object -> Parser Byron.ProtocolVersion
      parseByronProtocolVersion o =
        Byron.ProtocolVersion
          <$> (o .: "LastKnownBlockVersion-Major")
          <*> (o .: "LastKnownBlockVersion-Minor")
          <*> (o .: "LastKnownBlockVersion-Alt")

      parseShelleyHardForkEpoch :: Object -> Parser Shelley.TriggerHardFork
      parseShelleyHardForkEpoch o =
        asum
          [ Shelley.TriggerHardForkAtEpoch <$> o .: "TestShelleyHardForkAtEpoch"
          , pure $ Shelley.TriggerHardForkAtVersion 2 -- Mainnet default
          ]

      parseAllegraHardForkEpoch :: Object -> Parser Shelley.TriggerHardFork
      parseAllegraHardForkEpoch o =
        asum
          [ Shelley.TriggerHardForkAtEpoch <$> o .: "TestAllegraHardForkAtEpoch"
          , pure $ Shelley.TriggerHardForkAtVersion 3 -- Mainnet default
          ]

      parseMaryHardForkEpoch :: Object -> Parser Shelley.TriggerHardFork
      parseMaryHardForkEpoch o =
        asum
          [ Shelley.TriggerHardForkAtEpoch <$> o .: "TestMaryHardForkAtEpoch"
          , pure $ Shelley.TriggerHardForkAtVersion 4 -- Mainnet default
          ]

      parseAlonzoHardForkEpoch :: Object -> Parser Shelley.TriggerHardFork
      parseAlonzoHardForkEpoch o =
        asum
          [ Shelley.TriggerHardForkAtEpoch <$> o .: "TestAlonzoHardForkAtEpoch"
          , pure $ Shelley.TriggerHardForkAtVersion 5 -- Mainnet default
          ]

      parseBabbageHardForkEpoch :: Object -> Parser Shelley.TriggerHardFork
      parseBabbageHardForkEpoch o =
        asum
          [ Shelley.TriggerHardForkAtEpoch <$> o .: "TestBabbageHardForkAtEpoch"
          , pure $ Shelley.TriggerHardForkAtVersion 7 -- Mainnet default
          ]

      parseConwayHardForkEpoch :: Object -> Parser Shelley.TriggerHardFork
      parseConwayHardForkEpoch o =
        asum
          [ Shelley.TriggerHardForkAtEpoch <$> o .: "TestConwayHardForkAtEpoch"
          , pure $ Shelley.TriggerHardForkAtVersion 9 -- Mainnet default
          ]
