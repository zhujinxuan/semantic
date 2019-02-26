{-# LANGUAGE LambdaCase #-}

module Semantic.Config
  ( Config (..)
  , defaultConfig
  , Options (..)
  , defaultOptions
  , debugOptions
  , infoOptions
  , lookupStatsAddr
  , withHaystackFromConfig
  , logOptionsFromConfig
  , withLoggerFromConfig
  , withStatterFromConfig
  , withTelemetry
  ) where

import           Data.Duration
import           Network.HostName
import           Network.HTTP.Client.TLS
import           Network.URI
import           Prologue
import           Semantic.Env
import           Semantic.Telemetry
import qualified Semantic.Telemetry.Haystack as Haystack
import qualified Semantic.Telemetry.Stat as Stat
import           System.Environment
import           System.IO (hIsTerminalDevice, stdout)
import           System.Posix.Process
import           System.Posix.Types

data Config
  = Config
  { configAppName                :: String       -- ^ Application name ("semantic")
  , configHostName               :: String       -- ^ HostName from getHostName
  , configProcessID              :: ProcessID    -- ^ ProcessID from getProcessID
  , configHaystackURL            :: Maybe String -- ^ URL of Haystack (with creds) from environment
  , configStatsHost              :: Stat.Host    -- ^ Host of statsd/datadog (default: "127.0.0.1")
  , configStatsPort              :: Stat.Port    -- ^ Port of statsd/datadog (default: "28125")

  , configTreeSitterParseTimeout :: Duration     -- ^ Timeout in milliseconds before canceling tree-sitter parsing (default: 6000).
  , configAssignmentTimeout      :: Duration     -- ^ Millisecond timeout for assignment (default: 4000)
  , configMaxTelemetyQueueSize   :: Int          -- ^ Max size of telemetry queues before messages are dropped (default: 1000).
  , configIsTerminal             :: Bool         -- ^ Whether a terminal is attached (set automaticaly at runtime).
  , configLogPrintSource         :: Bool         -- ^ Whether to print the source reference when logging errors (set automatically at runtime).
  , configLogFormatter           :: LogFormatter -- ^ Log formatter to use (set automaticaly at runtime).
  , configSHA                    :: Maybe String -- ^ Optional SHA to include in log messages.
  , configFailParsingForTesting  :: Bool         -- ^ Simulate internal parse failure for testing (default: False).

  , configOptions                :: Options      -- ^ Options configurable via command line arguments.
  }

-- Options configurable via command line arguments.
data Options
  = Options
  { optionsLogLevel         :: Maybe Level   -- ^ What level of messages to log. 'Nothing' disables logging.
  , optionsFailOnWarning    :: Bool          -- ^ Should semantic fail fast on assignment warnings (for testing)
  , optionsFailOnParseError :: Bool          -- ^ Should semantic fail fast on tree-sitter parser errors (for testing)
  }

defaultOptions :: Options
defaultOptions = Options (Just Warning) False False

debugOptions :: Options
debugOptions = Options (Just Debug) False False

infoOptions :: Options
infoOptions = Options (Just Info) False False

defaultConfig :: Options -> IO Config
defaultConfig options@Options{..} = do
  pid <- getProcessID
  hostName <- getHostName
  isTerminal <- hIsTerminalDevice stdout
  haystackURL <- lookupEnv "HAYSTACK_URL"
  (statsHost, statsPort) <- lookupStatsAddr
  size <- envLookupNum 1000 "MAX_TELEMETRY_QUEUE_SIZE"
  parseTimeout <- envLookupNum 6000 "TREE_SITTER_PARSE_TIMEOUT"
  assignTimeout <- envLookupNum 4000 "SEMANTIC_ASSIGNMENT_TIMEOUT"
  pure Config
    { configAppName = "semantic"
    , configHostName = hostName
    , configProcessID = pid
    , configHaystackURL = haystackURL
    , configStatsHost = statsHost
    , configStatsPort = statsPort

    , configTreeSitterParseTimeout = fromMilliseconds parseTimeout
    , configAssignmentTimeout = fromMilliseconds assignTimeout
    , configMaxTelemetyQueueSize = size
    , configIsTerminal = isTerminal
    , configLogPrintSource = isTerminal
    , configLogFormatter = if isTerminal then terminalFormatter else logfmtFormatter
    , configSHA = Nothing
    , configFailParsingForTesting = False

    , configOptions = options
    }

withTelemetry :: Config -> (TelemetryQueues -> IO c) -> IO c
withTelemetry config action =
  withLoggerFromConfig config $ \logger ->
  withHaystackFromConfig config (queueLogMessage logger Error) $ \haystack ->
  withStatterFromConfig config $ \statter ->
    action (TelemetryQueues logger statter haystack)

logOptionsFromConfig :: Config -> LogOptions
logOptionsFromConfig Config{..} = LogOptions
  { logOptionsLevel     = optionsLogLevel configOptions
  , logOptionsFormatter = configLogFormatter
  , logOptionsContext   = logOptionsContext' configIsTerminal
  }
  where logOptionsContext' = \case
          False -> [ ("app", configAppName)
                   , ("pid", show configProcessID)
                   , ("hostname", configHostName)
                   , ("sha", fromMaybe "development" configSHA)
                   ]
          _     -> []


withLoggerFromConfig :: Config -> (LogQueue -> IO c) -> IO c
withLoggerFromConfig config = withLogger (logOptionsFromConfig config) (configMaxTelemetyQueueSize config)


withHaystackFromConfig :: Config -> Haystack.ErrorLogger -> (HaystackQueue -> IO c) -> IO c
withHaystackFromConfig Config{..} errorLogger =
  withHaystack configHaystackURL tlsManagerSettings configAppName errorLogger configMaxTelemetyQueueSize

withStatterFromConfig :: Config -> (StatQueue -> IO c) -> IO c
withStatterFromConfig Config{..} =
  withStatter configStatsHost configStatsPort configAppName configMaxTelemetyQueueSize

lookupStatsAddr :: IO (Stat.Host, Stat.Port)
lookupStatsAddr = do
  addr <- lookupEnv "STATS_ADDR"
  let (host', port) = parseAddr (fmap ("statsd://" <>) addr)

  -- When running in Kubes, DOGSTATSD_HOST is set with the dogstatsd host.
  kubesHost <- lookupEnv "DOGSTATSD_HOST"
  let host = fromMaybe host' kubesHost

  pure (host, port)
  where
    defaultHost = "127.0.0.1"
    defaultPort = "28125"
    parseAddr a | Just s <- a
                , Just (Just (URIAuth _ host port)) <- uriAuthority <$> parseURI s
                = (parseHost host, parsePort port)
                | otherwise = (defaultHost, defaultPort)
    parseHost s = if null s then defaultHost else s
    parsePort s = if null s then defaultPort else dropWhile (':' ==) s
