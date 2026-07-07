# bitcoin-node-odin

A Bitcoin full node written from scratch in [Odin](https://odin-lang.org/) —
consensus validation, P2P networking, mempool, storage, RPC, and dashboards,
with only C dependencies Bitcoin Core itself uses (libsecp256k1, LevelDB).

**Fully synced and verified on mainnet** — tip hash and UTXO totals
cross-checked against the public network — plus signet, testnet4, and
testnet3. 364 tests across 12 packages.

## Highlights

- **Full consensus validation** — script interpreter (P2PKH through Taproot),
  all deployed soft forks, parallel script verification, assumevalid
- **Headers-first IBD** with multi-peer download, compact blocks (BIP152),
  and encrypted v2 transport (BIP324) with automatic v1 fallback both ways
- **Bitcoin Core-compatible surface** — 69 of Core's 78 non-wallet RPCs,
  cookie auth, `bitcoin.conf`-style config, Core CLI flag names,
  [electrs](https://github.com/romanz/electrs) runs against it unmodified
- **ZMQ notifications** — Core's `zmqpub*` interface via a native ZMTP 3.0
  implementation (no libzmq), LND-ready
- **Crash-safe by construction** — chunked atomic flushes, undo-based
  recovery with live progress, bounded rollback depth, single-instance lock
- **Pruning** (`--prune`), background UTXO flushes, sync ETA
- **Tor-ready** — `--proxy` routes all outbound P2P through SOCKS5 with
  proxy-side name resolution (no DNS leaks); `.onion` peers via `--connect`
- **Drivechain (BIP300/301)** — opt-in `--drivechain=track|enforce`: sidechain
  proposal/withdrawal tracking, escrow (CTIP) validation, blind merged mining
- **Dashboards** — instant-start GUI window (raylib), SSH-friendly TUI
  (ncurses), and a standalone remote client (`btcnode-gui`)
- **First-run setup wizard** (`--wizard`) — a `menuconfig`-style ncurses flow
  that writes your `btcnode.conf` and prints the exact command to start
- **Runs headless or as a daemon** (`--daemon`) — forks, detaches, and logs to
  `<datadir>/debug.log`, like `bitcoind -daemon`

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

### First-run setup wizard

Not sure what to configure? Run the wizard — a `menuconfig`-style ncurses flow
that asks the handful of decisions that actually vary per user (network, data
directory, full vs pruned, cache size, RPC auth, dashboard, plus an Advanced
toggles screen), then creates the data directory, writes a `btcnode.conf`, and
prints the exact command to start:

```bash
./btcnode --wizard
```

It writes the config and exits without touching the network — everything it
doesn't ask keeps its default and can be edited in the conf afterward.

### Configuration file

Instead of passing everything on the command line, drop a `btcnode.conf` in
your data directory — the node reads `<datadir>/btcnode.conf` at startup. The
format is INI-style, mirroring Bitcoin Core's `bitcoin.conf` (`#` comments,
`key=value`, optional `[network]` sections). CLI flags override the file.

```bash
# ~/btcnode/btcnode.conf
network=mainnet
dbcache=1024
prune=2000
rpcuser=alice
rpcpassword=hunter2
```

```bash
./btcnode --datadir=~/btcnode --gui        # everything else comes from the conf
```

A fully-commented [`contrib/btcnode.conf.sample`](contrib/btcnode.conf.sample)
lists every supported key with its default. Copy it and uncomment what you
need:

```bash
cp contrib/btcnode.conf.sample ~/btcnode/btcnode.conf
```

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
