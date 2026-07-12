# Building

Prebuilt binaries for macOS arm64 and Linux x64/arm64 are attached to
[GitHub Releases](../../../releases) — built by `.github/workflows/release.yml`
(`-o:speed`, full test suite as a gate, SHA256SUMS included). Tagging `v*`
publishes a release; the workflow can also be dispatched manually as a dry run.

## Dependencies

**Build tools:**
- [Odin compiler](https://odin-lang.org/) (latest dev build recommended)
- LLVM 15+ (required by `core:nbio` for atomic pointer operations — Ubuntu 24.04+ or install via [apt.llvm.org](https://apt.llvm.org))
- C/C++ compiler — Homebrew LLVM recommended on macOS (`brew install llvm`); Apple clang on macOS 26+ forces a deployment target mismatch that causes linker warnings
- `make`
- `autoconf`, `automake`, `libtool` (for building libsecp256k1)
- `cmake` (for building RocksDB — the `--index-addresses` engine): `apt install cmake` / `dnf install cmake` / `brew install cmake`
- **zstd** dev headers + lib (RocksDB's compression backend): `apt install libzstd-dev` / `dnf install libzstd-devel` / `brew install zstd`
- **ncurses** (for the `--tui` terminal dashboard) — ships with macOS; on Linux install the dev package for the linker symlink: `apt install libncurses-dev` / `dnf install ncurses-devel`
- **GUI (`--gui` / `forseti-gui`)** — raylib ships inside the Odin toolchain (`vendor:raylib`), nothing to install on macOS; on Linux the prebuilt raylib links against system X11/GL: `apt install libgl1-mesa-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev`. Headless builds/servers can skip this: the node runs fully without either dashboard, and `--tui` needs only ncurses. **Linux arm64:** Odin's vendored Linux raylib libs are x64-only — build raylib 5.5 + raygui 4.0 from source and replace `$(odin root)/vendor/raylib/linux/lib{raylib,raygui}.a` (see the "Build arm64 raylib/raygui vendor libs" step in `.github/workflows/release.yml` for the exact recipe)

**C/C++ libraries (built automatically):**
- [libsecp256k1](https://github.com/bitcoin-core/secp256k1) v0.7.1 — git submodule, built with schnorrsig + recovery + extrakeys + ellswift modules
- [LevelDB](https://github.com/google/leveldb) 1.23 — git submodule, compiled as static library with C++17 (chainstate, block index, txindex, filter index)
- [RocksDB](https://github.com/facebook/rocksdb) v9.9.3 — the engine for the optional `--index-addresses` scripthash index only; cloned + built static (PORTABLE, Zstd-only) by `deps/build.sh` on first run. Needs `cmake` + zstd (above). Slow to compile (~minutes); skipped once `deps/lib/librocksdb.a` exists
- RIPEMD-160 — vendored C implementation in `deps/ripemd160/`
- SHA-256 — vendored from [Bitcoin Core](https://github.com/bitcoin/bitcoin) (`deps/sha256/`), multi-backend with runtime CPU detection: SHA-NI, AVX2 8-way, SSE4.1 4-way, ARMv8 crypto, generic scalar

## Compiling

```bash
# Clone with submodules
git clone --recursive https://github.com/Galaxoid-Labs/forseti.git
cd forseti

# If you already cloned without --recursive:
git submodule update --init --recursive

# Build everything (deps + binary)
make

# Or step by step:
make deps    # Build C/C++ libraries
make build   # Build the node binary
make debug   # Build with debug symbols
make gui     # Build the standalone dashboard client (forseti-gui)
```

The binary is output as `forseti` in the project root.


## Testing

```bash
make test         # all 378 tests across 13 packages
```

| Package | Tests | | Package | Tests |
|---|---|---|---|---|
| crypto | 41 | | mempool | 36 |
| wire | 45 | | rpc | 59 |
| script | 54 | | zmq | 1 |
| consensus | 23 | | drivechain | 11 |
| storage | 19 | | descriptor | 5 |
| chain | 35 | | | |
| p2p | 36 | | | |

Script tests have a known flaky secp256k1 thread-safety issue under parallel
test threads — use `odin test script -define:ODIN_TEST_THREADS=1` if they crash.
