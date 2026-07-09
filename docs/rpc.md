# RPC Interface

The node exposes a JSON-RPC 1.0 interface over HTTP with authentication. By default, a `.cookie` file is generated in the data directory (matching Bitcoin Core's cookie auth). You can also set explicit credentials with `--rpcuser` and `--rpcpassword`.

```bash
# Using curl with cookie auth (default)
curl -s -u "$(cat /tmp/forseti-data/.cookie)" \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' \
     http://127.0.0.1:18443/

# Using curl with explicit credentials
curl -s -u myuser:mypassword \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' \
     http://127.0.0.1:18443/

# Using bitcoin-cli (reads cookie file automatically)
bitcoin-cli -rpcport=18443 getblockchaininfo
```

## Bitcoin Core RPC Coverage (77 / 78 non-wallet RPCs)

Plus four forseti-specific methods: `getnodestatus` (feeds the GUI/TUI
dashboards) and the drivechain views `listsidechains`, `getsidechaininfo`,
and `listwithdrawalstatus` (see below).

The tables below show every non-wallet RPC from Bitcoin Core. Wallet RPCs are intentionally excluded.

**Blockchain (25/25):**

| Method | Status | Notes |
|--------|--------|-------|
| `getbestblockhash` | Yes | |
| `getblock` | Yes | Verbosity 0, 1, 2 |
| `getblockchaininfo` | Yes | |
| `getblockcount` | Yes | |
| `getblockfilter` | Yes | BIP 157 compact block filter (basic) |
| `getblockhash` | Yes | |
| `getblockheader` | Yes | |
| `getblockstats` | Yes | |
| `getchaintips` | Yes | |
| `getchaintxstats` | Yes | |
| `getdifficulty` | Yes | |
| `getmempoolancestors` | Yes | Verbose and non-verbose modes |
| `getmempooldescendants` | Yes | Verbose and non-verbose modes |
| `getmempoolentry` | Yes | |
| `getmempoolinfo` | Yes | |
| `getrawmempool` | Yes | |
| `gettxout` | Yes | |
| `gettxoutproof` | Yes | Partial merkle tree proof |
| `gettxoutsetinfo` | Yes | Instant on datadirs with rolling UTXO stats (coinstatsindex-style); full scan on older datadirs |
| `preciousblock` | Yes | Routed through the P2P control queue |
| `pruneblockchain` | Yes | Requires `--prune` mode |
| `savemempool` | Yes | |
| `scantxoutset` | Yes | Synchronous scan of DB + cache; descriptor expansion with default range 1000 |
| `verifychain` | Yes | Levels 0-2 (data reads, context-free validity, undo data); 3/4 run the level-2 checks |
| `verifytxoutproof` | Yes | Merkle proof verification |

**Control (6/6):**

| Method | Status | Notes |
|--------|--------|-------|
| `getmemoryinfo` | Yes | Reports UTXO cache usage |
| `getrpcinfo` | Yes | |
| `help` | Yes | Per-method and full listing |
| `logging` | Yes | Read-only category report |
| `stop` | Yes | Graceful shutdown |
| `uptime` | Yes | |

**Generating (3/3):**

| Method | Status | Notes |
|--------|--------|-------|
| `generateblock` | Yes | Regtest; raw txs and mempool txids (descriptor outputs not supported) |
| `generatetoaddress` | Yes | Regtest only; mines mempool txs + coinbase |
| `generatetodescriptor` | Yes | Non-ranged descriptors |

**Mining (6/6):**

| Method | Status | Notes |
|--------|--------|-------|
| `getblocktemplate` | Yes | segwit rule required; feerate-ordered selection with in-mempool parents; mode=proposal; per-tx sigops reported as 0; no longpoll |
| `getmininginfo` | Yes | |
| `getnetworkhashps` | Yes | |
| `prioritisetransaction` | Yes | Fee delta applied in template selection |
| `submitblock` | Yes | Routed through the P2P control queue (chain single-writer); announces to peers + ZMQ |
| `submitheader` | Yes | |

**Network (13/13):**

| Method | Status | Notes |
|--------|--------|-------|
| `addnode` | Yes | add / remove / onetry |
| `clearbanned` | Yes | |
| `disconnectnode` | Yes | By address or nodeid |
| `getaddednodeinfo` | Yes | |
| `getconnectioncount` | Yes | |
| `getnettotals` | Yes | |
| `getnetworkinfo` | Yes | |
| `getnodeaddresses` | Yes | IPv4 from the address manager |
| `getpeerinfo` | Yes | 18 fields |
| `listbanned` | Yes | Address-level bans |
| `ping` | Yes | |
| `setban` | Yes | Address-level (subnets: /32 only) |
| `setnetworkactive` | Yes | Disconnects all peers when false |

**Raw Transactions (16/17):**

| Method | Status | Notes |
|--------|--------|-------|
| `analyzepsbt` | Yes | Per-input status, next role, fee (BIP174) |
| `combinepsbt` | Yes | Combiner role — union of maps for a shared unsigned tx |
| `combinerawtransaction` | Yes | |
| `converttopsbt` | Yes | Strips scriptSigs/witness |
| `createpsbt` | Yes | Returns base64 PSBT |
| `createrawtransaction` | Yes | |
| `decodepsbt` | Yes | Base64 PSBT → JSON, computes fee when UTXOs present |
| `decoderawtransaction` | Yes | |
| `decodescript` | Yes | |
| `finalizepsbt` | Yes | Standard scripts (single-sig/multisig/P2TR key-path); extracts network tx when complete |
| `fundrawtransaction` | — | Requires wallet UTXO selection |
| `getrawtransaction` | Yes | Mempool + full history with `--txindex` (blockhash/confirmations/blocktime in verbose mode) |
| `joinpsbts` | Yes | Unions distinct PSBTs' inputs/outputs |
| `sendrawtransaction` | Yes | |
| `signrawtransactionwithkey` | Yes | P2PKH, P2WPKH, P2SH-P2WPKH |
| `testmempoolaccept` | Yes | |
| `utxoupdatepsbt` | Yes | Adds witness UTXOs from the node's UTXO set |

**Util (8/8):**

| Method | Status | Notes |
|--------|--------|-------|
| `createmultisig` | Yes | legacy / p2sh-segwit / bech32 |
| `deriveaddresses` | Yes | pkh/wpkh/sh(wpkh)/tr (BIP86)/multi/sortedmulti/wsh/addr; xpub + wildcard ranges |
| `estimatesmartfee` | Yes | Confirmation-tracking estimator (Core CBlockPolicyEstimator port, 3 decay horizons, `fee_estimates.dat` persistence); falls back to the mempool floor until it has observed enough history |
| `getdescriptorinfo` | Yes | Checksum + canonical form; watch-only (xprv/WIF rejected) |
| `getindexinfo` | Yes | Reports block filter index + txindex |
| `signmessagewithprivkey` | Yes | |
| `validateaddress` | Yes | |
| `verifymessage` | Yes | |

## Drivechain RPCs (forseti-specific)

Available when the node runs with `--drivechain=track` or `enforce` (BIP 300/301);
they error with "Drivechain support is disabled" otherwise.

| Method | Description |
|--------|-------------|
| `listsidechains` | Active sidechain slots (D1) with CTIP escrow info, plus pending M1 proposals under vote |
| `getsidechaininfo <nsidechain>` | One active sidechain: title, description, hashes, activation height, CTIP (txid/vout/amount) |
| `listwithdrawalstatus ( nsidechain )` | Withdrawal bundles (D2): blinded hash, ACK score (`nworkscore`), blocks remaining, approved flag |

