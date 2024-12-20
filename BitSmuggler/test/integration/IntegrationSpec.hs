{-# LANGUAGE OverloadedStrings #-}
module IntegrationSpec (main, spec) where

import Test.Hspec
import Test.QuickCheck

import Prelude as P
import Data.Torrent
import Data.Maybe
import Data.Text as T
import Data.ByteString as BS
import Data.ByteString.Lazy as BSL
import System.FilePath.Posix
import Crypto.Random.AESCtr as AESCtr
import Data.IP
import Data.Serialize as DS
import Data.Map.Strict as Map
import Data.Binary as Bin
import Crypto.Random
import Crypto.Curve25519
import Data.Byteable
import qualified Network.BitTorrent.ClientControl as BT
import qualified Network.BitTorrent.ClientControl.UTorrent as UT
import System.IO
import System.Log.Logger
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TChan

import Control.Exception.Base
import Control.Monad
import Control.Monad.Trans.Resource
import Control.Monad.IO.Class
import Data.Conduit as DC
import Data.Conduit.List as DC
import Data.Conduit.Binary as CBin
import Data.Conduit.Network

import qualified Network.BitTorrent.Shepherd as Tracker

import Network.TCP.Proxy.Server as Proxy hiding (UnsupportedFeature, logger)
import Network.TCP.Proxy.Socks4 as Socks4

import Network.BitSmuggler.Proxy.Client (proxyClient)
import Network.BitSmuggler.Proxy.Server (proxyServer)

import Network.BitSmuggler.Common as Common
import Network.BitSmuggler.Common as Protocol
import Network.BitSmuggler.Utils
import Network.BitSmuggler.TorrentFile
import Network.BitSmuggler.Crypto as Crypto
import Network.BitSmuggler.Server as Server
import Network.BitSmuggler.Client as Client
import Network.BitSmuggler.FileCache as Cache
import Network.BitSmuggler.TorrentClientProc as Proc
import Network.BitSmuggler.Protocol

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "bit-smuggler" $ do
    it "proxies data between 1 client and 1 server" $ do
      P.putStrLn "wtf"
      runClientServer clientChunkExchange serverChunkExchange [bigFile]
  return ()

{-

Integration test for bitsmuggler with 1 server and 1 client
both running on the same machine
-}


testRoot = "test-data/integration-test/"


data TestFile = TestFile {metadata :: (FilePath, Text, Int), fileDataPath :: String}
--1 gb file
bigFile = TestFile bigTestFile bigTestDataFile
bigTestFile = (testRoot </> "contactFile/testFileBig.torrent"
                , "ef967fc9d342a4ba5c4604c7b9f7b28e9e740b2f"
                , 69)

bigTestDataFile = testRoot </> "contactFile/testFileBig.txt"


-- 100 mb file
smallFile = TestFile smallTestFile smallTestDataFile
smallTestFile = (testRoot </> "contactFile/testFile.torrent"
                , "f921dd6548298527d40757fb264de07f7a47767f"
                , 23456)
smallTestDataFile = testRoot </> "contactFile/testFile.txt"

makePaths prefix = P.map ((testRoot </> prefix) </> ) ["cache", "utorrent-client"]

localhostIP = IPv4 $ toIPv4 [127,0,0,1]

runClientServer clientProto serverProto testFiles = runResourceT $ do

  liftIO $ updateGlobalLogger logger  (setLevel DEBUG)
  liftIO $ updateGlobalLogger Tracker.logger  (setLevel DEBUG)

  liftIO $ debugM logger "running integration test"

  let [serverCache, serverUTClientPath] = makePaths "server"
  let [clientCache, clientUTClientPath] = makePaths "client"

  contacts <- forM testFiles $ \testFile -> liftIO $ makeContactFile (metadata testFile)
  (serverDesc, serverSk)
    <- liftIO $ makeServerDescriptor contacts localhostIP

  -- launch the tracker
  trackEvents <- liftIO $ newTChanIO
  tracker <- allocAsync $ async $ Tracker.runTracker
                      $ Tracker.Config { Tracker.listenPort = 6666
                                         , Tracker.events = Just trackEvents}
  liftIO $ waitFor (== Tracker.Booting) trackEvents

  serverDone <- liftIO $ newGate
  clientDone <- liftIO $ newGate

  allocAsync $ async $ runServer (\c -> serverProto c
                                        `finally` (atomically $ openGate serverDone))
                                 serverUTClientPath serverCache contacts
                                       (serverDesc, serverSk)

  liftIO $ debugM logger "booted server.."

--  liftIO $ threadDelay $ 10 ^ 9

  liftIO $ waitFor (\(Tracker.AnnounceEv a) -> True) trackEvents
  liftIO $ debugM logger "tracker got announce from the server"

  liftIO $ debugM logger "running client now"

  allocAsync $ async $ runClient (\ c -> clientProto c
                                         `finally` (atomically $ openGate clientDone))
                                 clientUTClientPath clientCache serverDesc

  liftIO $ atomically $ goThroughGate clientDone
  liftIO $ atomically $ goThroughGate serverDone
  -- liftIO $ threadDelay $ 10 ^ 9

  liftIO $ debugM logger "finished running integration test" 
  return ()


 -- UTORRENT based client and server 
runClient protocol torrentProcPath cachePath serverDesc = do
  proc <- uTorrentProc torrentProcPath

  let btC = clientBTClientConfig {
                btProc = proc
              , outgoingRedirects
                             = redirectToRev (serverAddr serverDesc) serverBTClientConfig
              }

  Client.clientConnect (ClientConfig btC serverDesc cachePath) protocol 


runServer protocol torrentProcPath cachePath contacts (serverDesc, serverSk) = do

  proc <- uTorrentProc torrentProcPath
  let btC = serverBTClientConfig {
                 btProc = proc
               , outgoingRedirects
                  = redirectToRev (serverAddr serverDesc) clientBTClientConfig 
               }

  Server.listen (ServerConfig serverSk btC contacts cachePath) protocol


-- were are configuring the proxies to redirect the bittorrent traffic
-- to the reverse proxy port
-- so that we don't need to play with iptables
redirectToRev ip conf = Map.fromList
   [((Right ip, pubBitTorrentPort conf),(Right ip, revProxyPort conf))]


chunks = [ BS.replicate 1000 99, BS.replicate (10 ^ 4)  200
         , BS.concat [BS.replicate (10 ^ 4) 39, BS.replicate (10 ^ 4) 40]
         , BS.replicate (10 ^ 4)  173
         , BS.replicate (10 ^ 3)  201
         , BS.replicate (10 ^ 3)  202] P.++ smallChunks

smallChunks = P.take 10 $ P.map (BS.replicate (10 ^ 2)) $ P.cycle [1..255]

-- TODO: reabilitate those to use the new connData
serverChunkExchange c = do
  infoM logger "server ping pongs some chunks with the client.."
  (connSource c) =$ serverChunks (P.zip chunks [1..]) $$ (connSink c)
  return ()

serverChunks [] = return ()
serverChunks ((chunk, i) : cs) = do
  upstream <- await
  case upstream of
    (Just bigBlock) -> do
      liftIO $ bigBlock `shouldBe` chunk
      liftIO $ debugM logger $ "server received big chunk succesfully " P.++ (show i)
      DC.yield chunk
      serverChunks cs 
    Nothing -> (liftIO $ debugM logger "terminated from upstream") >> return ()

clientChunks [] = return ()
clientChunks ((chunk, i) : cs) = do
  DC.yield chunk -- send first, recieve after
  upstream <- await
  case upstream of
    (Just bigBlock) -> do
      liftIO $ bigBlock `shouldBe` chunk
      liftIO $ debugM logger $ "server received big chunk succesfully " P.++ (show i)
      clientChunks cs 
    Nothing -> (liftIO $ debugM logger "terminated from upstream") >> return ()

clientChunkExchange c = do
  infoM logger "client ping pongs some chunks with the server.."
  (connSource c) =$ clientChunks (P.zip chunks [1..]) $$ (connSink c)

  return ()

makeContactFile (filePath, infoHash, seed) = do
  Right t <- fmap readTorrent $ BSL.readFile $ filePath
  return $ FakeFile {seed = seed, torrentFile = t
                    , infoHash = fromJust $ textToInfoHash infoHash}

makeServerDescriptor contacts ip = do
  let cprg = cprgCreate $ createTestEntropyPool "leSeed" :: AESRNG
  let (skBytes, next2) = cprgGenerate Crypto.keySize cprg
  let serverSkWord = (fromRight $ DS.decode skBytes :: Key)
  let serverPk = derivePublicKey (fromBytes $ toBytes serverSkWord)
  let serverPkWord = (fromRight $ DS.decode (toBytes serverPk) :: Key)

  return $ (ServerDescriptor ip contacts serverPkWord
            , serverSkWord)


initIntegrationTestCaches testFile = do
  let serverCache = P.head $ makePaths "server"
  let clientCache = P.head $ makePaths "client"
  initFileCache serverCache  testFile
  initFileCache clientCache testFile


initFileCache cachePath testFile = do
  let (tpath, ih, seed)  = metadata testFile
  fHandle <- openFile (fileDataPath testFile) ReadMode
  cache <- Cache.load cachePath  
  Cache.put cache (fromJust $ textToInfoHash ih)
                  $  sourceHandle fHandle
  hClose fHandle
  Cache.close cache


uTorrentConnect host port = UT.makeUTorrentConn host port ("admin", "")

waitFor cond chan = do
  n <- atomically $ readTChan chan
  if (cond n) then return n else waitFor cond chan


clientBTClientConfig = BTClientConfig {
    pubBitTorrentPort = 5881
  , socksProxyPort = 2001
  , revProxyPort = 2002
  , cmdPort = 8000 -- port on which it's receiving commands
    -- host, port, (uname, password)
  , connectToClient = uTorrentConnect
}

serverBTClientConfig = BTClientConfig {
    pubBitTorrentPort = 7881
  , socksProxyPort = 3001
  , revProxyPort = 3002
  , cmdPort = 9000 -- port on which it's receiving commands
    -- host, port, (uname, password)
  , connectToClient = uTorrentConnect
}
