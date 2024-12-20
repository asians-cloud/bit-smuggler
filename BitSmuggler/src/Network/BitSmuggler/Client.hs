{-# LANGUAGE RecordWildCards #-}
module Network.BitSmuggler.Client where

import Prelude as P hiding (read)
import qualified Data.Tuple as Tup
import Control.Monad.Trans.Resource
import System.Log.Logger
import Control.Monad.IO.Class
import Control.Monad
import Control.Exception
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM.TQueue
import System.Random
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import Data.Conduit as DC
import Data.Conduit.List as DC

import Network.BitTorrent.ClientControl
import Network.TCP.Proxy.Server as Proxy hiding (UnsupportedFeature, logger)

import Network.BitSmuggler.Common
import Network.BitSmuggler.Crypto as Crypto
import Network.BitSmuggler.Protocol
import Network.BitSmuggler.Utils
import Network.BitSmuggler.ARQ as ARQ

{-

client is designed to support 1 single connection
at the moment. this simplifies the code for now.

Client and server are quite similar. in the end they can
be written as peers, not clients and servers, and any 
peer can make and recieve connection.

for now we stick with this design to cover the proxy 
server usecase. 

A proxy server could just be a peer with more bandwitdth
and a better a machine to back it up.
-}

data ClientConfig = ClientConfig {
    btClientConfig :: BTClientConfig
  , serverDescriptor :: ServerDescriptor
  , fileCachePath :: FilePath
}

data ClientStage = FirstConnect | Reconnect SessionToken

data ClientState = ClientState {
    serverToken :: Maybe SessionToken
--  , currentInfoHash :: InfoHash
}


clientConnect :: ClientConfig -> (ConnData -> IO ()) -> IO ()
clientConnect (ClientConfig {..}) handle = runResourceT $ do

  liftIO $ debugM logger "starting client "

  -- start torrent client (with config)
  (btProc, btClientConn) <- setupBTClient $ btClientConfig

  let possibleContacts = contactFiles $ serverDescriptor
  files <- setupContactFilesLazy possibleContacts fileCachePath


  -- == CLIENT INITIALIZATION =
  cprg <- liftIO $ makeCPRG
  let (cryptoOps, pubKeyRepr) = makeClientEncryption (serverPubKey serverDescriptor) cprg
  encryptCprg <- liftIO $ makeCPRG
  let clientEncrypter = encrypter (encrypt cryptoOps) encryptCprg

  pieceHooks <- liftIO $ makePieceHooks

  controlSend <-liftIO $ (newTQueueIO :: IO (TQueue ClientMessage))
  controlRecv <- liftIO $ (newTQueueIO :: IO (TQueue ServerMessage))
  let controlPipe = Pipe controlRecv controlSend

  dataGate <- liftIO $ newGate
  let dataPipes = DataPipes controlPipe pieceHooks dataGate
  
  userPipe <- launchPipes packetSize initGoBackNARQ
                          clientEncrypter (decrypt cryptoOps)  dataPipes
  userGate <- liftIO $ newGate -- closed gate

  clientState <- liftIO $ newTVarIO $ ClientState Nothing 

  let fileFixer = findPieceLoader files
 
  let handleConn = handleConnection clientState
                    (cryptoOps, pubKeyRepr) userPipe userGate dataPipes

  let onDisconnect = do
                  debugM logger "bitsmuggler connection disconnect occured."
                  atomically $ closeGate dataGate
                  return ()

    
  let onConn = clientProxyInit handleConn onDisconnect
                pieceHooks fileFixer (serverAddr serverDescriptor)

  liftIO $ debugM logger "finished initializng client..."

  -- setup proxies (socks and reverse)
  (reverseProxy, forwardProxy) <- startProxies btClientConfig onConn
  
  -- tell client to start working on file chosen at random
  firstFile <- pickRandFile files

  liftIO $ debugM logger "adding files to bittorrent client..."
  liftIO $ addTorrents btClientConn (fst btProc) [firstFile]

  liftIO $ do
    debugM logger "waiting for user handle to execute."
    atomically $ goThroughGate userGate
    debugM logger "starting user handler execution"
    handle $ pipeToConnData userPipe
    -- after user function executed 
    flushMsgQueue (pipeSend userPipe)

    debugM logger "client is terminated."

  return ()


clientProxyInit handleConn onConnLoss pieceHs fileFix serverAddress direction local remote = do

  liftIO $ debugM logger $ "bittorrent client connects to remote " P.++ (show remote)
  liftIO $ debugM logger $ "expected server address is " P.++ (show serverAddress)

  if ((fst remote) == serverAddress)
  then do
    liftIO $ debugM logger $ "it's a bitsmuggler connection. handle it. "

    forkIO $ handleConn
    streams <- fmap (if direction == Reverse then Tup.swap else P.id) $
                    makeStreams pieceHs fileFix
    return $ DataHooks { incoming = P.fst streams
                         , outgoing = P.snd streams 
                         , onDisconnect = onConnLoss
                        }

  -- it's some other connection - just proxy data without any 
  -- parsing or tampering
  else return $ Proxy.DataHooks { incoming = DC.map P.id
                          , outgoing = DC.map P.id
                          , onDisconnect = return () -- don't do anything
                        }

handleConnection stateVar  (cryptoOps, repr) userPipe userGate
  (DataPipes control (PieceHooks {..}) dataGate) = do
  state <- atomically $ readTVar stateVar

  cprg <- makeCPRG
  let prevToken = serverToken state

  noGate <- newGate
  atomically $ openGate noGate

  debugM logger "sending handshake message to the server..."

  -- send the first message (hanshake)
  -- the size of the block is smaller bc we need to make space for the
  -- elligatored publick key of the client
  -- and larger cause there is no ARQ for this message
  DC.sourceList [Just $ Control $ ConnRequest repr (serverToken state)]
             =$ sendPipe (packetSize + ARQ.headerLen - Crypto.keySize) (sendARQ noARQ)
                  (encrypter (encryptHandshake (cryptoOps, repr)) cprg)
             $$ outgoingSink (atomically $ read sendGetPiece) 
                             (\p -> atomically $ write sendPutBack p) noGate
  debugM logger "SENT the handshake message to the server."

  -- let any potential messages flow
  atomically $ openGate dataGate 
  if (prevToken == Nothing) then do -- first time connecting
    serverResponse <- liftIO $ atomically $ readTQueue (pipeRecv control)
    case serverResponse of
      AcceptConn token -> do
        liftIO $ debugM logger $ "connection to server succesful "

        atomically $ modifyTVar stateVar (\s -> s {serverToken = Just token}) 
        atomically $ openGate userGate -- start the user function
      RejectConn -> do
        errorM logger "connection rejected"
        -- TODO: clean up conn
        return ()
  else do
    infoM logger "it's a reconnect. nothing to do..."
  return ()


-- file replenishing on the client side
replenishTorrentFile btClientConn btProc files current = do
  threadDelay $ 5 * milli -- check every 5s
  [t] <- listTorrents btClientConn
  if isUsedUp t || isStale t
  then do   
    removeTorrentWithData btClientConn (P.fst current) -- remove the old
    nextFile <- pickRandFile files
    giveClientPartialFile btClientConn btProc nextFile
  else replenishTorrentFile btClientConn btProc files current -- keep going

isStale = undefined

pickRandFile files = fmap (files !!) $ liftIO $ randInt (0, P.length files - 1)

randInt :: (Int, Int) ->  IO Int 
randInt range = getStdGen >>= return . fst . (randomR range)
