# Windows: sockets are inheritable, so a child process keeps a closed connection open

## The problem

On Windows, a child process inherits every socket its parent has open: with `close_fds = False`, and also with `close_fds = True` as soon as any standard stream is redirected. The connection then stays open as long as the child's copy does, so when the parent closes it, the other side never sees the close. A client holding it as a keep-alive connection doesn't know it's dead: it sends its next request on it, nothing ever reads it, and the request hangs forever.

## Running it

On Windows, with GHC and cabal (e.g. from [ghcup](https://www.haskell.org/ghcup/)):

```
cabal run --project-file=cabal.project.original repro    # haskell/network master
cabal run --project-file=cabal.project.fixed repro       # master plus the fix
```

Running network's `configure` needs an `sh`, which ghcup's msys2 or Git for Windows (`C:\Program Files\Git\usr\bin` on the `PATH`) provides.

<details>
<summary>Results on Windows 11, GHC 9.12.4</summary>

```
original:
  listener handle flags: 1      (HANDLE_FLAG_INHERIT set; the same before every case)
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

</details>

For comparison, `cabal run unix-check` in `unix/` on Linux reports which sockets a child holds.

<details>
<summary>Results on Linux, GHC 9.14.1 and 9.12.3, network master and Hackage</summary>

```
close_fds=False listener (socket): inherited by the child
close_fds=False client (socket): inherited by the child
close_fds=False conn (accept): not inherited
close_fds=True listener (socket): not inherited
close_fds=True client (socket): not inherited
close_fds=True conn (accept): not inherited
```

</details>

## Analysis

Which sockets a child gets:

| Child created with | Unix, network master | Windows, network master | Windows, with the fix |
|---|---|---|---|
| `close_fds = False` (the default for `proc`) | sockets from `socket`, not from `accept` | every socket | none |
| `close_fds = True`, no standard stream redirected | none | none | none |
| `close_fds = True`, a standard stream redirected | none | every socket | none |

On Unix, `accept` returns a close-on-exec descriptor (`accept4` with `SOCK_CLOEXEC`), so an accepted connection is never inherited. `socket` doesn't set close-on-exec, so a listener or an outgoing connection is inherited unless `close_fds = True`.

On Windows, `socket` and `accept` both return inheritable handles, and `createProcess` passes `bInheritHandles = TRUE` unless `close_fds = True` and all three standard streams are `Inherit` (haskell/process#235).

## The fix

[codedownio/network `windows-non-inheritable-sockets`](https://github.com/codedownio/network/tree/windows-non-inheritable-sockets) clears `HANDLE_FLAG_INHERIT` right after `socket` and `accept` on Windows, the counterpart of `FD_CLOEXEC`. For accepted connections, Windows then behaves as Unix does. For sockets from `socket` it's stricter than Unix: with `close_fds = False` a Unix child still inherits them, a Windows child doesn't.

## Extra information

`Main.hs` makes a listener, connects a client to it, accepts the connection, spawns a child that sleeps, closes the accepted socket, and waits 3 seconds for the client to see EOF, with no child and with each `createProcess` setting above. `original` is [haskell/network master `2071e8e`](https://github.com/haskell/network/commit/2071e8ea82b48a1c5e2404391a27d551c8197a9d) (branch `repro-original`), `fixed` the fix on it (branch `repro-fixed`); both have their generated `configure` committed, so no autoconf is needed. `+RTS --io-manager=native` gives the same results.

We hit this with a warp server spawning long-lived `wsl.exe` children with redirected output.
