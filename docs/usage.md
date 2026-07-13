# Running & Configuration

```bash
# Show help
./forseti --help

# Start in regtest mode (no peers needed, good for RPC testing)
./forseti --network=regtest --no-p2p --rpcuser=user --rpcpassword=pass

# Query it
curl -s -u user:pass --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:18443/
```

### First-Run Setup Wizard

If you'd rather not assemble a command line or config by hand, run the wizard:

```bash
./forseti --wizard
```

It's a `menuconfig`-style ncurses flow that walks through the decisions that
actually vary per user, then does the setup for you:

1. **Network** — mainnet / testnet4 / signet / regtest
2. **Data directory** — where blocks, chainstate, and the config live
3. **Disk usage** — full node or pruned (choose a size)
4. **Cache** — `dbcache` in MB
5. **RPC auth** — cookie file (default) or an explicit user/password
6. **Review** — confirm and write; an **Advanced** screen here toggles
   `server`, `listen`, `v2transport`, `txindex`, `blockfilterindex`,
   `mempoolfullrbf`, `persistmempool`, `peerbloomfilters`, and `blocksonly`

Navigate with the arrow keys, `Space` toggles checkboxes, `←/→` move between
the bottom buttons, and `Enter` activates the focused one. On finish it creates
the data directory, writes `<datadir>/forseti.conf` (only keys that differ from
the defaults), and prints a cheat sheet of **every way to start the node**
(foreground, `--gui`, `--tui`, `--daemon`) and **every way to watch it**
(`forseti-gui` desktop/TUI over RPC, with the right auth flags and port filled
in for your network). The run mode is a launch-time flag, not a config setting,
so nothing is baked in — you pick when you start. It never touches the network;
everything it doesn't ask keeps its default and can be edited in the conf
afterward. Requires an interactive terminal (a TTY).

### Running on a Server (daemon / background)

`--daemon` runs the node detached, like `bitcoind -daemon`: it forks, releases
the terminal, and redirects all logging to `<datadir>/debug.log`. The launching
command prints the child PID and returns immediately.

```bash
./forseti --network=mainnet --datadir=~/forseti --prune=2000 --daemon
# forseti started in the background (PID 12345)
# Logging to /home/you/forseti/debug.log
# Stop it with:  kill 12345   (or the `stop` RPC)

tail -f ~/forseti/debug.log                          # follow the log
./forseti-gui --tui --cookie=~/forseti/.cookie       # or watch it live over RPC
```

Because a daemon has no terminal, `--daemon` is mutually exclusive with
`--gui`/`--tui`. Stop it with the `stop` RPC (graceful — flushes the UTXO cache)
or `kill <pid>`.

**Logging note:** whenever the terminal is owned by the dashboard (`--tui`) or
detached (`--daemon`), logs go to `<datadir>/debug.log` instead of the console,
so they never corrupt the TUI or vanish into a detached session. In normal
foreground mode logs still print to the terminal as before.

### Syncing a Network

Each network syncs via P2P and stores data in its own directory. The examples below set explicit RPC credentials so you can query the node immediately. Run in the background with `nohup` and monitor via the log file:

**Mainnet:**
```bash
# Start syncing mainnet (full validation, ~939k blocks)
nohup ./forseti --network=mainnet --datadir=/tmp/forseti-mainnet --dbcache=4096 \
  --rpcuser=user --rpcpassword=pass > /tmp/forseti-mainnet.log 2>&1 &

# Monitor sync progress
tail -f /tmp/forseti-mainnet.log | grep "Blocks:"

# Check current block height via RPC
curl -s -u user:pass \
     --data '{"method":"getblockcount","params":[],"id":1}' http://127.0.0.1:8332/

# Check sync status
curl -s -u user:pass \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:8332/ | python3 -m json.tool

# Check peer connections
curl -s -u user:pass \
     --data '{"method":"getpeerinfo","params":[],"id":1}' http://127.0.0.1:8332/ | python3 -m json.tool

# Stop gracefully (saves mempool, flushes UTXO cache)
curl -s -u user:pass \
     --data '{"method":"stop","params":[],"id":1}' http://127.0.0.1:8332/
# or: kill -SIGINT $(pgrep -f "forseti.*mainnet")
```

**Signet:**
```bash
nohup ./forseti --network=signet --datadir=/tmp/forseti-signet --dbcache=4096 \
  --rpcuser=user --rpcpassword=pass > /tmp/forseti-signet.log 2>&1 &

tail -f /tmp/forseti-signet.log | grep "Blocks:"
curl -s -u user:pass \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:38332/
```

