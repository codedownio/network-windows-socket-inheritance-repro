# Build with ghcup's GHC 9.12.4, using a cabal dir of our own so a global config's extra
# include/lib dirs (such as an msys2 install) don't leak in. network's configure script needs
# Git for Windows' sh on the PATH.
#   .\build.ps1 <name>     (builds into dist-<name> and prints the executable's path)
$env:CABAL_DIR = Join-Path $PSScriptRoot ".cabal"
$env:PATH = "C:\Program Files\Git\bin;" + $env:PATH
$cabal = "C:\ghcup\bin\cabal.exe"
$ghc = "C:\ghcup\bin\ghc-9.12.4.exe"
if (-not (Test-Path (Join-Path $env:CABAL_DIR "packages"))) { & $cabal update | Out-Null }
& $cabal build -w $ghc --builddir "dist-$($args[0])" | Out-Host
& $cabal list-bin -w $ghc --builddir "dist-$($args[0])" repro
