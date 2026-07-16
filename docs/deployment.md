# Deploying forseti as a public Esplora endpoint

This is a start-to-finish playbook for running forseti on a Linux server as a
full node **and** a public wallet backend — syncing mainnet with the built-in
scripthash address index and serving the [Esplora REST API](integrations.md#built-in-esplora-rest-api-recommended-no-sidecar)
over the internet. No electrs/Esplora sidecar, no second copy of the chain: the
node builds the index during sync and serves the API itself.

Point [BDK](https://docs.rs/bdk_esplora) / `esplora-client` wallets — or a
browser explorer — straight at it.

## What you get

- A fully-validating mainnet full node.
- A scripthash **address index** built *during* the initial sync (one pass).
- The **Esplora HTTP REST API** (`/address/:addr`, `/tx/:txid`, `/block/:hash`,
  `/mempool`, `/fee-estimates`, …) served by the node — response JSON verified
  byte-identical to Blockstream's Esplora.
- `/tx/:txid` and all tx endpoints resolve from the address index — you do
  **not** need `--txindex`.

## Requirements

- **Disk:** mainnet unpruned (~700 GB and growing) **plus** the address index
  (RocksDB, tens to 100+ GB). Budget **~1 TB+ of fast NVMe** — the index sync is
  compaction-heavy, so slow disks hurt a lot.
- **RAM:** enough for `dbcache` (the coins cache) **plus** the RocksDB
  address-index memtable (~1 GB) plus OS headroom. 16 GB is comfortable with
  `dbcache=8192`; more RAM → raise `dbcache`.
- **Must be unpruned.** `--index-addresses` is incompatible with `--prune` (the
  index reads txs from full block files).
- Build prerequisites (Odin, LLVM 15+, `make`, `cmake`, zstd) — see
  [build.md](build.md).

Sync time reference: on an NVIDIA DGX Spark (`--dbcache=16384`, assumevalid on),
plain IBD is ~5.5 h; with `--index-addresses --esplora` in the same pass it's
~12–13 h. See [hardware.md](hardware.md).

## 1. Config file

Drop this at `<datadir>/forseti.conf` (e.g. `/data/forseti/forseti.conf`):

```ini
# ── forseti.conf — mainnet server, public Esplora wallet backend ──────────
network=mainnet

# Coins-cache budget (LevelDB). Size toward free RAM, leaving headroom for the
# RocksDB address-index memtable (~1 GB) + the OS. 8 GB is a safe start.
dbcache=8192

# RPC — keep it LOOPBACK ONLY. Never expose 8332 to the internet.
rpcuser=forseti
rpcpassword=CHANGE_ME_TO_SOMETHING_LONG

# Accept inbound P2P (good server citizen).
listen=1

# ── Wallet backend ────────────────────────────────────────────────────────
# Scripthash address index, built DURING sync. Unpruned only. This alone
# powers the whole Esplora API incl. /tx/:txid — no --txindex needed.
index-addresses=1

# Serve the Esplora REST API. See "Public serving" below for the two options.
# Direct (quick):        esplora=0.0.0.0:3000
# Behind a proxy (best): esplora=127.0.0.1:3000
esplora=0.0.0.0:3000
```

Then start it (reads the conf from the datadir):

```bash
./forseti --datadir=/data/forseti --daemon
tail -f /data/forseti/debug.log        # watch sync progress
```

## 2. Run it under systemd (survives reboots, restarts on crash)

Create a dedicated user and a unit. Run in the **foreground** (no `--daemon`) so
systemd tracks the process directly and captures logs in the journal:

```ini
# /etc/systemd/system/forseti.service
[Unit]
Description=forseti Bitcoin node + Esplora API
After=network-online.target
Wants=network-online.target

[Service]
User=forseti
Group=forseti
ExecStart=/opt/forseti/forseti --datadir=/data/forseti
Restart=on-failure
RestartSec=10
# A flush at scale can take minutes — give shutdown room, never kill mid-flush.
TimeoutStopSec=600
# Node + RocksDB + many peers open a lot of files.
LimitNOFILE=65536
# Hardening (optional but recommended)
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/data/forseti

[Install]
WantedBy=multi-user.target
```

```bash
sudo useradd --system --home /data/forseti --shell /usr/sbin/nologin forseti
sudo mkdir -p /data/forseti && sudo chown forseti:forseti /data/forseti
# put forseti.conf in /data/forseti/ (from step 1)
sudo systemctl daemon-reload
sudo systemctl enable --now forseti
sudo journalctl -u forseti -f            # watch sync
```

`systemctl stop forseti` sends SIGTERM; forseti flushes and shuts down
gracefully (never `kill -9` mid-flush — recovery handles it but costs a replay).

## 3. Serving Esplora publicly

The Esplora API is **read-only chain data with no auth by design** (and
`Access-Control-Allow-Origin: *` so browsers can hit it) — safe to expose. Two
approaches:

### The one firewall rule that matters

Open **3000** (Esplora) and optionally **8333** (P2P inbound). **Keep 8332 (RPC)
closed** — it's loopback by default; do not add `rpcbind`/`rpcallowip` for the
public.

```bash
sudo ufw allow 3000/tcp        # Esplora API
sudo ufw allow 8333/tcp        # P2P inbound (optional)
# 8332 (RPC) stays closed
```

### Direct (quick): `esplora=0.0.0.0:3000`

Binds all interfaces. Clients hit `http://your-host:3000/`. Fine for testing or
a trusted network. forseti logs a warning on non-loopback bind to remind you
it's unauthenticated.

### Behind a reverse proxy (recommended for a real public endpoint)

Bind Esplora to loopback and let nginx/Caddy face the internet — you get TLS,
rate limiting, and caching (a raw public API *will* get hammered):

```ini
esplora=127.0.0.1:3000
```

```nginx
# /etc/nginx/... — add certbot for TLS; define the limit_req zone in http{}:
#   limit_req_zone $binary_remote_addr zone=esplora:10m rate=20r/s;
server {
    listen 443 ssl;
    server_name explorer.example.com;
    # ssl_certificate ... (certbot)
    location / {
        proxy_pass http://127.0.0.1:3000;
        limit_req zone=esplora burst=40 nodelay;
        proxy_read_timeout 60s;
    }
}
```

Caddy equivalent (auto-TLS):
```
explorer.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

## 4. Verify

Once synced (or even mid-sync, for tip data):

```bash
curl http://127.0.0.1:3000/blocks/tip/height
curl http://127.0.0.1:3000/block-height/1
curl http://127.0.0.1:3000/address/<some-address>
curl http://127.0.0.1:3000/fee-estimates
```

Point a wallet at it — e.g. BDK's `esplora-client` with base URL
`https://explorer.example.com/` (or `http://your-host:3000/`).

## Notes

- **No `--txindex`.** The address index resolves `/tx/:txid`; adding txindex
  would only duplicate work.
- **Reorgs** are handled by the node's existing undo machinery — the address
  index rolls back with the chain.
- **Broadcast** (`POST /tx`) reuses the node's normal `sendrawtransaction` path
  into the mempool + P2P relay.
- For the external-indexer alternatives (electrs, Blockstream/Esplora,
  mempool.space) and a regtest test playbook, see [integrations.md](integrations.md).
