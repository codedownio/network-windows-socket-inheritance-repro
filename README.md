# Windows: accepted sockets are inheritable, so a child process keeps a closed connection open

## The problem

On Windows, a child process inherits every socket its parent has open: with `close_fds = False`, and also with `close_fds = True` as soon as any standard stream is redirected. The connection then stays open as long as the child's copy does, so when the parent closes it, the other side never sees the close. If the client sends a new request on the connection, the request hangs forever.

## Running it

On Windows, with GHC 9.14.2 (network master needs it, or 9.12.5, on Windows) and cabal:

```
cabal run --project-file=cabal.project.original repro    # haskell/network master
cabal run --project-file=cabal.project.fixed repro       # master plus the fix
```

`cabal.project.original-process382` and `cabal.project.fixed-process382` are the same with process from haskell/process#382. Running network's `configure` needs an `sh`, which ghcup's msys2 or Git for Windows (`C:\Program Files\Git\usr\bin` on the `PATH`) provides. The same program runs on Linux, for comparison.

Each case opens two connections, spawns a child, then closes the accepted end of one connection and the outgoing end of the other, and checks whether the other end sees each close:

| Child created with | Linux | Windows, master | Windows, master + fix | Windows, master + #382 | Windows, master + fix + #382 |
|---|---|---|---|---|---|
| `close_fds = True`, stdout inherited | ✓ ✓ | ✓ ✓ | ✓ ✓ | ✓ ✓ | ✓ ✓ |
| `close_fds = True`, stdout piped | ✓ ✓ | ✗ ✗ | ✓ ✗ | ✓ ✓ | ✓ ✓ |
| `close_fds = False` | ✓ ✗ | ✗ ✗ | ✓ ✗ | ✗ ✗ | ✓ ✗ |

Each cell is "closing an accepted connection, closing an outgoing connection": ✓ the other end saw the close, ✗ it didn't within 3s. With no child, every column sees both. Windows 11 with GHC 9.14.2-rc3, Linux with GHC 9.12.3, network master `31c3d2c`.

<details>
<summary>Output on Windows, master</summary>

```
no child:
  listener inheritable, outgoing inheritable, accepted inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end saw it
child with close_fds = True, std_out = Inherit:
  listener inheritable, outgoing inheritable, accepted inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end saw it
child with close_fds = True, std_out = CreatePipe:
  listener inheritable, outgoing inheritable, accepted inheritable
  closing an accepted connection: the other end did NOT see it within 3s
  closing an outgoing connection: the other end did NOT see it within 3s
child with close_fds = False, std_out = Inherit:
  listener inheritable, outgoing inheritable, accepted inheritable
  closing an accepted connection: the other end did NOT see it within 3s
  closing an outgoing connection: the other end did NOT see it within 3s
```

</details>

<details>
<summary>Output on Windows, master + fix + #382</summary>

```
no child:
  listener inheritable, outgoing inheritable, accepted not inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end saw it
child with close_fds = True, std_out = Inherit:
  listener inheritable, outgoing inheritable, accepted not inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end saw it
child with close_fds = True, std_out = CreatePipe:
  listener inheritable, outgoing inheritable, accepted not inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end saw it
child with close_fds = False, std_out = Inherit:
  listener inheritable, outgoing inheritable, accepted not inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end did NOT see it within 3s
```

</details>

<details>
<summary>Output on Linux</summary>

```
no child:
  listener inheritable, outgoing inheritable, accepted not inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end saw it
child with close_fds = True, std_out = Inherit:
  listener inheritable, outgoing inheritable, accepted not inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end saw it
child with close_fds = True, std_out = CreatePipe:
  listener inheritable, outgoing inheritable, accepted not inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end saw it
child with close_fds = False, std_out = Inherit:
  listener inheritable, outgoing inheritable, accepted not inheritable
  closing an accepted connection: the other end saw it
  closing an outgoing connection: the other end did NOT see it within 3s
```

</details>

## Analysis

Two things differ from Unix:

- **Which sockets are inheritable.** On Unix, `accept` returns a close-on-exec descriptor (`accept4` with `SOCK_CLOEXEC`), and `socket` doesn't set close-on-exec. On Windows, both return inheritable handles.
- **What `close_fds = True` does.** On Unix it closes every descriptor above 2 in the child. On Windows, `createProcess` passes `bInheritHandles = TRUE` whenever a standard stream is redirected, so the child gets every inheritable handle anyway (haskell/process#235).

## The fix

[codedownio/network `windows-non-inheritable-accept`](https://github.com/codedownio/network/tree/windows-non-inheritable-accept) clears `HANDLE_FLAG_INHERIT` on accepted sockets, the counterpart of `SOCK_CLOEXEC` on `accept`. [haskell/process#382](https://github.com/haskell/process/pull/382) fixes the other half: with `close_fds = True`, a child gets only its standard handles. With both, Windows behaves as Linux does in every case above, including the one case where Linux itself leaks: an outgoing connection, inherited by a child created with `close_fds = False`.

## Extra information

The project files build network and process from commits with their generated `configure` committed, so no autoconf is needed: network branches `repro-master-configure` and `repro-accept-configure`, process branch `repro-382-with-configure` on [codedownio/process](https://github.com/codedownio/process). On Windows the repro runs under the WinIO I/O manager, which network master requires.

We hit this with a warp server spawning long-lived `wsl.exe` children with `close_fds = True` and redirected output.
