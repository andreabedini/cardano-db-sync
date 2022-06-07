{-# LANGUAGE NoImplicitPrelude #-}

module Cardano.DbSync.Era.Shelley.Generic.Tx.Types
  ( Tx (..)
  , TxCertificate (..)
  , TxWithdrawal (..)
  , TxIn (..)
  , TxOut (..)
  , TxRedeemer (..)
  , TxScript (..)
  , PlutusData (..)
  , TxOutDatum (..)
  , whenInlineDatum
  , getTxOutDatumHash
  , getMaybeDatumHash
  , sumTxOutCoin
  ) where

import           Cardano.Prelude

import           Cardano.Slotting.Slot (SlotNo (..))

import qualified Cardano.Ledger.Address as Ledger
import           Cardano.Ledger.Alonzo.Scripts (Tag (..))
import           Cardano.Ledger.Coin (Coin (..))
import           Cardano.Ledger.Mary.Value (AssetName, PolicyID, Value)
import qualified Cardano.Ledger.Shelley.TxBody as Shelley

import           Ouroboros.Consensus.Cardano.Block (StandardCrypto)

import           Cardano.Api.Shelley (TxMetadataValue (..))

import           Cardano.Db (ScriptType (..))

import           Cardano.DbSync.Era.Shelley.Generic.ParamProposal


data Tx = Tx
  { txHash :: !ByteString
  , txBlockIndex :: !Word64
  , txSize :: !Word64
  , txValidContract :: !Bool
  , txInputs :: ![TxIn]
  , txCollateralInputs :: ![TxIn]
  , txReferenceInputs :: ![TxIn]
  , txOutputs :: ![TxOut]
  , txCollateralOutputs :: ![TxOut]
  , txFees :: !(Maybe Coin)
  , txOutSum :: !Coin
  , txInvalidBefore :: !(Maybe SlotNo)
  , txInvalidHereafter :: !(Maybe SlotNo)
  , txWithdrawalSum :: !Coin
  , txMetadata :: !(Maybe (Map Word64 TxMetadataValue))
  , txCertificates :: ![TxCertificate]
  , txWithdrawals :: ![TxWithdrawal]
  , txParamProposal :: ![ParamProposal]
  , txMint :: !(Value StandardCrypto)
  , txRedeemer :: [(Word64, TxRedeemer)]
  , txData :: [PlutusData]
  , txScriptSizes :: [Word64] -- this contains only the sizes of plutus scripts in witnesses
  , txScripts :: [TxScript]
  , txScriptsFee :: Coin -- fees for plutus scripts
  , txExtraKeyWitnesses :: ![ByteString]
  }

data TxCertificate = TxCertificate
  { txcRedeemerIndex :: !(Maybe Word64)
  , txcIndex :: !Word16
  , txcCert :: !(Shelley.DCert StandardCrypto)
  }

data TxWithdrawal = TxWithdrawal
  { txwRedeemerIndex :: !(Maybe Word64)
  , txwRewardAccount :: !(Shelley.RewardAcnt StandardCrypto)
  , txwAmount :: !Coin
  }

data TxIn = TxIn
  { txInHash :: !ByteString
  , txInIndex :: !Word16
  , txInRedeemerIndex :: !(Maybe Word64) -- This only has a meaning for Alonzo.
  } deriving Show

data TxOut = TxOut
  { txOutIndex :: !Word16
  , txOutAddress :: !(Ledger.Addr StandardCrypto)
  , txOutAddressRaw :: !ByteString
  , txOutAdaValue :: !Coin
  , txOutMaValue :: !(Map (PolicyID StandardCrypto) (Map AssetName Integer))
  , txOutScript :: Maybe TxScript
  , txOutDatum :: !TxOutDatum
  }

data TxRedeemer = TxRedeemer
  { txRedeemerMem :: !Word64
  , txRedeemerSteps :: !Word64
  , txRedeemerPurpose :: !Tag
  , txRedeemerFee :: !Coin
  , txRedeemerIndex :: !Word64
  , txRedeemerScriptHash :: Maybe (Either TxIn ByteString)
  , txRedeemerData :: PlutusData
  }

-- Fields are intentionally left lazy, to avoid transformation if the entry already
-- exists in db.
data TxScript = TxScript
  { txScriptHash :: !ByteString
  , txScriptType :: ScriptType
  , txScriptPlutusSize :: Maybe Word64
  , txScriptJson :: Maybe ByteString
  , txScriptCBOR :: Maybe ByteString
  }

-- Fields are intentionally left lazy, to avoid transformation if the entry already
-- exists in db.
data PlutusData = PlutusData
  { txDataHash :: !ByteString
  , txDataValue :: ByteString -- we turn this into json later.
  }

data TxOutDatum = InlineDatum PlutusData | DatumHash ByteString | NoDatum

whenInlineDatum :: Monad m => TxOutDatum -> (PlutusData -> m a) -> m (Maybe a)
whenInlineDatum (InlineDatum pd) f = Just <$> f pd
whenInlineDatum _ _ = pure Nothing

getTxOutDatumHash :: TxOutDatum -> Maybe ByteString
getTxOutDatumHash (InlineDatum txDatum) = Just $ txDataHash txDatum
getTxOutDatumHash (DatumHash hsh) = Just hsh
getTxOutDatumHash NoDatum = Nothing

getMaybeDatumHash :: Maybe ByteString -> TxOutDatum
getMaybeDatumHash Nothing = NoDatum
getMaybeDatumHash (Just hsh) = DatumHash hsh

sumTxOutCoin :: [TxOut] -> Coin
sumTxOutCoin = Coin . sum . map (unCoin . txOutAdaValue)