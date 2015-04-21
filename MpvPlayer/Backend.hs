module MpvPlayer.Backend where

import Data.List
import Data.List.Split (splitOn)
import Data.Word
import Data.IORef
import Data.Maybe
import System.Process hiding (createPipe)
import System.IO
import System.Posix.IO
import System.Directory
import Text.Printf
import Text.Read
import Control.Concurrent 
import Control.Monad
import Control.Exception

data PlayStatus = PlayStatus {
      playStatusPaused :: Bool,
      playStatusLength :: Double,
      playStatusPos :: Double,
      playStatusMuted :: Bool,
      playStatusVol :: Int,
      playStatusFullscreen :: Bool
} deriving (Show)

data Player = Player {
      playerWid :: Word32,

      playerProcess :: ProcessHandle,
      playerCmdIn :: Handle,
      playerCmdInFilePath :: FilePath,

      playerOutWrite :: Handle,
      playerOutRead :: Handle
}

data PlayerDead = PlayerDead

cmdPrefix :: String
cmdPrefix = "mpvguihs command response: "

buildArgs :: Word32 -> FilePath -> FilePath -> String -> [String]
buildArgs wid fifo filename extraArgs = filter (not . null) $ 
  ["--wid=" ++ (printf "0x%x" wid), 
   "--input-file=" ++ fifo, 
   "--status-msg=",
   extraArgs,
   filename]

getResponse :: String -> Handle -> IO (Maybe String)
getResponse prefix readHandle = do
  ready <- hReady readHandle
  if ready
    then do
      line <- hGetLine readHandle 
      let status = stripPrefix prefix line
      case status of
        Nothing -> putStrLn line >> getResponse prefix readHandle
        Just i  -> return $ Just i
    else return Nothing

getProperty :: Handle -> Handle -> String -> IO (Maybe String)
getProperty hIn hOut p = do
  let str = concat ["print_text \"", cmdPrefix, p, "\""]
  ex <- try $ hPutStrLn hIn str :: IO (Either SomeException ())
  case ex of
    Left _  -> return Nothing
    Right _ -> getResponse cmdPrefix hOut                 

parseLines :: Maybe PlayStatus -> Handle -> IO (Maybe PlayStatus)
parseLines ps readHandle = do
  info <- getResponse cmdPrefix readHandle
  case info of
    Nothing -> return ps
    Just i  ->
      let [len, r, p, m, vol, fs] = words' i
          len' = fromMaybe 0.0 $ readMaybe len
          r' = fromMaybe 0.0 $ readMaybe r
          paused = p == "yes"
          muted = m == "yes"
          vol' = round $ (fromMaybe 0.0 $ readMaybe vol :: Double)
          fullscreen = fs == "yes"
      in parseLines (Just $ PlayStatus paused 
                                       len' 
                                       r' 
                                       muted 
                                       vol' 
                                       fullscreen) readHandle
  where words' = splitOn " " -- Behaves better than "words"

hPutStrLnSafe :: Handle -> String -> IO ()
hPutStrLnSafe h str = catch (hPutStrLn h str) ignoreException
  where ignoreException :: SomeException -> IO ()
        ignoreException _ = return ()

mpvGetPlayStatus :: IORef Player -> IO (Either PlayerDead (Maybe PlayStatus))
mpvGetPlayStatus playerRef = do
  p <- readIORef playerRef

  catch (do hPutStrLn (playerCmdIn p) $ concat 
              ["print_text \"", cmdPrefix,
               "${=length} ${=time-pos} ${pause} " ++
               "${mute} ${volume} ${fullscreen}\""]
    
            ps <- catch (parseLines Nothing $ playerOutRead p) $ printException
            return $ Right ps)
        handleNoPlayerException

  where printException :: SomeException -> IO (Maybe PlayStatus)
        printException e = print e >> return Nothing
        handleNoPlayerException :: SomeException 
                                -> IO (Either PlayerDead (Maybe PlayStatus))
        handleNoPlayerException _ = return $ Left PlayerDead

