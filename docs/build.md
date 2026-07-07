# Building

## Dependencies

**Build tools:**
- [Odin compiler](https://odin-lang.org/) (latest dev build recommended)
- LLVM 15+ (required by `core:nbio` for atomic pointer operations — Ubuntu 24.04+ or install via [apt.llvm.org](https://apt.llvm.org))
- C/C++ compiler — Homebrew LLVM recommended on macOS (`brew install llvm`); Apple clang on macOS 26+ forces a deployment target mismatch that causes linker warnings
- `make`
- `autoconf`, `automake`, `libtool` (for building libsecp256k1)
- **ncurses** (for the `--tui` terminal dashboard) — ships with macOS; on Linux install the dev package for the linker symlink: `apt install libncurses-dev` / `dnf install ncurses-devel`
- **GUI (`--gui` / `btcnode-gui`)** — raylib ships inside the Odin toolchain (`vendor:raylib`), nothing to install on macOS; on Linux the prebuilt raylib links against system X11/GL: `apt install libgl1-mesa-dev libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev`. Headless builds/servers can skip this: the node runs fully without either dashboard, and `--tui` needs only ncurses

**C/C++ libraries (built automatically):**
- [libsecp256k1](https://github.com/bitcoin-core/secp256k1) v0.7.1 — git submodule, built with schnorrsig + recovery + extrakeys + ellswift modules
- [LevelDB](https://github.com/google/leveldb) 1.23 — git submodule, compiled as static library with C++17
- RIPEMD-160 — vendored C implementation in `deps/ripemd160/`
- SHA-256 — vendored from [Bitcoin Core](https://github.com/bitcoin/bitcoin) (`deps/sha256/`), multi-backend with runtime CPU detection: SHA-NI, AVX2 8-way, SSE4.1 4-way, ARMv8 crypto, generic scalar

## Compiling

```bash
# Clone with submodules
git clone --recursive https://github.com/youruser/bitcoin-node-odin.git
cd bitcoin-node-odin

# If you already cloned without --recursive:
git submodule update --init --recursive

# Build everything (deps + binary)
make

# Or step by step:
make deps    # Build C/C++ libraries
make build   # Build the node binary
make debug   # Build with debug symbols
make gui     # Build the standalone dashboard client (btcnode-gui)
```

The binary is output as `btcnode` in the project root.


## Testing

```bash
make test         # all 328 tests across 10 packages
```

| Package | Tests | | Package | Tests |
|---|---|---|---|---|
| crypto | 40 | | chain | 29 |
| wire | 44 | | p2p | 34 |
| script | 54 | | mempool | 32 |
| consensus | 23 | | rpc | 53 |
| storage | 18 | | zmq | 1 |

Script tests have a known flaky secp256k1 thread-safety issue under parallel
test threads — use `odin test script -define:ODIN_TEST_THREADS=1` if they crash.
