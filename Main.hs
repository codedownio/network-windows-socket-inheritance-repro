{-# LANGUAGE LambdaCase #-}

import Control.Concurrent
import Foreign
import Control.Monad
import qualified Data.ByteString as BS
import Network.Socket
import Network.Socket.ByteString (recv)
import System.Environment
import System.IO
import System.Process
import System.Timeout

-- Accept a connection, spawn a child that outlives it, close the connection, and see whether
-- the peer gets EOF
run :: String -> Maybe (StdStream, Bool) -> IO ()
run label childOpts = do
  listener <- socket AF_INET Stream defaultProtocol
  bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  listen listener 1
  port <- socketPort listener
  client <- socket AF_INET Stream defaultProtocol
  connect client (SockAddrInet port (tupleToHostAddress (127, 0, 0, 1)))
  (conn, _) <- accept listener
  forM_ [("listener", listener), ("client", client), ("conn", conn)] $ \(n, sk) -> do
    fd <- unsafeFdSocket sk
    flags <- alloca $ \p -> c_GetHandleInformation (wordPtrToPtr (fromIntegral fd)) p >> peek p
    putStrLn ("  " ++ n ++ " handle flags: " ++ show flags)

  self <- getExecutablePath
  child <- forM childOpts $ \(s, cf) -> do
    (_, _, _, ph) <- createProcess (proc self ["sleep"]) { std_out = s, close_fds = cf }
    return ph

  close conn
  result <- timeout 3000000 (recv client 1)
  putStrLn $ label ++ ": " ++ case result of
    Just bs | BS.null bs -> "peer saw the close"
    Just _ -> "peer got data?"
    Nothing -> "peer did NOT see the close within 3s (connection still open)"
  mapM_ terminateProcess child
  close client
  close listener

foreign import ccall unsafe "windows.h GetHandleInformation"
  c_GetHandleInformation :: Ptr () -> Ptr Word32 -> IO Bool

main :: IO ()
main = getArgs >>= \case
  ["sleep"] -> threadDelay 20000000
  _ -> do
    hSetBuffering stdout LineBuffering
    run "no child" Nothing
    run "child with close_fds = True, std_out = Inherit" (Just (Inherit, True))
    run "child with close_fds = True, std_out = CreatePipe" (Just (CreatePipe, True))
    run "child with close_fds = False, std_out = Inherit" (Just (Inherit, False))
