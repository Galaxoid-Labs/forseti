# bitcoin-node-odin

A Bitcoin full node written from scratch in [Odin](https://odin-lang.org/) —
consensus validation, P2P networking, mempool, storage, RPC, and dashboards,
with only C dependencies Bitcoin Core itself uses (libsecp256k1, LevelDB).

**Fully synced and verified on mainnet** — tip hash and UTXO totals
cross-checked against the public network — plus signet, testnet4, and
testnet3. 342 tests across 11 packages.

## Highlights

- **Full consensus validation** — script interpreter (P2PKH through Taproot),
  all deployed soft forks, parallel script verification, assumevalid
- **Headers-first IBD** with multi-peer download, compact blocks (BIP152),
  and encrypted v2 transport (BIP324) with automatic v1 fallback both ways
- **Bitcoin Core-compatible surface** — 64 of Core's 78 non-wallet RPCs,
  cookie auth, `bitcoin.conf`-style config, Core CLI flag names,
  [electrs](https://github.com/romanz/electrs) runs against it unmodified
- **ZMQ notifications** — Core's `zmqpub*` interface via a native ZMTP 3.0
  implementation (no libzmq), LND-ready
- **Crash-safe by construction** — chunked atomic flushes, undo-based
  recovery with live progress, bounded rollback depth, single-instance lock
- **Pruning** (`--prune`), background UTXO flushes, sync ETA
- **Drivechain (BIP300/301)** — opt-in `--drivechain=track|enforce`: sidechain
  proposal/withdrawal tracking, escrow (CTIP) validation, blind merged mining
- **Dashboards** — instant-start GUI window (raylib), SSH-friendly TUI
  (ncurses), and a standalone remote client (`btcnode-gui`)

## Quick Start

Prebuilt binaries (macOS arm64, Linux x64/arm64) are on the
[releases page](../../releases). Or build from source:

```bash
git clone --recursive https://github.com/youruser/bitcoin-node-odin.git
cd bitcoin-node-odin && make

./btcnode --network=signet --datadir=~/btcnode-signet --gui   # small network, syncs fast
./btcnode --network=mainnet --datadir=~/btcnode --dbcache=4096 --prune=2000 --gui
```

Requires the Odin compiler, LLVM 15+, and `make` — full details in
[docs/build.md](docs/build.md).

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/build.md](docs/build.md) | Dependencies, compiling, running the tests |
| [docs/usage.md](docs/usage.md) | Syncing each network, monitoring, every CLI flag, config file, ports |
| [docs/rpc.md](docs/rpc.md) | RPC usage and the full Bitcoin Core coverage matrix |
| [docs/integrations.md](docs/integrations.md) | Electrum wallets via electrs (BDK/Sparrow), ZMQ notifications |
| [docs/dashboards.md](docs/dashboards.md) | GUI window, terminal TUI, remote client |
| [docs/architecture.md](docs/architecture.md) | Project layout, storage design, threading, sync internals |
| [docs/bips.md](docs/bips.md) | All 36 implemented BIPs |
| [docs/hardware.md](docs/hardware.md) | What to run it on (SHA-256 backends, IBD times) |
| [docs/history.md](docs/history.md) | The 50 build phases and what's left |

## License

MIT
