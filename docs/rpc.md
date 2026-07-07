# RPC Interface

The node exposes a JSON-RPC 1.0 interface over HTTP with authentication. By default, a `.cookie` file is generated in the data directory (matching Bitcoin Core's cookie auth). You can also set explicit credentials with `--rpcuser` and `--rpcpassword`.

```bash
# Using curl with cookie auth (default)
curl -s -u "$(cat /tmp/btcnode-data/.cookie)" \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' \
     http://127.0.0.1:18443/

# Using curl with explicit credentials
curl -s -u myuser:mypassword \
     --data '{"method":"getblockchaininfo","params":[],"id":1}' \
     http://127.0.0.1:18443/

# Using bitcoin-cli (reads cookie file automatically)
bitcoin-cli -rpcport=18443 getblockchaininfo
```

## Bitcoin Core RPC Coverage (59 / 78 non-wallet RPCs)

Plus four btcnode-specific methods: `getnodestatus` (feeds the GUI/TUI
dashboards) and the drivechain views `listsidechains`, `getsidechaininfo`,
and `listwithdrawalstatus` (see below).

The tables below show every non-wallet RPC from Bitcoin Core. Wallet RPCs are intentionally excluded.

**Blockchain (23/25):**

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
| `gettxoutsetinfo` | Yes | UTXO count + total amount |
| `preciousblock` | Yes | Routed through the P2P control queue |
| `pruneblockchain` | Yes | Requires `--prune` mode |
| `savemempool` | Yes | |
| `scantxoutset` | — | UTXO set descriptor scan |
| `verifychain` | — | Block-by-block re-verification |
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

**Generating (1/3):**

| Method | Status | Notes |
|--------|--------|-------|
| `generateblock` | — | Regtest block generation |
| `generatetoaddress` | Yes | Regtest only; mines mempool txs + coinbase |
| `generatetodescriptor` | — | Regtest mining to descriptor |

**Mining (2/6):**

| Method | Status | Notes |
|--------|--------|-------|
| `getblocktemplate` | — | Block template for miners |
| `getmininginfo` | Yes | |
| `getnetworkhashps` | Yes | |
| `prioritisetransaction` | — | Manual fee delta |
| `submitblock` | — | Mined block submission |
| `submitheader` | — | Header-only submission |

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

**Raw Transactions (8/17):**

| Method | Status | Notes |
|--------|--------|-------|
| `analyzepsbt` | — | PSBT not implemented |
| `combinepsbt` | — | PSBT not implemented |
| `combinerawtransaction` | Yes | |
| `converttopsbt` | — | PSBT not implemented |
| `createpsbt` | — | PSBT not implemented |
| `createrawtransaction` | Yes | |
| `decodepsbt` | — | PSBT not implemented |
| `decoderawtransaction` | Yes | |
| `decodescript` | Yes | |
| `finalizepsbt` | — | PSBT not implemented |
| `fundrawtransaction` | — | Requires wallet UTXO selection |
| `getrawtransaction` | Yes | Mempool lookup |
| `joinpsbts` | — | PSBT not implemented |
| `sendrawtransaction` | Yes | |
| `signrawtransactionwithkey` | Yes | P2PKH, P2WPKH, P2SH-P2WPKH |
| `testmempoolaccept` | Yes | |
| `utxoupdatepsbt` | — | PSBT not implemented |

**Util (6/8):**

| Method | Status | Notes |
|--------|--------|-------|
| `createmultisig` | Yes | legacy / p2sh-segwit / bech32 |
| `deriveaddresses` | — | Descriptor address derivation |
| `estimatesmartfee` | Yes | Mempool-floor estimator |
| `getdescriptorinfo` | — | Output descriptor analysis |
| `getindexinfo` | Yes | |
| `signmessagewithprivkey` | Yes | |
| `validateaddress` | Yes | |
| `verifymessage` | Yes | |

## Drivechain RPCs (btcnode-specific)

Available when the node runs with `--drivechain=track` or `enforce` (BIP 300/301);
they error with "Drivechain support is disabled" otherwise.

| Method | Description |
|--------|-------------|
| `listsidechains` | Active sidechain slots (D1) with CTIP escrow info, plus pending M1 proposals under vote |
| `getsidechaininfo <nsidechain>` | One active sidechain: title, description, hashes, activation height, CTIP (txid/vout/amount) |
| `listwithdrawalstatus ( nsidechain )` | Withdrawal bundles (D2): blinded hash, ACK score (`nworkscore`), blocks remaining, approved flag |

