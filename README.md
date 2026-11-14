# Windows: sockets are inheritable, so a child process keeps a closed connection open

`socket` and `accept` create inheritable handles on Windows (there is no equivalent of the
`SOCK_CLOEXEC`/`FD_CLOEXEC` handling network does elsewhere). `createProcess` passes
`bInheritHandles=TRUE` whenever a standard stream is redirected, even with `close_fds = True`
(see haskell/process#235), so every socket open at that moment is inherited by the child.
Closing the socket in the parent then doesn't close the connection: the peer never sees EOF
until the child exits.

`Main.hs` accepts a connection, spawns a child that sleeps, closes the accepted socket, and
checks whether the client sees the close.

## Building

`network` is built from git, which needs its `configure` script generated with autoconf. Do that
from Linux or WSL, then build on Windows with ghcup's GHC 9.12.4 (Git for Windows provides the
`sh` that runs `configure`):

```
./get-network.sh https://github.com/haskell/network master    # Linux/WSL
.\build.ps1 master                                             # Windows; prints the exe path
```

`build.ps1` uses a cabal dir of its own, so extra include/lib dirs from a global cabal config
(an msys2 install, say) don't leak into the build.

## Results (Windows 11, GHC 9.12.4)

haskell/network master (`2071e8e`, 3.3.0.0), under both `--io-manager=posix` and `native`:

```
  listener handle flags: 1
  client handle flags: 1
  conn handle flags: 1
no child: peer saw the close
child with std_out = Inherit: peer saw the close
child with std_out = CreatePipe: peer did NOT see the close within 3s (connection still open)
```

With the fix (`./get-network.sh https://github.com/codedownio/network windows-non-inheritable-sockets`,
which clears `HANDLE_FLAG_INHERIT` after `socket` and `accept`), all three handles report flags 0
and every case sees the close, under both I/O managers.

## How we hit it

A warp server spawning long-lived `wsl.exe` children. Every keep-alive connection open at spawn
time was inherited; when warp closed an idle one, the client reused it and its next request hung
forever.
