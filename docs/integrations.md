# Wallet & Indexer Integrations

## Electrum Wallets (BDK / Electrum / Sparrow)

forseti speaks enough Bitcoin Core RPC + P2P that [electrs](https://github.com/romanz/electrs)
v0.10 runs against it unmodified, giving any Electrum-protocol wallet
(BDK's `bdk_electrum`, Electrum, Sparrow) address balances, histories, and
UTXOs backed by your own node.

> **⚠️ The node must be UNPRUNED.** electrs builds its own address index by
> reading *every historical block* over the P2P connection. A pruned node has
> deleted those blocks, so electrs's initial index build fails partway through.
> Do not run `--prune` (or pick "pruned" in the wizard) on a node you intend to
> back electrs with — you'd need a full resync.

electrs does **not** need the node's `--txindex`: it maintains its own index.
It pulls historical blocks and learns about new ones over **P2P**, and syncs
the mempool + chain info over **RPC** — no ZMQ required.

**Signet:**
```bash
./forseti --network=signet --datadir=~/forseti-signet --daemon
electrs --network signet \
  --daemon-rpc-addr 127.0.0.1:38332 \
  --daemon-p2p-addr 127.0.0.1:38333 \
  --cookie-file ~/forseti-signet/.cookie \
  --db-dir ~/electrs-db
# wallets connect to electrs at tcp://127.0.0.1:60601
```

**Mainnet:**
```bash
./forseti --network=mainnet --datadir=~/forseti --daemon   # must be unpruned
electrs --network bitcoin \
  --daemon-rpc-addr 127.0.0.1:8332 \
  --daemon-p2p-addr 127.0.0.1:8333 \
  --cookie-file ~/forseti/.cookie \
  --db-dir ~/electrs-db
# wallets connect to electrs at tcp://127.0.0.1:50001
```
The initial mainnet index build takes hours and the electrs DB is tens of GB —
put `--db-dir` on a disk with room.

**Auth with `rpcuser`/`rpcpassword`** (instead of the rotating cookie): drop
`--cookie-file` and give electrs the credentials in its config file (e.g.
`~/.electrs/config.toml`, or point at one with `--conf`):
```toml
auth = "youruser:yourpassword"
```

### Exposing electrs to other machines

Both links from electrs to forseti (`daemon-rpc-addr` 8332, `daemon-p2p-addr`
8333) are localhost — **no firewall rules, and never open the node's 8332/8333
to the internet.** Only the Electrum port that *wallets* connect to needs
opening, and only if they run on another machine. By default electrs binds it
to localhost; to expose it, set in the electrs config:
```toml
electrum_rpc_addr = "0.0.0.0:50001"
```
and open the firewall: `sudo ufw allow 50001`.

**Privacy/security caveat:** the Electrum protocol on 50001 is *plaintext* — it
leaks every address your wallet queries, and anyone who reaches the port can
query the index. On a public/internet-facing server, prefer reaching electrs
over an **SSH tunnel** (`ssh -L 50001:localhost:50001 <server>`) or a **Tor
hidden service** (electrs supports it natively) rather than opening 50001. If
you must open it, use SSL (port 50002) or restrict the firewall rule to specific
client IPs (`sudo ufw allow from <client-ip> to any port 50001`).

For consumers that DO want ZMQ (LND's bitcoind backend, custom indexers),
forseti implements Bitcoin Core's publisher interface natively (no libzmq
dependency — ZMTP 3.0 spoken directly):

```bash
./forseti --zmqpubrawblock=tcp://127.0.0.1:28332 --zmqpubrawtx=tcp://127.0.0.1:28333
```

Topics: `hashblock`, `hashtx`, `rawblock`, `rawtx`, `sequence` — payloads
and per-topic LE32 sequence numbers match Core exactly (verified against
libzmq subscribers).

