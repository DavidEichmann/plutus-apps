{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE ViewPatterns          #-}

{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}

module Plutus.PAB.App(
    App,
    runApp,
    AppEnv(..),
    StorageBackend(..),
    -- * App actions
    migrate,
    dbConnect,
    handleContractDefinition
    ) where

import Cardano.Api.NetworkId.Extra (NetworkIdWrapper (..))
import Cardano.Api.ProtocolParameters ()
import Cardano.Api.Shelley (ProtocolParameters)
import Cardano.BM.Trace (Trace, logDebug)
import Cardano.ChainIndex.Types qualified as ChainIndex
import Cardano.Node.Client (handleNodeClientClient)
import Cardano.Node.Client qualified as NodeClient
import Cardano.Node.Types (MockServerConfig (..), NodeMode (..))
import Cardano.Protocol.Socket.Mock.Client qualified as MockClient
import Cardano.Wallet.Client qualified as WalletClient
import Cardano.Wallet.Mock.Client qualified as WalletMockClient
import Cardano.Wallet.Mock.Types qualified as Wallet
import Control.Concurrent.STM qualified as STM
import Control.Monad.Freer
import Control.Monad.Freer.Error (Error, handleError, throwError)
import Control.Monad.Freer.Extras.Beam (handleBeam)
import Control.Monad.Freer.Extras.Log (LogMsg, mapLog)
import Control.Monad.Freer.Reader (Reader)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (FromJSON, ToJSON, eitherDecode)
import Data.ByteString.Lazy qualified as BSL
import Data.Coerce (coerce)
import Data.Default (def)
import Data.Text (Text, pack, unpack)
import Data.Typeable (Typeable)
import Database.Beam.Migrate.Simple
import Database.Beam.Sqlite qualified as Sqlite
import Database.Beam.Sqlite.Migrate qualified as Sqlite
import Database.SQLite.Simple (open)
import Database.SQLite.Simple qualified as Sqlite
import Network.HTTP.Client (managerModifyRequest, newManager, setRequestIgnoreStatus)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Plutus.ChainIndex.Client qualified as ChainIndex
import Plutus.PAB.Core (EffectHandlers (..), PABAction)
import Plutus.PAB.Core qualified as Core
import Plutus.PAB.Core.ContractInstance.BlockchainEnv qualified as BlockchainEnv
import Plutus.PAB.Core.ContractInstance.STM as Instances
import Plutus.PAB.Db.Beam.ContractStore qualified as BeamEff
import Plutus.PAB.Db.Memory.ContractStore (InMemInstances, initialInMemInstances)
import Plutus.PAB.Db.Memory.ContractStore qualified as InMem
import Plutus.PAB.Db.Schema (checkedSqliteDb)
import Plutus.PAB.Effects.Contract (ContractDefinition (..))
import Plutus.PAB.Effects.Contract.Builtin (Builtin, BuiltinHandler (..), HasDefinitions (..))
import Plutus.PAB.Monitoring.Monitoring (convertLog, handleLogMsgTrace)
import Plutus.PAB.Monitoring.PABLogMsg (PABLogMsg (..), PABMultiAgentMsg (BeamLogItem, UserLog, WalletClient),
                                        WalletClientMsg)
import Plutus.PAB.Timeout (Timeout (..))
import Plutus.PAB.Types (Config (Config), DbConfig (..), PABError (..), WebserverConfig (..), chainIndexConfig,
                         dbConfig, endpointTimeout, nodeServerConfig, pabWebserverConfig, walletServerConfig)
import Servant.Client (ClientEnv, ClientError, mkClientEnv)
import Wallet.Effects (WalletEffect (..))
import Wallet.Emulator.Error (WalletAPIError)
import Wallet.Emulator.Wallet (Wallet (..))

------------------------------------------------------------

-- | Application environment with a contract type `a`.
data AppEnv a =
    AppEnv
        { dbConnection          :: Sqlite.Connection
        , walletClientEnv       :: ClientEnv
        , nodeClientEnv         :: ClientEnv
        , chainIndexEnv         :: ClientEnv
        , txSendHandle          :: MockClient.TxSendHandle
        , chainSyncHandle       :: NodeClient.ChainSyncHandle
        , appConfig             :: Config
        , appTrace              :: Trace IO (PABLogMsg (Builtin a))
        , appInMemContractStore :: InMemInstances (Builtin a)
        , protocolParameters    :: ProtocolParameters
        }

appEffectHandlers
  :: forall a.
  ( FromJSON a
  , ToJSON a
  , HasDefinitions a
  , Typeable a
  )
  => StorageBackend
  -> Config
  -> Trace IO (PABLogMsg (Builtin a))
  -> BuiltinHandler a
  -> EffectHandlers (Builtin a) (AppEnv a)
appEffectHandlers storageBackend config trace BuiltinHandler{contractHandler} =
    EffectHandlers
        { initialiseEnvironment = do
            env <- liftIO $ mkEnv trace config
            let Config{nodeServerConfig=MockServerConfig{mscSocketPath, mscSlotConfig, mscNodeMode, mscNetworkId=NetworkIdWrapper networkId}} = config
            instancesState <- liftIO $ STM.atomically Instances.emptyInstancesState
            blockchainEnv <- liftIO $ BlockchainEnv.startNodeClient mscSocketPath mscNodeMode mscSlotConfig networkId instancesState
            pure (instancesState, blockchainEnv, env)

        , handleLogMessages =
            interpret (handleLogMsgTrace trace)
            . reinterpret (mapLog SMultiAgent)

        , handleContractEffect =
            interpret (handleLogMsgTrace trace)
            . reinterpret contractHandler

        , handleContractStoreEffect =
          case storageBackend of
            InMemoryBackend ->
              interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
              . interpret (Core.handleMappedReader @(AppEnv a) appInMemContractStore)
              . reinterpret2 InMem.handleContractStore

            BeamSqliteBackend ->
              interpret (handleLogMsgTrace trace)
              . reinterpret (mapLog @_ @(PABLogMsg (Builtin a)) SMultiAgent)
              . interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
              . interpret (Core.handleMappedReader @(AppEnv a) dbConnection)
              . flip handleError (throwError . BeamEffectError)
              . interpret (handleBeam (convertLog (SMultiAgent . BeamLogItem) trace))
              . reinterpretN @'[_, _, _, _, _] BeamEff.handleContractStore

        , handleContractDefinitionEffect =
            interpret (handleLogMsgTrace trace)
            . reinterpret (mapLog @_ @(PABLogMsg (Builtin a)) SMultiAgent)
            . interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
            . interpret (Core.handleMappedReader @(AppEnv a) dbConnection)
            . flip handleError (throwError . BeamEffectError)
            . interpret (handleBeam (convertLog (SMultiAgent . BeamLogItem) trace))
            . reinterpretN @'[_, _, _, _, _] handleContractDefinition

        , handleServicesEffects = \wallet ->
            -- handle 'NodeClientEffect'
            flip handleError (throwError . NodeClientError)
            . interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
            . reinterpret (Core.handleMappedReader @(AppEnv a) @NodeClient.ChainSyncHandle chainSyncHandle)
            . interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
            . reinterpret (Core.handleMappedReader @(AppEnv a) @MockClient.TxSendHandle txSendHandle)
            . interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
            . reinterpret (Core.handleMappedReader @(AppEnv a) @ClientEnv nodeClientEnv)
            . reinterpretN @'[_, _, _, _] (handleNodeClientClient @IO $ mscSlotConfig $ nodeServerConfig config)

            -- handle 'ChainIndexEffect'
            . flip handleError (throwError . ChainIndexError)
            . interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
            . reinterpret (Core.handleMappedReader @(AppEnv a) @ClientEnv chainIndexEnv)
            . reinterpret2 (ChainIndex.handleChainIndexClient @IO)

            -- handle 'WalletEffect'
            . flip handleError (throwError . WalletClientError)
            . flip handleError (throwError . WalletError)
            . interpret (mapLog @_ @(PABMultiAgentMsg (Builtin a)) WalletClient)
            . interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
            . reinterpret (Core.handleMappedReader @(AppEnv a) @ClientEnv walletClientEnv)
            . interpret (Core.handleUserEnvReader @(Builtin a) @(AppEnv a))
            . reinterpret (Core.handleMappedReader @(AppEnv a) @ProtocolParameters protocolParameters)
            . reinterpretN @'[_, _, _, _, _] (handleWalletEffect (nodeServerConfig config) wallet)

        , onStartup = pure ()

        , onShutdown = pure ()
        }

handleWalletEffect
  :: forall effs.
  ( LastMember IO effs
  , Member (Error ClientError) effs
  , Member (Error WalletAPIError) effs
  , Member (Reader ClientEnv) effs
  , Member (Reader ProtocolParameters) effs
  , Member (LogMsg WalletClientMsg) effs
  )
  => MockServerConfig
  -> Wallet
  -> WalletEffect
  ~> Eff effs
handleWalletEffect (mscNodeMode -> MockNode) = WalletMockClient.handleWalletClient @IO
handleWalletEffect config                    = WalletClient.handleWalletClient config

runApp ::
    forall a b.
    ( FromJSON a
    , ToJSON a
    , HasDefinitions a
    , Typeable a
    )
    => StorageBackend
    -> Trace IO (PABLogMsg (Builtin a)) -- ^ Top-level tracer
    -> BuiltinHandler a
    -> Config -- ^ Client configuration
    -> App a b -- ^ Action
    -> IO (Either PABError b)
runApp storageBackend trace contractHandler config@Config{pabWebserverConfig=WebserverConfig{endpointTimeout}} = Core.runPAB (Timeout endpointTimeout) (appEffectHandlers storageBackend config trace contractHandler)

type App a b = PABAction (Builtin a) (AppEnv a) b

data StorageBackend = BeamSqliteBackend | InMemoryBackend
  deriving (Eq, Ord, Show)

mkEnv :: Trace IO (PABLogMsg (Builtin a)) -> Config -> IO (AppEnv a)
mkEnv appTrace appConfig@Config { dbConfig
             , nodeServerConfig =  MockServerConfig{mscBaseUrl, mscSocketPath, mscSlotConfig, mscProtocolParametersJsonPath}
             , walletServerConfig
             , chainIndexConfig
             } = do
    walletClientEnv <- clientEnv (Wallet.baseUrl walletServerConfig)
    nodeClientEnv <- clientEnv mscBaseUrl
    chainIndexEnv <- clientEnv (ChainIndex.ciBaseUrl chainIndexConfig)
    dbConnection <- dbConnect appTrace dbConfig
    txSendHandle <- liftIO $ MockClient.runTxSender mscSocketPath
    -- This is for access to the slot number in the interpreter
    chainSyncHandle <- Left <$> (liftIO $ MockClient.runChainSync' mscSocketPath mscSlotConfig)
    appInMemContractStore <- liftIO initialInMemInstances
    protocolParameters <- maybe (pure def) readPP mscProtocolParametersJsonPath
    pure AppEnv {..}
  where
    clientEnv baseUrl = mkClientEnv <$> liftIO mkManager <*> pure (coerce baseUrl)

    mkManager =
        newManager $
        tlsManagerSettings {managerModifyRequest = pure . setRequestIgnoreStatus}

    readPP path = do
      bs <- BSL.readFile path
      case eitherDecode bs of
        Left err -> error $ "Error reading protocol parameters JSON file: " ++ show mscProtocolParametersJsonPath ++ " (" ++ err ++ ")"
        Right params -> pure params


logDebugString :: Trace IO (PABLogMsg t) -> Text -> IO ()
logDebugString trace = logDebug trace . SMultiAgent . UserLog

-- | Initialize/update the database to hold our effects.
migrate :: Trace IO (PABLogMsg (Builtin a)) -> DbConfig -> IO ()
migrate trace config = do
    connection <- dbConnect trace config
    logDebugString trace "Running beam migration"
    runBeamMigration trace connection

runBeamMigration
  :: Trace IO (PABLogMsg (Builtin a))
  -> Sqlite.Connection
  -> IO ()
runBeamMigration trace conn = Sqlite.runBeamSqliteDebug (logDebugString trace . pack) conn $ do
  autoMigrate Sqlite.migrationBackend checkedSqliteDb

-- | Connect to the database.
dbConnect :: Trace IO (PABLogMsg (Builtin a)) -> DbConfig -> IO Sqlite.Connection
dbConnect trace DbConfig {dbConfigFile} = do
  logDebugString trace $ "Connecting to DB: " <> dbConfigFile
  open (unpack dbConfigFile)

handleContractDefinition ::
  forall a effs. HasDefinitions a
  => ContractDefinition (Builtin a)
  ~> Eff effs
handleContractDefinition = \case
  AddDefinition _ -> pure ()
  GetDefinitions  -> pure getDefinitions
