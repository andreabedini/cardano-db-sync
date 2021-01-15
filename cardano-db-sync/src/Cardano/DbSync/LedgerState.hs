{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Cardano.DbSync.LedgerState
  ( CardanoLedgerState (..)
  , LedgerStateSnapshot (..)
  , LedgerStateVar (..)
  , LedgerStateFile (..)
  , applyBlock
  , initLedgerStateVar
  , ledgerStateTipSlot
  , loadLatestLedgerState
  , loadLedgerStateAtSlot
  , readLedgerState
  , saveLedgerState
  , listLedgerStateFilesOrdered
  , getLedgerFromFile
  ) where

import           Cardano.Binary (DecoderError)
import qualified Cardano.Binary as Serialize

import           Cardano.DbSync.Config
import           Cardano.DbSync.Config.Cardano
import qualified Cardano.DbSync.Era.Cardano.Util as Cardano
import qualified Cardano.DbSync.Era.Shelley.Generic.EpochUpdate as Generic
import qualified Cardano.DbSync.Era.Shelley.Generic.Rewards as Generic
import           Cardano.DbSync.Types hiding (CardanoBlock)
import           Cardano.DbSync.Util

import           Cardano.Prelude

import           Cardano.Slotting.EpochInfo (EpochInfo, epochInfoEpoch)
import           Cardano.Slotting.Slot (EpochNo (..), SlotNo (..), fromWithOrigin)

import           Control.Concurrent.STM.TVar (TVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import qualified Control.Exception as Exception
import           Control.Monad.Extra (firstJustM)

import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.ByteString.Short as BSS
import qualified Data.List as List

import           Ouroboros.Consensus.Block (CodecConfig, WithOrigin (..), blockHash, blockPrevHash,
                   withOrigin)
import           Ouroboros.Consensus.Cardano.Block (CardanoBlock, HardForkState (..),
                   LedgerState (..), StandardCrypto)
import           Ouroboros.Consensus.Cardano.CanHardFork ()
import           Ouroboros.Consensus.Config (TopLevelConfig (..), configCodec, configLedger)
import qualified Ouroboros.Consensus.HardFork.Combinator as Consensus
import           Ouroboros.Consensus.HardFork.Combinator.Basics (LedgerState (..))
import           Ouroboros.Consensus.HardFork.Combinator.State (epochInfoLedger)
import qualified Ouroboros.Consensus.HeaderValidation as Consensus
import           Ouroboros.Consensus.Ledger.Abstract (ledgerTipHash, ledgerTipSlot, tickThenReapply)
import           Ouroboros.Consensus.Ledger.Extended (ExtLedgerCfg (..), ExtLedgerState (..))
import qualified Ouroboros.Consensus.Ledger.Extended as Consensus
import qualified Ouroboros.Consensus.Node.ProtocolInfo as Consensus
import qualified Ouroboros.Consensus.Shelley.Protocol as Consensus
import           Ouroboros.Consensus.Storage.Serialisation (DecodeDisk (..), EncodeDisk (..))

import           Ouroboros.Network.Block (BlockNo (..))

import qualified Shelley.Spec.Ledger.API.Protocol as Shelley
import qualified Shelley.Spec.Ledger.BaseTypes as Shelley
import qualified Shelley.Spec.Ledger.STS.Tickn as Shelley

import           System.Directory (listDirectory, removeFile)
import           System.FilePath (dropExtension, takeExtension, (</>))


-- Note: The decision on whether a ledger-state is written to disk is based on the block number
-- rather than the slot number because while the block number is fully populated (for every block
-- other then genesis with number N there exists a block with number N - 1) whereas in the Shelley
-- era, only about 1/20 slots are occupied with blocks.
-- However, rollbacks are specified using a Point (basically a tuple of SlotNo and hash) and
-- therefore ledger states are stored in files with the SlotNo and hash in the file name.

{- HLINT ignore "Reduce duplication" -}

data CardanoLedgerState = CardanoLedgerState
  { clsState :: !(ExtLedgerState (CardanoBlock StandardCrypto))
  , clsConfig :: !(TopLevelConfig (CardanoBlock StandardCrypto))
  }

newtype LedgerStateVar = LedgerStateVar
  { unLedgerStateVar :: TVar CardanoLedgerState
  }

data LedgerStateFile = LedgerStateFile -- Internal use only.
  { lsfSlotNo :: !SlotNo
  , lsfFilePath :: !FilePath
  } deriving Show

data LedgerStateSnapshot = LedgerStateSnapshot
  { lssState :: !CardanoLedgerState
  , lssEpochUpdate :: !(Maybe Generic.EpochUpdate) -- Only Just for a single block at the epoch boundary
  }


initLedgerStateVar :: GenesisConfig -> IO LedgerStateVar
initLedgerStateVar genesisConfig =
  fmap LedgerStateVar . newTVarIO $ initCardanoLedgerState genesisConfig

initCardanoLedgerState :: GenesisConfig -> CardanoLedgerState
initCardanoLedgerState genesisConfig = CardanoLedgerState
      { clsState = Consensus.pInfoInitLedger protocolInfo
      , clsConfig = Consensus.pInfoConfig protocolInfo
      }
  where
    protocolInfo = mkProtocolInfoCardano genesisConfig

-- The function 'tickThenReapply' does zero validation, so add minimal validation ('blockPrevHash'
-- matches the tip hash of the 'LedgerState'). This was originally for debugging but the check is
-- cheap enough to keep.
applyBlock :: DbSyncEnv -> LedgerStateVar -> CardanoBlock StandardCrypto -> IO LedgerStateSnapshot
applyBlock env (LedgerStateVar stateVar) blk =
    -- 'LedgerStateVar' is just being used as a mutable variable. There should not ever
    -- be any contention on this variable, so putting everything inside 'atomically'
    -- is fine.
    atomically $ do
      oldState <- readTVar stateVar
      let !newState = oldState { clsState = applyBlk (ExtLedgerCfg (clsConfig oldState)) blk (clsState oldState) }
      writeTVar stateVar newState
      pure $ LedgerStateSnapshot
                { lssState = newState
                , lssEpochUpdate =
                    if ledgerEpochNo newState == ledgerEpochNo oldState + 1
                      then ledgerEpochUpdate env (clsState newState)
                             (ledgerRewardUpdate env (ledgerState $ clsState oldState))
                      else Nothing
                }
  where
    applyBlk
        :: ExtLedgerCfg (CardanoBlock StandardCrypto) -> CardanoBlock StandardCrypto
        -> ExtLedgerState (CardanoBlock StandardCrypto)
        -> ExtLedgerState (CardanoBlock StandardCrypto)
    applyBlk cfg block lsb =
      case tickThenReapplyCheckHash cfg block lsb of
        Left err -> panic err
        Right result -> result

ledgerStateTipSlot :: LedgerStateVar -> IO SlotNo
ledgerStateTipSlot (LedgerStateVar stateVar) = do
  lstate <- readTVarIO stateVar
  pure $ fromWithOrigin (SlotNo 0) . ledgerTipSlot $ ledgerState (clsState lstate)

saveLedgerState :: LedgerStateDir -> LedgerStateVar -> LedgerStateSnapshot -> SyncState -> IO ()
saveLedgerState lsd@(LedgerStateDir stateDir) (LedgerStateVar stateVar) snapshot synced = do
  atomically $ writeTVar stateVar ledger
  case synced of
    SyncFollowing -> saveState                          -- If following, save every state.
    SyncLagging
      | unSlotNo slot == 0 -> pure ()                   -- Genesis and the first EBB are weird so do not store them.
      | block `mod` 2000 == 0 -> saveState              -- Only save state ocassionally.
      | isJust (lssEpochUpdate snapshot) -> saveState   -- Epoch boundaries cost a lot, so we better save them
      | otherwise -> pure ()
  where
    ledger :: CardanoLedgerState
    ledger = lssState snapshot

    filename :: FilePath
    filename = stateDir </> show (unSlotNo slot) ++ ".lstate"

    slot :: SlotNo
    slot = fromWithOrigin (SlotNo 0) (ledgerTipSlot . ledgerState $ clsState ledger)

    block :: Word64
    block = withOrigin 0 unBlockNo $ ledgerTipBlockNo (clsState ledger)

    saveState :: IO ()
    saveState = do
      -- Encode and write lazily.
      LBS.writeFile filename $
        Serialize.serializeEncoding $
          Consensus.encodeExtLedgerState
             (encodeDisk codecConfig)
             (encodeDisk codecConfig)
             (encodeDisk codecConfig)
             (clsState ledger)
      cleanupLedgerStateFiles lsd slot

    codecConfig :: CodecConfig (CardanoBlock StandardCrypto)
    codecConfig = configCodec (clsConfig ledger)

loadLatestLedgerState :: LedgerStateDir -> LedgerStateVar -> IO ()
loadLatestLedgerState stateDir ledgerVar = do
  files <- listLedgerStateFilesOrdered stateDir
  ledger <- readLedgerState ledgerVar
  mcs <- firstJustM (loadFile ledger) files
  case mcs of
    Just cs -> atomically $ writeTVar (unLedgerStateVar ledgerVar) cs
    Nothing -> pure ()

loadLedgerStateAtSlot :: LedgerStateDir -> LedgerStateVar -> SlotNo -> IO ()
loadLedgerStateAtSlot stateDir (LedgerStateVar stateVar) slotNo = do
  -- Read current state to get the LedgerConfig and CodecConfig.
  lstate <- readLedgerState (LedgerStateVar stateVar)
  -- Load the state
  mState <- loadState stateDir lstate slotNo
  case mState of
    Nothing -> pure ()
    Just st -> atomically $ writeTVar stateVar st

-- | This should be exposed by 'consensus'.
ledgerTipBlockNo :: ExtLedgerState blk -> WithOrigin BlockNo
ledgerTipBlockNo = fmap Consensus.annTipBlockNo . Consensus.headerStateTip . Consensus.headerState

-- -------------------------------------------------------------------------------------------------

-- Find the ledger state files and keep the 4 most recent.
cleanupLedgerStateFiles :: LedgerStateDir -> SlotNo -> IO ()
cleanupLedgerStateFiles stateDir slotNo = do
    files <- listLedgerStateFilesOrdered stateDir
    let (invalid, valid) = partitionEithers $ map keepFile files
    -- Remove invalid (ie SlotNo >= current) ledger state files (occurs on rollback).
    mapM_ safeRemoveFile invalid
    -- Remove all but 8 most recent state files.
    mapM_ (safeRemoveFile . lsfFilePath) (List.drop 8 valid)
  where
    -- Left files are deleted, Right files are kept.
    keepFile :: LedgerStateFile ->  Either FilePath LedgerStateFile
    keepFile lsf@(LedgerStateFile w fp) =
      if w <= slotNo
        then Right lsf
        else Left fp

extractEpochNonce :: ExtLedgerState (CardanoBlock era) -> Maybe Shelley.Nonce
extractEpochNonce extLedgerState =
    case Consensus.headerStateChainDep (headerState extLedgerState) of
      ChainDepStateByron _ -> Nothing
      ChainDepStateShelley st -> Just $ extractNonce st
      ChainDepStateAllegra st -> Just $ extractNonce st
      ChainDepStateMary st -> Just $ extractNonce st
  where
    extractNonce :: Consensus.TPraosState crypto -> Shelley.Nonce
    extractNonce =
      Shelley.ticknStateEpochNonce . Shelley.csTickn . Consensus.tpraosStateChainDepState

getLedgerFromFile :: GenesisConfig -> LedgerStateFile -> IO (Maybe CardanoLedgerState)
getLedgerFromFile conf file = do
  loadFile (initCardanoLedgerState conf) file

loadState :: LedgerStateDir -> CardanoLedgerState -> SlotNo -> IO (Maybe CardanoLedgerState)
loadState stateDir ledger slotNo = do
    files <- listLedgerStateFilesOrdered stateDir
    let (invalid, valid) = partitionEithers $ map keepFile files
    -- Remove invalid (ie SlotNo >= current) ledger state files (occurs on rollback).
    mapM_ safeRemoveFile invalid
    -- Want the highest numbered snapshot.
    firstJustM (loadFile ledger) valid
  where
    -- Left files are deleted, Right files are kept.
    keepFile :: LedgerStateFile ->  Either FilePath LedgerStateFile
    keepFile lsf@(LedgerStateFile w fp) =
      if w <= slotNo
        then Right lsf
        else Left fp

loadFile :: CardanoLedgerState -> LedgerStateFile -> IO (Maybe CardanoLedgerState)
loadFile ledger lsf = do
    mst <- safeReadFile (lsfFilePath lsf)
    case mst of
      Nothing -> pure Nothing
      Just st -> pure . Just $ ledger { clsState = st }
  where
    safeReadFile :: FilePath -> IO (Maybe (ExtLedgerState (CardanoBlock StandardCrypto)))
    safeReadFile fp = do
      mbs <- Exception.try $ BS.readFile fp
      case mbs of
        Left (_ :: IOException) -> pure Nothing
        Right bs ->
          case decode bs of
            Left _err -> do
              safeRemoveFile fp
              pure Nothing
            Right ls -> pure $ Just ls


    codecConfig :: CodecConfig (CardanoBlock StandardCrypto)
    codecConfig = configCodec (clsConfig ledger)

    decode :: ByteString -> Either DecoderError (ExtLedgerState (CardanoBlock StandardCrypto))
    decode =
      Serialize.decodeFullDecoder
          "Ledger state file"
          (Consensus.decodeExtLedgerState
            (decodeDisk codecConfig)
            (decodeDisk codecConfig)
            (decodeDisk codecConfig))
        . LBS.fromStrict

-- Get a list of the ledger state files order most recent
listLedgerStateFilesOrdered :: LedgerStateDir -> IO [LedgerStateFile]
listLedgerStateFilesOrdered (LedgerStateDir stateDir) = do
    files <- filter isLedgerStateFile <$> listDirectory stateDir
    pure . List.sortBy revSlotNoOrder $ mapMaybe extractIndex files
  where
    isLedgerStateFile :: FilePath -> Bool
    isLedgerStateFile fp = takeExtension fp == ".lstate"

    extractIndex :: FilePath -> Maybe LedgerStateFile
    extractIndex fp =
      case readMaybe (dropExtension fp) of
        Nothing -> Nothing
        Just w -> Just $ LedgerStateFile (SlotNo w) (stateDir </> fp)

    revSlotNoOrder :: LedgerStateFile -> LedgerStateFile -> Ordering
    revSlotNoOrder a b = compare (lsfSlotNo b) (lsfSlotNo a)

readLedgerState :: LedgerStateVar -> IO CardanoLedgerState
readLedgerState (LedgerStateVar stateVar) = readTVarIO stateVar

-- | Remove given file path and ignore any IOEXceptions.
safeRemoveFile :: FilePath -> IO ()
safeRemoveFile fp = handle (\(_ :: IOException) -> pure ()) $ removeFile fp

ledgerEpochNo :: CardanoLedgerState -> EpochNo
ledgerEpochNo cls =
    case ledgerTipSlot (ledgerState (clsState cls)) of
      Origin -> 0 -- An empty chain is in epoch 0
      NotOrigin slot -> runIdentity $ epochInfoEpoch epochInfo slot
  where
    epochInfo :: EpochInfo Identity
    epochInfo = epochInfoLedger (configLedger $ clsConfig cls) (hardForkLedgerStatePerEra . ledgerState $ clsState cls)

-- Create an EpochUpdate from the current epoch state and the rewards from the last epoch.
ledgerEpochUpdate :: DbSyncEnv -> ExtLedgerState (CardanoBlock StandardCrypto) -> Maybe Generic.Rewards -> Maybe Generic.EpochUpdate
ledgerEpochUpdate env els mRewards =
  case ledgerState els of
    LedgerStateByron _ -> Nothing
    LedgerStateShelley sls -> Just $ Generic.shelleyEpochUpdate env sls mRewards mNonce
    LedgerStateAllegra als -> Just $ Generic.allegraEpochUpdate env als mRewards mNonce
    LedgerStateMary mls -> Just $ Generic.maryEpochUpdate env mls mRewards mNonce
  where
    mNonce :: Maybe Shelley.Nonce
    mNonce = extractEpochNonce els

-- This will return a 'Just' from the time the rewards are updated until the end of the
-- epoch. It is 'Nothing' for the first block of a new epoch (which is slightly inconvenient).
ledgerRewardUpdate :: DbSyncEnv -> LedgerState (CardanoBlock StandardCrypto) -> Maybe Generic.Rewards
ledgerRewardUpdate env lsc =
    case lsc of
      LedgerStateByron _ -> Nothing -- This actually happens during the Byron era.
      LedgerStateShelley sls -> Generic.shelleyRewards env sls
      LedgerStateAllegra als -> Generic.allegraRewards env als
      LedgerStateMary mls -> Generic.maryRewards env mls

-- Like 'Consensus.tickThenReapply' but also checks that the previous hash from the block matches
-- the head hash of the ledger state.
tickThenReapplyCheckHash
    :: ExtLedgerCfg (CardanoBlock StandardCrypto) -> CardanoBlock StandardCrypto
    -> ExtLedgerState (CardanoBlock StandardCrypto)
    -> Either Text (ExtLedgerState (CardanoBlock StandardCrypto))
tickThenReapplyCheckHash cfg block lsb =
  if blockPrevHash block == ledgerTipHash (ledgerState lsb)
    then Right $ tickThenReapply cfg block lsb
    else Left $ mconcat
                  [ "Ledger state hash mismatch. Ledger head is slot "
                  , textShow (unSlotNo $ fromWithOrigin (SlotNo 0) (ledgerTipSlot $ ledgerState lsb))
                  , " hash ", renderByteArray (Cardano.unChainHash (ledgerTipHash $ ledgerState lsb))
                  , " but block previous hash is "
                  , renderByteArray (Cardano.unChainHash $ blockPrevHash block)
                  , " and block current hash is "
                  , renderByteArray (BSS.fromShort . Consensus.getOneEraHash $ blockHash block), "."
                  ]
