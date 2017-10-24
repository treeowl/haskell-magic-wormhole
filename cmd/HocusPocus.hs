-- | Command-line tool for opening and communicating through magic wormholes.
--
-- Intended to inter-operate with the `wormhole` command-line tool from
-- [magic-wormhole](https://github.com/warner/magic-wormhole).
module Main (main) where

import Protolude

import Control.Monad (fail)
import Data.Aeson (FromJSON(..), Value(Object), (.:), eitherDecode)
import Data.Aeson.Types (typeMismatch)
import Data.String (String)
import Network.Socket (withSocketsDo)
import Network.URI (URI(..), URIAuth(..), parseURI)
import qualified Network.WebSockets as WS
import qualified Options.Applicative as Opt


data Options
  = Options
  { cmd :: Command
  , rendezvousEndpoint :: WebSocketEndpoint
  } deriving (Eq, Show)

optionsParser :: Opt.Parser Options
optionsParser
  = Options
  <$> commandParser
  <*> Opt.option
        (Opt.maybeReader (toWebSocketEndpoint <=< parseURI))
        ( Opt.long "rendezvous-url" <>
          Opt.help "Endpoint for the Rendezvous server" <>
          Opt.value defaultEndpoint <>
          Opt.showDefault )
  where
    -- | Default URI for rendezvous server.
    --
    -- This is Brian Warner's personal server.
    defaultEndpoint = fromMaybe (panic "Invalid default URL") (toWebSocketEndpoint <=< parseURI $ "ws://relay.magic-wormhole.io:4000/v1")


-- | Endpoint for a websocket connection.
data WebSocketEndpoint = WebSocketEndpoint Hostname Port Path deriving (Eq, Show)

type Hostname = String
type Port = Int
type Path = String

-- | Turn a 'URI' into a 'WebSocketEndpoint', if we can.
--
-- Requires that the URI has an authority (i.e. host & port).
-- Discards information from scheme, query, and fragment.
toWebSocketEndpoint :: URI -> Maybe WebSocketEndpoint
toWebSocketEndpoint uri = do
  authority <- uriAuthority uri
  port <- case uriPort authority of
            "" -> empty
            _:rest -> readMaybe rest
  pure $ WebSocketEndpoint (uriRegName authority) port (uriPath uri)

data Command
  = Send
  | Receive
  deriving (Eq, Show)

commandParser :: Opt.Parser Command
commandParser = Opt.hsubparser $
  Opt.command "send" (Opt.info (pure Send) (Opt.progDesc "Send a text message, file, or directory")) <>
  Opt.command "receive" (Opt.info (pure Receive) (Opt.progDesc "Receive a text message, file, or directory"))

makeOptions :: Text -> Opt.Parser a -> Opt.ParserInfo a
makeOptions headerText parser = Opt.info (Opt.helper <*> parser) (Opt.fullDesc <> Opt.header (toS headerText))

-- | A message that can be sent to or received from the server.
--
-- Notes
-- * clients & servers MUST ignore unrecognized keys in otherwise-recognized
--   messages
--
-- Error messages
-- * welcome messages can include 'error'
-- * there's a general 'error' type (indicated by 'type': 'error' key)
--   which also includes an 'orig' message
--
-- Some open questions:
-- * general message stuff--how are we going to model this?
--   * outgoing messages include a randomly generated 'id' field, which is
--     returned by the server
--   * messages from the server include 'server_tx', a float timestamp recording
--     when the server received the message
--   * messages from the server that are direct responses include a 'server_rx'
--     timestamp
--   * do we want a separate Haskell type for each message type? e.g. PingMessage
--   * if we do that, how do associate request/response pairs? e.g. PingMessage &
--     PongMessage?
--   * do we want to have different types for messages from server (e.g. Ack,
--     Welcome, Pong) vs messages from client (e.g. Ping, Bind)?
data Message
  = Welcome
  | Ping
  | Pong
  | Ack
  deriving (Eq, Show)

instance FromJSON Message where
  parseJSON (Object v) = do
    t <- v .: "type"
    case t of
      "welcome" -> pure Welcome
      "ping" -> pure Ping
      "pong" -> pure Pong
      "ack" -> pure Ack
      _ -> fail $ "Unrecognized type: " <> t
  parseJSON unknown = typeMismatch "Message" unknown

-- | Execute 'Command' against a Wormhole Rendezvous server.
app :: Command -> WS.ClientApp ()
app command conn = do
  print command
  -- XXX: Just block waiting for the server to tell us stuff. To be a proper
  -- client, we want to get stuff from the server and send stuff more or less
  -- simultaneously.
  void $ forever $ do
    message <- eitherDecode @Message <$> WS.receiveData conn
    liftIO $ case message of
      Left err -> putStrLn $ "ERROR: " <> err
      -- XXX: What's `msg` in Protolude?
      Right message' -> print message'

main :: IO ()
main = do
  options <- Opt.execParser (makeOptions "hocus-pocus - summon and traverse magic wormholes" optionsParser)
  let WebSocketEndpoint host port path = rendezvousEndpoint options
  withSocketsDo $ WS.runClient host port path (app (cmd options))