**Testnet4:**
```bash
nohup ./forseti --network=testnet4 --datadir=/tmp/forseti-testnet4 --dbcache=4096 \
  --rpcuser=user --rpcpassword=pass > /tmp/forseti-testnet4.log 2>&1 &

tail -f /tmp/forseti-testnet4.log | grep "Blocks:"
curl -s -u user:pass \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:48332/
```

**Testnet3:**
```bash
nohup ./forseti --network=testnet3 --datadir=/tmp/forseti-testnet3 --dbcache=4096 \
  --rpcuser=user --rpcpassword=pass > /tmp/forseti-testnet3.log 2>&1 &

tail -f /tmp/forseti-testnet3.log | grep "Blocks:"
curl -s -u user:pass \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:18332/
```

> **Tip:** If you omit `--rpcuser`/`--rpcpassword`, a `.cookie` file is generated in the data directory (Bitcoin Core compatible). Use `-u "$(cat /tmp/forseti-signet/.cookie)"` with curl in that case. Use `--server=0` to disable the RPC server entirely.

### Monitoring

```bash
# Watch block progress (any network)
tail -f /tmp/forseti-mainnet.log | grep "Blocks:"

# Check for validation errors
grep -iE "FAIL|Bad_Script|halting|consensus" /tmp/forseti-mainnet.log

# Check memory/resource usage
ps aux | grep forseti | grep -v grep | awk '{print "CPU: "$3"% MEM: "$4"% RSS: "$6/1024"MB"}'

# Reduce memory usage on constrained machines
./forseti --network=signet --dbcache=64 --rpcuser=user --rpcpassword=pass
```

### CLI Flags

**General:**

