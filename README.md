# Windows: sockets are inheritable, so a child process keeps a closed connection open

## Running it

On Windows, with GHC and cabal (e.g. from [ghcup](https://www.haskell.org/ghcup/)):

```
cabal run --project-file=cabal.project.original repro    # haskell/network master
cabal run --project-file=cabal.project.fixed repro       # master plus the fix
```

Each project file builds network from a commit on [codedownio/network](https://github.com/codedownio/network) that has its generated `configure` script committed, so no autoconf is needed. Running `configure` still needs an `sh`, which ghcup's msys2 or Git for Windows (`C:\Program Files\Git\usr\bin` on the `PATH`) provides. Add `-- +RTS --io-manager=native` to use the WinIO I/O manager; the results are the same.

Results on Windows 11 with GHC 9.12.4 (the handle flags lines, printed before each case, are the same every time and shown once):

```
original:
  listener handle flags: 1      (HANDLE_FLAG_INHERIT set)
  client handle flags: 1
  conn handle flags: 1
no child: peer saw the close
child with close_fds = True, std_out = Inherit: peer saw the close
child with close_fds = True, std_out = CreatePipe: peer did NOT see the close within 3s (connection still open)
child with close_fds = False, std_out = Inherit: peer did NOT see the close within 3s (connection still open)

fixed:
  listener handle flags: 0
  client handle flags: 0
  conn handle flags: 0
no child: peer saw the close
child with close_fds = True, std_out = Inherit: peer saw the close
child with close_fds = True, std_out = CreatePipe: peer saw the close
child with close_fds = False, std_out = Inherit: peer saw the close
```

**The Unix side.** In `unix/`, on Linux, `cabal run unix-check` makes the same three sockets, spawns a child with `close_fds = False` and then `True`, and reports which of the sockets the child holds (from `/proc/<pid>/fd`):

```
close_fds=False listener (socket): inherited by the child
close_fds=False client (socket): inherited by the child
close_fds=False conn (accept): not inherited
close_fds=True listener (socket): not inherited
close_fds=True client (socket): not inherited
close_fds=True conn (accept): not inherited
```

The same on network master (`2071e8e`) and on network from Hackage, with GHC 9.14.1 and 9.12.3.

## The problem

Unix and Windows differ in which of a process's sockets a child process gets:

| Child created with | Unix, network master | Windows, network master | Windows, with the fix |
|---|---|---|---|
| `close_fds = False` (the default for `proc`) | sockets from `socket`; not those from `accept` | every socket | none |
| `close_fds = True`, no standard stream redirected | none | none | none |
| `close_fds = True`, a standard stream redirected (`CreatePipe`, `UseHandle`, ...) | none | every socket | none |

On Unix, `accept` returns a close-on-exec descriptor (`accept4` with `SOCK_CLOEXEC`, or `FD_CLOEXEC` set right after), so an accepted connection is never inherited. `socket` makes the descriptor non-blocking but not close-on-exec, so a listener or an outgoing connection is inherited unless `close_fds = True`, which closes every descriptor above 2 in the child.

On Windows, `socket` and `accept` both return inheritable handles. `createProcess` passes `bInheritHandles = TRUE` to `CreateProcess` unless `close_fds = True` *and* all three standard streams are `Inherit`, so a child with any redirected stream gets every inheritable handle in the process, including every socket, even with `close_fds = True` (haskell/process#235).

As on Unix, a connection only closes when every handle to it is closed. When the child holds a copy, closing the socket in the parent doesn't close the connection, and the peer sees no EOF until the child exits. On Unix that can't happen to an accepted connection; on Windows it happens to any connection open when a child is spawned with a redirected stream, or with `close_fds = False`.

## The fix

[codedownio/network `windows-non-inheritable-sockets`](https://github.com/codedownio/network/tree/windows-non-inheritable-sockets) clears `HANDLE_FLAG_INHERIT` on the handle right after `socket` and `accept` on Windows, the Windows counterpart of `FD_CLOEXEC`. No child inherits a socket then, whatever `createProcess` is given:

- For accepted connections, Windows then behaves as Unix already does.
- For sockets from `socket`, Windows becomes stricter than Unix: with `close_fds = False`, a Unix child still inherits a listener or an outgoing connection; a Windows child doesn't.

## Extra information

`Main.hs` makes a listener, connects a client to it, accepts the connection, spawns a child that sleeps for 20 seconds, closes the accepted socket, and waits up to 3 seconds for the client to see EOF. It runs that with no child and with each of the three `createProcess` settings above.

- `original`: [haskell/network master `2071e8e`](https://github.com/haskell/network/commit/2071e8ea82b48a1c5e2404391a27d551c8197a9d) (branch `repro-original`)
- `fixed`: the fix on the same master (branch `repro-fixed`)

How we hit it: a warp server spawning long-lived `wsl.exe` children with redirected output. Every keep-alive connection open at spawn time was inherited; when warp closed an idle one, the client reused it and its next request hung forever.
