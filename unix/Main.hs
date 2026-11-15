import Control.Monad
import Network.Socket
import System.Directory
import System.Posix.Files
import System.Process
import Control.Concurrent

-- Which socket a descriptor refers to, as /proc shows it (socket:[inode])
inodeOf :: Socket -> IO String
inodeOf s = do
  fd <- unsafeFdSocket s
  readSymbolicLink ("/proc/self/fd/" ++ show fd)

main :: IO ()
main = forM_ [False, True] $ \cf -> do
  listener <- socket AF_INET Stream defaultProtocol
  bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
  listen listener 1
  port <- socketPort listener
  client <- socket AF_INET Stream defaultProtocol
  connect client (SockAddrInet port (tupleToHostAddress (127, 0, 0, 1)))
  (conn, _) <- accept listener
  (_, _, _, ph) <- createProcess (proc "sleep" ["5"]) { std_out = CreatePipe, close_fds = cf }
  Just pid <- getPid ph
  threadDelay 300000
  fds <- listDirectory ("/proc/" ++ show pid ++ "/fd")
  held <- forM fds $ \f -> readSymbolicLink ("/proc/" ++ show pid ++ "/fd/" ++ f)
  forM_ [("listener (socket)", listener), ("client (socket)", client), ("conn (accept)", conn)] $ \(n, s) -> do
    ino <- inodeOf s
    putStrLn $ "close_fds=" ++ show cf ++ " " ++ n ++ ": " ++ (if ino `elem` held then "inherited by the child" else "not inherited")
  terminateProcess ph
  mapM_ close [conn, client, listener]
