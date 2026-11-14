# Windows: sockets are inheritable, so a child process keeps a closed connection open

## Running it

On Windows, with GHC and cabal (e.g. from [ghcup](https://www.haskell.org/ghcup/)):

```
cabal run --project-file=cabal.project.original repro    # haskell/network master
cabal run --project-file=cabal.project.fixed repro       # master plus the fix
```

Add `-- +RTS --io-manager=native` to either to use the WinIO I/O manager; the results are the same.

Each project file builds network from a commit on [codedownio/network](https://github.com/codedownio/network) that has its generated `configure` script committed, so no autoconf is needed. Running `configure` still needs an `sh`, which ghcup's msys2 or Git for Windows (`C:\Program Files\Git\bin` on the `PATH`) provides.

- `original`: [haskell/network master `2071e8e`](https://github.com/haskell/network/commit/2071e8ea82b48a1c5e2404391a27d551c8197a9d) (branch `repro-original`)
- `fixed`: the fix, [`windows-non-inheritable-sockets`](https://github.com/codedownio/network/tree/windows-non-inheritable-sockets), on the same master (branch `repro-fixed`)

## Results (Windows 11, GHC 9.12.4)

`original`:

```
  listener handle flags: 1
  client handle flags: 1
  conn handle flags: 1
no child: peer saw the close
child with std_out = Inherit: peer saw the close
child with std_out = CreatePipe: peer did NOT see the close within 3s (connection still open)
```

`fixed`: every handle reports flags 0, and the peer sees the close in all three cases.

## What it shows

`socket` and `accept` create inheritable handles on Windows (there is no equivalent of the `SOCK_CLOEXEC`/`FD_CLOEXEC` handling network does elsewhere). `createProcess` passes `bInheritHandles=TRUE` whenever a standard stream is redirected, even with `close_fds = True` (see haskell/process#235), so every socket open at that moment is inherited by the child. Closing the socket in the parent then doesn't close the connection: the peer never sees EOF until the child exits.

`Main.hs` accepts a connection, spawns a child that sleeps, closes the accepted socket, and checks whether the client sees the close. The fix clears `HANDLE_FLAG_INHERIT` right after `socket` and `accept`.

How we hit it: a warp server spawning long-lived `wsl.exe` children. Every keep-alive connection open at spawn time was inherited; when warp closed an idle one, the client reused it and its next request hung forever.
