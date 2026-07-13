<p align="center">
  <img src="assets/forseti_icon.png" width="128" alt="forseti">
</p>

# forseti

A Bitcoin full node written from scratch in [Odin](https://odin-lang.org/) —
consensus validation, P2P networking, mempool, storage, RPC, and dashboards,
with only C dependencies Bitcoin Core itself uses (libsecp256k1, LevelDB),
plus RocksDB for the optional in-node address index.

**Fully synced and verified on mainnet** — tip hash and UTXO totals
cross-checked against the public network — plus signet, testnet4, and
testnet3. 378 tests across 13 packages.

## Highlights

- **Full consensus validation** — script interpreter (P2PKH through Taproot),
  all deployed soft forks, parallel script verification, parallel prevout
  prefetch (warms the UTXO cache from LevelDB across worker threads for faster
  cold-cache IBD), assumevalid
- **Headers-first IBD** with multi-peer download, compact blocks (BIP152),
  and encrypted v2 transport (BIP324) with automatic v1 fallback both ways
- **Bitcoin Core-compatible surface** — 87 of Core v30's 94 non-wallet RPCs
  (incl. the BIP174 PSBT family), cookie auth, `bitcoin.conf`-style config,
  Core CLI flag names, [electrs](https://github.com/romanz/electrs) runs against it unmodified
- **Built-in wallet backend** — an [Esplora-compatible REST API](docs/integrations.md#built-in-esplora-rest-api-recommended-no-sidecar)
  (`--esplora`) served by the node itself, backed by a scripthash address index
  built *during* sync (`--index-addresses`) — no electrs/Esplora sidecar, no
  second copy of the chain. Point [BDK](https://docs.rs/bdk_esplora)/`esplora-client`
  wallets straight at it; response JSON is verified byte-identical to Blockstream's Esplora
- **ZMQ notifications** — Core's `zmqpub*` interface via a native ZMTP 3.0
  implementation (no libzmq), LND-ready
- **Crash-safe by construction** — chunked atomic flushes, undo-based
  recovery with live progress, bounded rollback depth, single-instance lock
- **Pruning** (`--prune`), background UTXO flushes, sync ETA
- **Tor-ready** — `--proxy` routes all outbound P2P through SOCKS5 with
  proxy-side name resolution (no DNS leaks); `.onion` peers via `--connect`
- **Drivechain (BIP300/301)** — opt-in `--drivechain=track|enforce`: sidechain
  proposal/withdrawal tracking, escrow (CTIP) validation, blind merged mining.
  Full **ecash/drivechain** node support (running forseti on the drivechain
  hardfork chain) is in the works
- **Dashboards** — instant-start GUI window (raylib), SSH-friendly TUI
  (ncurses), and a standalone remote client (`forseti-gui`)
- **First-run setup wizard** (`--wizard`) — a `menuconfig`-style ncurses flow
  that writes your `forseti.conf` and prints the exact command to start
- **Runs headless or as a daemon** (`--daemon`) — forks, detaches, and logs to
  `<datadir>/debug.log`, like `bitcoind -daemon`

## Quick Start

Prebuilt binaries (macOS arm64, Linux x64/arm64) are on the
[releases page](../../releases). Or build from source:

```bash
git clone --recursive https://github.com/Galaxoid-Labs/forseti.git
cd forseti && make

./forseti --network=signet --datadir=~/forseti-signet --gui   # small network, syncs fast
./forseti --network=mainnet --datadir=~/forseti --dbcache=4096 --prune=2000 --gui
```

Requires the Odin compiler, LLVM 15+, `make`, plus `cmake` and zstd
(`libzstd-dev` / `brew install zstd`) for the address-index engine — full
details in [docs/build.md](docs/build.md).

### First-run setup wizard

Not sure what to configure? Run the wizard — a `menuconfig`-style ncurses flow
that asks the handful of decisions that actually vary per user (network, data
directory, full vs pruned, cache size, RPC auth, dashboard, plus an Advanced
toggles screen), then creates the data directory, writes a `forseti.conf`, and
prints the exact command to start:

```bash
./forseti --wizard
```

It writes the config and exits without touching the network — everything it
doesn't ask keeps its default and can be edited in the conf afterward.

### Configuration file

Instead of passing everything on the command line, drop a `forseti.conf` in
your data directory — the node reads `<datadir>/forseti.conf` at startup. The
format is INI-style, mirroring Bitcoin Core's `bitcoin.conf` (`#` comments,
`key=value`, optional `[network]` sections). CLI flags override the file.

```bash
# ~/forseti/forseti.conf
network=mainnet
dbcache=1024
prune=2000
rpcuser=alice
rpcpassword=hunter2
```

```bash
./forseti --datadir=~/forseti --gui        # everything else comes from the conf
```

A fully-commented [`contrib/forseti.conf.sample`](contrib/forseti.conf.sample)
lists every supported key with its default. Copy it and uncomment what you
need:

```bash
cp contrib/forseti.conf.sample ~/forseti/forseti.conf
```

## Performance

Full mainnet initial block download (genesis → chain tip), measured:

| Machine | Config | Time |
|---------|--------|------|
| NVIDIA DGX Spark (GB10 Grace-Blackwell, 20-core Arm64, 128 GB) | `--dbcache=16384`, assumevalid on | **~5.5 hours** |
| same machine | `--dbcache=16384`, assumevalid on, `--index-addresses --esplora` | **~12–13 hours** |

On a fast CPU with hardware SHA-256, IBD is **I/O-bound** — UTXO reads dominate over script verification — so a fast NVMe and a large `--dbcache` help most. Building the address index (`--index-addresses`) during the same pass roughly doubles wall-clock — the random scripthash writes are compaction-heavy — but it's **one pass**: the node finishes sync with the Esplora wallet backend already built, no separate multi-hour indexer run. See [docs/hardware.md](docs/hardware.md) for backend details and recommendations.

## Documentation

| Doc | Contents |
|-----|----------|
| [docs/build.md](docs/build.md) | Dependencies, compiling, running the tests |
| [docs/usage.md](docs/usage.md) | Syncing each network, monitoring, every CLI flag, config file, ports |
| [docs/rpc.md](docs/rpc.md) | RPC usage and the full Bitcoin Core coverage matrix |
| [docs/integrations.md](docs/integrations.md) | **Built-in Esplora REST API** (BDK, no sidecar), plus external electrs (BDK/Sparrow), Esplora, mempool.space, ZMQ, + a regtest test playbook |
| [docs/dashboards.md](docs/dashboards.md) | GUI window, terminal TUI, remote client |
| [docs/architecture.md](docs/architecture.md) | Project layout, storage design, threading, sync internals |
| [docs/bips.md](docs/bips.md) | All 50 implemented BIPs |
| [docs/hardware.md](docs/hardware.md) | What to run it on (SHA-256 backends, IBD times) |
| [docs/full-validation-test.md](docs/full-validation-test.md) | Full-consensus sync from genesis (`--assumevalid=0`) — the strongest correctness test |
| [docs/history.md](docs/history.md) | The 50 build phases and what's left |

## License

MIT