| Flag | Description | Default |
|------|-------------|---------|
| `--network=<name>` | `mainnet`, `testnet3`, `testnet4`, `signet`, `regtest` | `regtest` |
| `--wizard` | Interactive first-run setup: write a `forseti.conf`, then exit (see above) | — |
| `--daemon` | Run in the background: fork, detach from the terminal, log to `<datadir>/debug.log`. Prints the PID and exits. Mutually exclusive with `--gui`/`--tui` | foreground |
| `--gui` | GUI dashboard window (raylib; node stays headless without it) | headless |
| `--tui` | Terminal dashboard (ncurses, SSH-friendly; `q` quits gracefully) | headless |
| `--prune=<MB>` | Delete old block files, keep blk+rev usage under target (min 550, 0=off). Pruned nodes advertise `NODE_NETWORK_LIMITED` only | 0 (keep all) |
| `--datadir=<path>` | Data directory for blocks, index, UTXO database | `/tmp/forseti-data` |
| `--rpcport=<port>` | JSON-RPC port | Network default |
| `--rpcuser=<user>` | RPC auth username | Cookie auth |
| `--rpcpassword=<pass>` | RPC auth password (must set both user and password) | Cookie auth |
| `--rpcbind=<addr>` | Bind RPC to an address (e.g. `0.0.0.0` for a trusted LAN); non-loopback requires `--rpcallowip` | `127.0.0.1` |
| `--rpcallowip=<ip[/nn]>` | Allow RPC from an IPv4 address/CIDR, repeatable (loopback always allowed) | — |
| `--server=<0\|1>` | Enable/disable RPC server | `1` |
| `--connect=<ip:port>` | Connect to a specific peer | DNS discovery |
| `--p2p-port=<port>` | P2P listen port | Network default |
| `--no-p2p` | Disable P2P (RPC-only mode) | `false` |
| `--maxconnections=<N>` | Total peer connections (8 outbound + N-9 inbound) | `125` |
| `--listen=<0\|1>` | Accept inbound P2P connections | `1` |
| `--maxuploadtarget=<MiB>` | Daily upload budget; when exceeded, blocks older than a week are not served (tip relay unaffected) | 0 (unlimited) |
| `--proxy=<ip[:port]>` | SOCKS5 proxy for all outbound P2P (e.g. Tor at `127.0.0.1:9050`). Hostnames/.onion resolve at the proxy, DNS seeds are contacted through it, inbound is disabled | direct |
| `--dbcache=<MB>` | Database cache size in MiB | `450` |
| `--par=<N>` | Script verification threads (0=auto, 1=serial, 2+=parallel) | `0` |
| `--assumevalid=<height>` | Skip script verification below height (0=disable) | Network default |
| `--v2transport=<0\|1>` | BIP 324 v2 encrypted P2P transport (automatic v1 fallback) | `1` |
| `--blockfilterindex=<0\|1>` | Build and serve BIP 157 compact block filters | `0` |
| `--txindex=<0\|1>` | Full transaction index (historical `getrawtransaction`); incompatible with `--prune`; catch-up runs at startup when enabled on an existing datadir | `0` |
| `--index-addresses=<0\|1>` | Scripthash (address) index for the built-in wallet backend, built during sync; incompatible with `--prune`. Catch-up runs at startup if enabled on an existing datadir | `0` |
| `--esplora=<1\|addr:port>` | Serve the built-in [Esplora REST API](integrations.md#built-in-esplora-rest-api-recommended-no-sidecar) for BDK/wallet clients. `1` = `127.0.0.1:3000`, or an `addr:port`. Requires `--index-addresses` | off |
| `--peerbloomfilters=<0\|1>` | Enable BIP 37 bloom filters + BIP 35 mempool message | `0` |
| `--zmqpub<topic>=<tcp://ip:port>` | ZMQ notifications: `hashblock`, `hashtx`, `rawblock`, `rawtx`, `sequence` | off |
| `--repairutxo` | Maintenance: sweep stale UTXO entries from local block data, report, exit | — |
| `--drivechain=<mode>` | BIP 300/301: `off`, `track` (maintain sidechain/withdrawal DBs, reject nothing), or `enforce` (reject violating blocks — see warning in [bips.md](bips.md)) | `off` |
| `--debug` | Enable debug logging | `false` |

**Mempool (matching Bitcoin Core):**

| Flag | Description | Default |
|------|-------------|---------|
| `--maxmempool=<MB>` | Maximum mempool size in megabytes | `300` |
| `--mempoolexpiry=<hours>` | Evict transactions older than N hours | `336` (14 days) |
| `--mempoolfullrbf=<0\|1>` | Allow full replace-by-fee | `1` |
| `--limitancestorcount=<N>` | Max unconfirmed ancestor count per tx | `25` |
| `--limitancestorsize=<kvB>` | Max ancestor chain size in kvB | `101` |
| `--limitdescendantcount=<N>` | Max unconfirmed descendant count per tx | `25` |
| `--limitdescendantsize=<kvB>` | Max descendant chain size in kvB | `101` |
| `--minrelaytxfee=<BTC/kvB>` | Minimum relay fee rate | `0.00001000` |
| `--incrementalrelayfee=<BTC/kvB>` | Fee rate increment for RBF and mempool limiting | `0.00001000` |
| `--dustrelayfee=<BTC/kvB>` | Dust threshold fee rate | `0.00003000` |
| `--datacarrier=<0\|1>` | Allow OP_RETURN outputs | `1` |
| `--datacarriersize=<bytes>` | Max OP_RETURN script size | `83` |
| `--permitbaremultisig=<0\|1>` | Allow bare multisig outputs | `1` |
| `--blocksonly` | Disable tx relay, only sync blocks | `false` |
| `--persistmempool=<0\|1>` | Save/load mempool on shutdown/startup | `1` |

### Config File

The node reads an optional `forseti.conf` from the data directory (`<datadir>/forseti.conf`). The format mirrors Bitcoin Core's `bitcoin.conf` — INI-style with `#` comments and `[section]` network overrides.

**Precedence:** CLI flags > config file > defaults

A fully-commented [`contrib/forseti.conf.sample`](../contrib/forseti.conf.sample) in the repo lists every supported key with its default. Copy it to your data directory to get started:

```bash
cp contrib/forseti.conf.sample ~/forseti/forseti.conf
./forseti --datadir=~/forseti        # reads ~/forseti/forseti.conf
```

Each config key matches a `--flag` of the same name (drop the `--`). Example:

```ini
# ~/forseti/forseti.conf

network=mainnet
dbcache=1024
prune=2000
rpcuser=myuser
rpcpassword=mypassword
txindex=1
maxuploadtarget=5000

# Network-specific sections override global values
[signet]
dbcache=512
```

`rpcallowip` accepts a comma-separated list. The following are CLI-only and are *not* read from the config file: `--no-p2p`, `--repairutxo`, `--gui`, `--tui`, `--wizard`, `--daemon`, `--debug`, `--help`.

Keys match CLI flag names without the `--` prefix. Boolean values accept `1`, `true`, or `yes` for on.

Values in a network-specific section (e.g. `[regtest]`) take priority over global values. CLI flags always override both.

### Default Ports

| Network | RPC Port | P2P Port |
|---------|----------|----------|
| mainnet | 8332 | 8333 |
| testnet3 | 18332 | 18333 |
| testnet4 | 48332 | 48333 |
| signet | 38332 | 38333 |
| regtest | 18443 | 18444 |

The built-in **Esplora REST API** (`--esplora`) defaults to `127.0.0.1:3000` on every network — override with `--esplora=<addr:port>`.

