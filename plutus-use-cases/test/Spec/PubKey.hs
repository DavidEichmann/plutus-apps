{-# LANGUAGE TypeApplications #-}
module Spec.PubKey(tests, pubKeyTrace) where

import Control.Monad (void)
import Data.Map qualified as Map

import Ledger.Ada qualified as Ada
import Ledger.Constraints (ScriptLookups (..))
import Ledger.Constraints qualified as Constraints
import Ledger.Scripts (unitRedeemer)
import Ledger.Typed.Scripts as Scripts
import Plutus.Contract
import Plutus.Contract.Test
import Plutus.Trace.Emulator qualified as Trace

import Plutus.Contracts.PubKey (PubKeyError, pubKeyContract)

import Test.Tasty

theContract :: Contract () EmptySchema PubKeyError ()
theContract = do
  (txOutRef, ciTxOut, pkInst) <- pubKeyContract (walletPubKeyHash w1) (Ada.lovelaceValueOf 10)
  let lookups = ScriptLookups
                  { slMPS = Map.empty
                  , slTxOutputs = maybe mempty (Map.singleton txOutRef) ciTxOut
                  , slOtherScripts = Map.singleton (Scripts.validatorHash pkInst) (Scripts.validatorScript pkInst)
                  , slOtherData = Map.empty
                  , slPubKeyHashes = Map.empty
                  , slTypedValidator = Nothing
                  , slOwnPubkeyHash = Nothing
                  }
  void $ submitTxConstraintsWith @Scripts.Any lookups (Constraints.mustSpendScriptOutput txOutRef unitRedeemer)

tests :: TestTree
tests = testGroup "pubkey"
  [ checkPredicate "works like a public key output"
      (walletFundsChange w1 mempty .&&. assertDone theContract (Trace.walletInstanceTag w1) (const True) "pubkey contract not done")
      pubKeyTrace
  ]

-- | Use 'pubKeyContract' to create a script output that works like a
--   public key output, requiring only the right signature on the spending
--   transaction. Then spend the script output.
pubKeyTrace :: Trace.EmulatorTrace ()
pubKeyTrace = do
    _ <- Trace.activateContractWallet w1 theContract
    void $ Trace.waitNSlots 2
