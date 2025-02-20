{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
module Spec.Contract(tests, loopCheckpointContract, initial, upd) where

import Control.Lens hiding ((.>))
import Control.Monad (forever, void)
import Control.Monad.Error.Lens
import Control.Monad.Except (catchError)
import Control.Monad.Freer.Extras.Log (LogLevel (..))
import Control.Monad.Freer.Extras.Log qualified as Log
import Data.Functor.Apply ((.>))
import Data.Map qualified as Map
import Data.Void
import Test.Tasty

import Ledger (Address, PubKeyHash)
import Ledger qualified
import Ledger.Ada qualified as Ada
import Ledger.Constraints qualified as Constraints
import Ledger.Tx (getCardanoTxId)
import Plutus.Contract as Con
import Plutus.Contract.State qualified as State
import Plutus.Contract.Test
import Plutus.Contract.Types (ResumableResult (..), responses)
import Plutus.Contract.Util (loopM)
import Plutus.Trace qualified as Trace
import Plutus.Trace.Emulator (ContractInstanceTag, EmulatorTrace, activateContract, activeEndpoints, callEndpoint)
import Plutus.Trace.Emulator.Types (ContractInstanceLog (..), ContractInstanceMsg (..), ContractInstanceState (..),
                                    UserThreadMsg (..))
import PlutusTx qualified
import Prelude hiding (not)
import Wallet.Emulator qualified as EM
import Wallet.Emulator.Wallet (walletAddress)

import Plutus.ChainIndex.Types
import Plutus.Contract.Effects (ActiveEndpoint (..))

tests :: TestTree
tests =
    let run :: String -> TracePredicate -> EmulatorTrace () -> _
        run = checkPredicateOptions (defaultCheckOptions & minLogLevel .~ Debug)

        check :: String -> Contract () Schema ContractError () -> _ -> _
        check nm contract pred = run nm (pred contract) (void $ activateContract w1 contract tag)

        tag :: ContractInstanceTag
        tag = "instance 1"

    in
    testGroup "contracts"
        [ check "awaitSlot" (void $ awaitSlot 10) $ \con ->
            waitingForSlot con tag 10

        , check "selectEither" (void $ awaitPromise $ selectEither (isSlot 10) (isSlot 5)) $ \con ->
            waitingForSlot con tag 5

        , check "both" (void $ awaitPromise $ Con.both (isSlot 10) (isSlot 20)) $ \con ->
            waitingForSlot con tag 10

        , check "both (2)" (void $ awaitPromise $ Con.both (isSlot 10) (isSlot 20)) $ \con ->
            waitingForSlot con tag 20

        , check "watchAddressUntilSlot" (void $ watchAddressUntilSlot someAddress 5) $ \con ->
            waitingForSlot con tag 5

        , check "endpoint" (void $ awaitPromise $ endpoint @"ep" pure) $ \con ->
            endpointAvailable @"ep" con tag

        , check "forever" (forever $ awaitPromise $ endpoint @"ep" pure) $ \con ->
            endpointAvailable @"ep" con tag

        , let
            oneTwo :: Promise () Schema ContractError Int = endpoint @"1" pure .> endpoint @"2" pure .> endpoint @"4" pure
            oneThree :: Promise () Schema ContractError Int = endpoint @"1" pure .> endpoint @"3" pure .> endpoint @"4" pure
            con = selectList [void oneTwo, void oneThree]
          in
            run "alternative"
                (endpointAvailable @"2" con tag
                    .&&. not (endpointAvailable @"3" con tag))
                $ do
                    hdl <- activateContract w1 con tag
                    callEndpoint @"1" hdl 1

        , let theContract :: Contract () Schema ContractError () = void $ awaitPromise $ endpoint @"1" @Int pure .> endpoint @"2" @Int pure
          in run "call endpoint (1)"
                (endpointAvailable @"1" theContract tag)
                (void $ activateContract w1 theContract tag)

        , let theContract :: Contract () Schema ContractError () = void $ awaitPromise $ endpoint @"1" @Int pure .> endpoint @"2" @Int pure
          in run "call endpoint (2)"
                (endpointAvailable @"2" theContract tag
                    .&&. not (endpointAvailable @"1" theContract tag))
                (activateContract w1 theContract tag >>= \hdl -> callEndpoint @"1" hdl 1)

        , let theContract :: Contract () Schema ContractError () = void $ awaitPromise $ endpoint @"1" @Int pure .> endpoint @"2" @Int pure
          in run "call endpoint (3)"
                (not (endpointAvailable @"2" theContract tag)
                    .&&. not (endpointAvailable @"1" theContract tag))
                (activateContract w1 theContract tag >>= \hdl -> callEndpoint @"1" hdl 1 >> callEndpoint @"2" hdl 2)

        , let theContract :: Contract () Schema ContractError [ActiveEndpoint] = awaitPromise $ endpoint @"5" @[ActiveEndpoint] pure
              expected = ActiveEndpoint{ aeDescription = EndpointDescription "5", aeMetadata = Nothing}
          in run "active endpoints"
                (assertDone theContract tag ((==) [expected]) "should be done")
                $ do
                    hdl <- activateContract w1 theContract tag
                    _ <- Trace.waitNSlots 1
                    eps <- activeEndpoints hdl
                    void $ callEndpoint @"5" hdl eps

        , let theContract :: Contract () Schema ContractError () = void $ submitTx mempty >> watchAddressUntilSlot someAddress 20
          in run "submit tx"
                (waitingForSlot theContract tag 20)
                (void $ activateContract w1 theContract tag)

        , let smallTx = Constraints.mustPayToPubKey (walletPubKeyHash w2) (Ada.lovelaceValueOf 10)
              theContract :: Contract () Schema ContractError () = submitTx smallTx >>= awaitTxConfirmed . getCardanoTxId >> submitTx smallTx >>= awaitTxConfirmed . getCardanoTxId
          in run "handle several blockchain events"
                (walletFundsChange w1 (Ada.lovelaceValueOf (-20))
                    .&&. assertNoFailedTransactions
                    .&&. assertDone theContract tag (const True) "all blockchain events should be processed")
                (void $ activateContract w1 theContract tag >> Trace.waitUntilSlot 3)

        , let l = endpoint @"1" pure .> endpoint @"2" pure
              r = endpoint @"3" pure .> endpoint @"4" pure
              theContract :: Contract () Schema ContractError () = void . awaitPromise $ selectEither l r
          in run "select either"
                (assertDone theContract tag (const True) "left branch should finish")
                (activateContract w1 theContract tag >>= (\hdl -> callEndpoint @"1" hdl 1 >> callEndpoint @"2" hdl 2))

        , let theContract :: Contract () Schema ContractError () = void $ loopM (\_ -> fmap Left . awaitPromise $ endpoint @"1" @Int pure) 0
          in run "loopM"
                (endpointAvailable @"1" theContract tag)
                (void $ activateContract w1 theContract tag >>= \hdl -> callEndpoint @"1" hdl 1)

        , let theContract :: Contract () Schema ContractError () = void $ throwing Con._ContractError $ OtherError "error"
          in run "throw an error"
                (assertContractError theContract tag (\case { OtherError "error" -> True; _ -> False}) "failed to throw error")
                (void $ activateContract w1 theContract tag)

        , run "pay to wallet"
            (walletFundsChange w1 (Ada.lovelaceValueOf (-200))
                .&&. walletFundsChange w2 (Ada.lovelaceValueOf 200)
                .&&. assertNoFailedTransactions)
            (void $ Trace.payToWallet w1 w2 (Ada.lovelaceValueOf 200))

        , let theContract :: Contract () Schema ContractError () = void $ awaitUtxoProduced (walletAddress w2)
          in run "await utxo produced"
            (assertDone theContract tag (const True) "should receive a notification")
            (void $ do
                activateContract w1 theContract tag
                Trace.payToWallet w1 w2 (Ada.lovelaceValueOf 200)
                Trace.waitNSlots 1
            )

        , let theContract :: Contract () Schema ContractError () = void (utxosAt (walletAddress w1) >>= awaitUtxoSpent . fst . head . Map.toList)
          in run "await txout spent"
            (assertDone theContract tag (const True) "should receive a notification")
            (void $ do
                activateContract w1 theContract tag
                Trace.payToWallet w1 w2 (Ada.lovelaceValueOf 200)
                Trace.waitNSlots 1
            )

        , let theContract :: Contract () Schema ContractError PubKeyHash = ownPubKeyHash
          in run "own public key"
                (assertDone theContract tag (== walletPubKeyHash w2) "should return the wallet's public key")
                (void $ activateContract w2 (void theContract) tag)

        , let payment = Constraints.mustPayToPubKey (walletPubKeyHash w2) (Ada.lovelaceValueOf 10)
              theContract :: Contract () Schema ContractError () = submitTx payment >>= awaitTxConfirmed . Ledger.getCardanoTxId
          in run "await tx confirmed"
            (assertDone theContract tag (const True) "should be done")
            (activateContract w1 theContract tag >> void (Trace.waitNSlots 1))

        , let payment = Constraints.mustPayToPubKey (walletPubKeyHash w2) (Ada.lovelaceValueOf 10)
              theContract :: Contract () Schema ContractError TxStatus =
                submitTx payment >>= awaitTxStatusChange . Ledger.getCardanoTxId
          in run "await change in tx status"
            (assertDone theContract tag ((==) (Committed TxValid ())) "should be done")
            (activateContract w1 theContract tag >> void (Trace.waitNSlots 1))

        , let c :: Contract [TxOutStatus] Schema ContractError () = do
                -- Submit a payment tx of 10 lovelace to W2.
                let w2PubKeyHash = walletPubKeyHash w2
                let payment = Constraints.mustPayToPubKey w2PubKeyHash
                                                          (Ada.lovelaceValueOf 10)
                tx <- submitTx payment
                -- There should be 2 utxos. We suppose the first belongs to the
                -- wallet calling the contract and the second one to W2.
                let utxo = head $ fmap snd $ Ledger.getCardanoTxOutRefs tx
                -- We wait for W1's utxo to change status. It should be of
                -- status confirmed unspent.
                s <- awaitTxOutStatusChange utxo
                tell [s]

                -- We submit another tx which spends the utxo belonging to the
                -- contract's caller. It's status should be changed eventually
                -- to confirmed spent.
                pubKeyHash <- ownPubKeyHash
                ciTxOutM <- txOutFromRef utxo
                let lookups = Constraints.unspentOutputs (maybe mempty (Map.singleton utxo) ciTxOutM)
                submitTxConstraintsWith @Void lookups $ Constraints.mustSpendPubKeyOutput utxo
                                                     <> Constraints.mustBeSignedBy pubKeyHash
                s <- awaitTxOutStatusChange utxo
                tell [s]

              expectedAccumState =
                [ Committed TxValid Unspent
                , Committed TxValid (Spent "2e02b91e17093a89ffbaa2b8b769e28cae83d567f4c183462bec16ea0fc7f8cd")
                ]
          in run "await change in tx out status"
            ( assertAccumState c tag ((==) expectedAccumState) "should be done"
            ) $ do
              _ <- activateContract w1 c tag
              void (Trace.waitNSlots 2)

        , run "checkpoints"
            (not (endpointAvailable @"2" checkpointContract tag) .&&. endpointAvailable @"1" checkpointContract tag)
            (void $ activateContract w1 checkpointContract tag >>= \hdl -> callEndpoint @"1" hdl 1 >> callEndpoint @"2" hdl 1)

        , run "error handling & checkpoints"
            (assertDone errorContract tag (\i -> i == 11) "should finish")
            (void $ activateContract w1 (void errorContract) tag >>= \hdl -> callEndpoint @"1" hdl 1 >> callEndpoint @"2" hdl 10 >> callEndpoint @"3" hdl 11)

        , run "loop checkpoint"
            (assertDone loopCheckpointContract tag (\i -> i == 4) "should finish"
            .&&. assertResumableResult loopCheckpointContract tag DoShrink (null . view responses) "should collect garbage"
            .&&. assertResumableResult loopCheckpointContract tag DontShrink ((==) 4 . length . view responses) "should keep everything"
            )
            $ do
                hdl <- activateContract w1 loopCheckpointContract tag
                sequence_ . replicate 4 $ callEndpoint @"1" hdl 1

        , let theContract :: Contract () Schema ContractError () = logInfo @String "waiting for endpoint 1" >> awaitPromise (endpoint @"1" (logInfo . (<>) "Received value: " . show))
              matchLogs :: [EM.EmulatorTimeEvent ContractInstanceLog] -> Bool
              matchLogs lgs =
                  case _cilMessage . EM._eteEvent <$> lgs of
                            [ Started, ContractLog "waiting for endpoint 1", CurrentRequests [_], ReceiveEndpointCall{}, ContractLog "Received value: 27", HandledRequest _, CurrentRequests [], StoppedNoError ] -> True
                            _ -> False
          in run "contract logs"
                (assertInstanceLog tag matchLogs)
                (void $ activateContract w1 theContract tag >>= \hdl -> callEndpoint @"1" hdl 27)

        , let theContract :: Contract () Schema ContractError () = logInfo @String "waiting for endpoint 1" >> awaitPromise (endpoint @"1" (logInfo . (<>) "Received value: " . show))
              matchLogs :: [EM.EmulatorTimeEvent UserThreadMsg] -> Bool
              matchLogs lgs =
                  case EM._eteEvent <$> lgs of
                            [ UserLog "Received contract state", UserLog "Final state: Right Nothing"] -> True
                            _                                                                          -> False
          in run "contract state"
                (assertUserLog matchLogs)
                $ do
                    hdl <- Trace.activateContractWallet w1 theContract
                    Trace.waitNSlots 1
                    ContractInstanceState{instContractState=ResumableResult{_finalState}} <- Trace.getContractState hdl
                    Log.logInfo @String "Received contract state"
                    Log.logInfo @String $ "Final state: " <> show _finalState

        , let theContract :: Contract () Schema ContractError () = void $ awaitSlot 10
              emTrace = do
                void $ Trace.assert "Always succeeds" $ const True
                void $ Trace.waitNSlots 10
          in run "assert succeeds" (waitingForSlot theContract tag 10) emTrace

        , let theContract :: Contract () Schema ContractError () = void $ awaitSlot 10
              emTrace = do
                void $ Trace.assert "Always fails" $ const False
                void $ Trace.waitNSlots 10
          in checkEmulatorFails "assert throws error" (defaultCheckOptions & minLogLevel .~ Debug) (waitingForSlot theContract tag 10) emTrace
        ]

checkpointContract :: Contract () Schema ContractError ()
checkpointContract = void $ do
    checkpoint $ awaitPromise $ endpoint @"1" @Int pure .> endpoint @"2" @Int pure
    checkpoint $ awaitPromise $ endpoint @"1" @Int pure .> endpoint @"3" @Int pure

loopCheckpointContract :: Contract () Schema ContractError Int
loopCheckpointContract = do
    -- repeatedly expose the "1" endpoint until we get a total
    -- value greater than 3.
    -- We can call "1" with different values to control whether
    -- the left or right branch is chosen.
    flip checkpointLoop (0 :: Int) $ \counter -> awaitPromise $ endpoint @"1" @Int $ \vl -> do
        let newVal = counter + vl
        if newVal > 3
            then pure (Left newVal)
            else pure (Right newVal)

errorContract :: Contract () Schema ContractError Int
errorContract = do
    catchError
        (awaitPromise $ endpoint @"1" @Int $ \_ -> throwError (OtherError "something went wrong"))
        (\_ -> checkpoint $ awaitPromise $ endpoint @"2" @Int pure .> endpoint @"3" @Int pure)

someAddress :: Address
someAddress = Ledger.scriptAddress $
    Ledger.mkValidatorScript $$(PlutusTx.compile [|| \(_ :: PlutusTx.BuiltinData) (_ :: PlutusTx.BuiltinData) (_ :: PlutusTx.BuiltinData) -> () ||])

type Schema =
    Endpoint "1" Int
        .\/ Endpoint "2" Int
        .\/ Endpoint "3" Int
        .\/ Endpoint "4" Int
        .\/ Endpoint "ep" ()
        .\/ Endpoint "5" [ActiveEndpoint]
        .\/ Endpoint "6" Ledger.Tx

initial :: _
initial = State.initialiseContract loopCheckpointContract

upd :: _
upd = State.insertAndUpdateContract loopCheckpointContract
