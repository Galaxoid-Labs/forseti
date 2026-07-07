# Running & Configuration

```bash
# Show help
./btcnode --help

# Start in regtest mode (no peers needed, good for RPC testing)
./btcnode --network=regtest --no-p2p --rpcuser=user --rpcpassword=pass

# Query it
curl -s -u user:pass --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:18443/
```

### Syncing a Network

Each network syncs via P2P and stores data in its own directory. The examples below set explicit RPC credentials so you can query the node immediately. Run in the background with `nohup` and monitor via the log file:

**Mainnet:**
```bash
# Start syncing mainnet (full validation, ~939k blocks)
nohup ./btcnode --network=mainnet --datadir=/tmp/btcnode-mainnet --dbcache=4096 \
  --rpcuser=user --rpcpassword=pass > /tmp/btcnode-mainnet.log 2>&1 &

# Monitor sync progress
tail -f /tmp/btcnode-mainnet.log | grep "Blocks:"

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
# or: kill -SIGINT $(pgrep -f "btcnode.*mainnet")
```

**Signet:**
```bash
nohup ./btcnode --network=signet --datadir=/tmp/btcnode-signet --dbcache=4096 \
  --rpcuser=user --rpcpassword=pass > /tmp/btcnode-signet.log 2>&1 &

tail -f /tmp/btcnode-signet.log | grep "Blocks:"
curl -s -u user:pass \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:38332/
```

**Testnet4:**
```bash
nohup ./btcnode --network=testnet4 --datadir=/tmp/btcnode-testnet4 --dbcache=4096 \
  --rpcuser=user --rpcpassword=pass > /tmp/btcnode-testnet4.log 2>&1 &

tail -f /tmp/btcnode-testnet4.log | grep "Blocks:"
curl -s -u user:pass \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:48332/
```

**Testnet3:**
```bash
nohup ./btcnode --network=testnet3 --datadir=/tmp/btcnode-testnet3 --dbcache=4096 \
  --rpcuser=user --rpcpassword=pass > /tmp/btcnode-testnet3.log 2>&1 &

tail -f /tmp/btcnode-testnet3.log | grep "Blocks:"
curl -s -u user:pass \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' http://127.0.0.1:18332/
```

> **Tip:** If you omit `--rpcuser`/`--rpcpassword`, a `.cookie` file is generated in the data directory (Bitcoin Core compatible). Use `-u "$(cat /tmp/btcnode-signet/.cookie)"` with curl in that case. Use `--server=0` to disable the RPC server entirely.

### Monitoring

```bash
# Watch block progress (any network)
tail -f /tmp/btcnode-mainnet.log | grep "Blocks:"

# Check for validation errors
grep -iE "FAIL|Bad_Script|halting|consensus" /tmp/btcnode-mainnet.log

# Check memory/resource usage
ps aux | grep btcnode | grep -v grep | awk '{print "CPU: "$3"% MEM: "$4"% RSS: "$6/1024"MB"}'

# Reduce memory usage on constrained machines
./btcnode --network=signet --dbcache=64 --rpcuser=user --rpcpassword=pass
```

### CLI Flags

**General:**

| Flag | Description | Default |
|------|-------------|---------|
| `--network=<name>` | `mainnet`, `testnet3`, `testnet4`, `signet`, `regtest` | `regtest` |
| `--gui` | GUI dashboard window (raylib; node stays headless without it) | headless |
| `--tui` | Terminal dashboard (ncurses, SSH-friendly; `q` quits gracefully) | headless |
| `--prune=<MB>` | Delete old block files, keep blk+rev usage under target (min 550, 0=off). Pruned nodes advertise `NODE_NETWORK_LIMITED` only | 0 (keep all) |
| `--datadir=<path>` | Data directory for blocks, index, UTXO database | `/tmp/btcnode-data` |
| `--rpcport=<port>` | JSON-RPC port | Network default |
| `--rpcuser=<user>` | RPC auth username | Cookie auth |
| `--rpcpassword=<pass>` | RPC auth password (must set both user and password) | Cookie auth |
| `--server=<0\|1>` | Enable/disable RPC server | `1` |
| `--connect=<ip:port>` | Connect to a specific peer | DNS discovery |
| `--p2p-port=<port>` | P2P listen port | Network default |
| `--no-p2p` | Disable P2P (RPC-only mode) | `false` |
| `--maxconnections=<N>` | Total peer connections (8 outbound + N-9 inbound) | `125` |
| `--listen=<0\|1>` | Accept inbound P2P connections | `1` |
| `--dbcache=<MB>` | Database cache size in MiB | `450` |
| `--par=<N>` | Script verification threads (0=auto, 1=serial, 2+=parallel) | `0` |
| `--assumevalid=<height>` | Skip script verification below height (0=disable) | Network default |
| `--v2transport=<0\|1>` | BIP 324 v2 encrypted P2P transport | `0` |
| `--blockfilterindex=<0\|1>` | Build and serve BIP 157 compact block filters | `0` |
| `--peerbloomfilters=<0\|1>` | Enable BIP 37 bloom filters + BIP 35 mempool message | `0` |
| `--zmqpub<topic>=<tcp://ip:port>` | ZMQ notifications: `hashblock`, `hashtx`, `rawblock`, `rawtx`, `sequence` | off |
| `--repairutxo` | Maintenance: sweep stale UTXO entries from local block data, report, exit | — |
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

The node reads an optional `btcnode.conf` from the data directory (`<datadir>/btcnode.conf`). The format mirrors Bitcoin Core's `bitcoin.conf` — INI-style with `#` comments and `[section]` network overrides.

**Precedence:** CLI flags > config file > defaults

```ini
# /tmp/btcnode-data/btcnode.conf

network=regtest
rpcport=18443
rpcuser=myuser
rpcpassword=mypassword
server=1
connect=127.0.0.1:18444
no-p2p=1
dbcache=450
par=0
assumevalid=880000
maxconnections=125
listen=1
blockfilterindex=0
peerbloomfilters=0

# Mempool settings (Bitcoin Core compatible)
maxmempool=300
mempoolexpiry=336
mempoolfullrbf=1
limitancestorcount=25
limitdescendantcount=25
minrelaytxfee=0.00001000
dustrelayfee=0.00003000
datacarrier=1
datacarriersize=83
persistmempool=1
# blocksonly=1

# Network-specific sections override global values
[regtest]
rpcport=19443
```

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