mpvPlay :: Word32 -> FilePath -> String -> IO (IORef Player)
mpvPlay wid filename extraArgs = do
  tmpDir <- getTemporaryDirectory

  (cmdFile, cmdHandle) <- openTempFile tmpDir "mpvguihs"
  hClose cmdHandle         
  removeFile cmdFile
  system $ "mkfifo " ++ cmdFile

  let args = buildArgs wid cmdFile filename extraArgs
  putStrLn $ "Launching mpv with args: " ++ show args
  
  (readFd, writeFd) <- createPipe
  outWrite <- fdToHandle writeFd
  outRead <- fdToHandle readFd
  
  errWrite <- openFile "/dev/null" WriteMode

  process <- runProcess "mpv" args 
             Nothing Nothing Nothing (Just outWrite) (Just errWrite)

  cmdFd <- openFd cmdFile WriteOnly Nothing defaultFileFlags
  cmdHandle' <- fdToHandle cmdFd
  hSetBuffering cmdHandle' NoBuffering

  newIORef $ Player wid process cmdHandle' cmdFile outWrite outRead

mpvPause :: IORef Player -> IO ()
mpvPause playerRef = do
  player <- readIORef playerRef
  status <- mpvGetPlayStatus playerRef
  case status of
    Left _         -> return ()
    Right Nothing  -> mpvPause playerRef
    Right (Just s) -> when (not $ playStatusPaused s) $ 
                        hPutStrLnSafe (playerCmdIn player) "cycle pause"
  
mpvUnpause :: IORef Player -> IO ()
mpvUnpause playerRef = do
  player <- readIORef playerRef
  status <- mpvGetPlayStatus playerRef
  case status of 
    Left _         -> return ()
    Right Nothing  -> mpvUnpause playerRef
    Right (Just s) -> when (playStatusPaused s) $ 
                        hPutStrLnSafe (playerCmdIn player) "cycle pause"

mpvSeek :: IORef Player -> Double -> IO ()
mpvSeek player ratio = do
  p <- readIORef player
  let percent = ratio * 100
  hPutStrLnSafe (playerCmdIn p) $ printf "seek %f absolute-percent" percent

mpvStop :: IORef Player -> IO ()
mpvStop playerRef = do
  p <- readIORef playerRef
  hPutStrLnSafe (playerCmdIn p) "stop"

mpvSetMuted :: IORef Player -> Bool -> IO ()
mpvSetMuted playerRef val = do
  p <- readIORef playerRef
  let val' = if val then "yes" else "no"
  hPutStrLnSafe (playerCmdIn p) $ "set mute " ++ val'

mpvSetVolume :: IORef Player -> Int -> IO ()
mpvSetVolume playerRef vol = do
  p <- readIORef playerRef
  hPutStrLnSafe (playerCmdIn p) $ "set volume " ++ show vol

mpvToggleFullscreen :: IORef Player -> IO ()
mpvToggleFullscreen playerRef = do
  p <- readIORef playerRef
  hPutStrLnSafe (playerCmdIn p) $ "cycle fullscreen"
  
{- Test:
mpvGetMetadata :: IORef Player -> IO (String, String)
mpvGetMetadata playerRef = do
  p <- readIORef playerRef
  prop <- getProperty (playerCmdIn p) (playerOutRead p) "${metadata}"
  print prop
  return ("", "")
-}

mpvTerminate :: IORef Player -> IO ()
mpvTerminate playerRef = do
  p <- readIORef playerRef
  let h = playerCmdIn p
  hPutStrLnSafe h "quit 0"

  hClose h 
  hClose $ playerOutRead p
  hClose $ playerOutWrite p

  removeFile $ playerCmdInFilePath p

  threadDelay 250000
  terminateProcess (playerProcess p)

