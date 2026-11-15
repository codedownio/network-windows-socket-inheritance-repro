{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}

import Control.Concurrent
import Control.Exception (IOException, try)
import Foreign
import Control.Monad
import Data.List (intercalate)
import qualified Data.ByteString as BS
import Network.Socket
import Network.Socket.ByteString (recv)
import System.Environment
import System.IO
import System.Process
import System.Timeout
#if !defined(mingw32_HOST_OS)
import System.Posix.IO (FdOption (..), queryFdOption)
import System.Posix.Types (Fd (..))
#endif

-- Open two connections, spawn a child that outlives them, then close the accepted end of one and
-- the outgoing end of the other, and see whether the far end of each gets EOF
run :: String -> Maybe (StdStream, Bool) -> IO ()
run label childOpts = do
  listener <- socket AF_INET Stream defaultProtocol
  bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  listen listener 2
  port <- socketPort listener
  let open = do
        client <- socket AF_INET Stream defaultProtocol
        connect client (SockAddrInet port (tupleToHostAddress (127, 0, 0, 1)))
        (conn, _) <- accept listener
        return (client, conn)
  (client1, conn1) <- open
  (client2, conn2) <- open
  flags <- forM [("listener", listener), ("outgoing", client1), ("accepted", conn1)] $ \(n, sk) -> do
    inheritable <- isInheritable sk
    return (n ++ (if inheritable then " inheritable" else " not inheritable"))

  self <- getExecutablePath
  child <- forM childOpts $ \(s, cf) -> do
    (_, _, _, ph) <- createProcess (proc self ["sleep"]) { std_out = s, close_fds = cf }
    return ph

  close conn1
  close client2
  accepted <- sawClose client1
  outgoing <- sawClose conn2
  putStrLn $ label ++ ":"
  putStrLn $ "  " ++ intercalate ", " flags
  putStrLn $ "  closing an accepted connection: " ++ accepted
  putStrLn $ "  closing an outgoing connection: " ++ outgoing
  mapM_ terminateProcess child
  mapM_ close [client1, conn2, listener]
  where
    -- Waits on the result rather than cancelling the recv, which on Windows fails it with EINVAL
    sawClose peer = do
      result <- newEmptyMVar
      _ <- forkIO $ try (recv peer 1) >>= putMVar result
      timeout 3000000 (takeMVar result) >>= \case
        Just (Left e) -> return ("recv failed: " ++ show (e :: IOException))
        Just (Right bs) -> return (if BS.null bs then "the other end saw it" else "the other end got data?")
        Nothing -> return "the other end did NOT see it within 3s"

isInheritable :: Socket -> IO Bool
#if defined(mingw32_HOST_OS)
isInheritable sk = do
  fd <- unsafeFdSocket sk
  flags <- alloca $ \p -> c_GetHandleInformation (wordPtrToPtr (fromIntegral fd)) p >> peek p
  return (flags .&. 1 /= 0)

foreign import ccall unsafe "windows.h GetHandleInformation"
  c_GetHandleInformation :: Ptr () -> Ptr Word32 -> IO Bool
#else
isInheritable sk = do
  fd <- unsafeFdSocket sk
  not <$> queryFdOption (Fd fd) CloseOnExec
#endif

main :: IO ()
main = getArgs >>= \case
  ["sleep"] -> threadDelay 20000000
  _ -> do
    hSetBuffering stdout LineBuffering
    run "no child" Nothing
    run "child with close_fds = True, std_out = Inherit" (Just (Inherit, True))
    run "child with close_fds = True, std_out = CreatePipe" (Just (CreatePipe, True))
    run "child with close_fds = False, std_out = Inherit" (Just (Inherit, False))
