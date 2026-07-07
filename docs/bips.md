# Supported BIPs

| BIP | Title | Implementation |
|-----|-------|---------------|
| 11 | M-of-N Standard Transactions | Script interpreter (OP_CHECKMULTISIG) |
| 13 | Address Format for P2SH | Address encoding/decoding |
| 16 | Pay to Script Hash | Script interpreter (P2SH evaluation) |
| 22 | getblocktemplate | — (not yet) |
| 30 | Duplicate Transactions | Consensus validation (reject duplicate coinbase txids) |
| 35 | mempool P2P Message | P2P (reply with inv of mempool txids, gated by `--peerbloomfilters`) |
| 34 | Block v2 (Height in Coinbase) | Consensus validation |
| 65 | OP_CHECKLOCKTIMEVERIFY | Script interpreter |
| 66 | Strict DER Signatures | Script interpreter (DERSIG flag) |
| 68 | Relative Lock-time (Sequence Numbers) | Consensus validation (sequence locks in connect_block) |
| 94 | Testnet4 | Chain params, difficulty retarget fix |
| 111 | NODE_BLOOM Service Bit | P2P (NODE_BLOOM flag, `--peerbloomfilters`, disconnect on unsupported) |
| 112 | CHECKSEQUENCEVERIFY | Script interpreter |
| 113 | Median Time Past for Lock-time | Consensus validation (MTP calculation) |
| 125 | Replace-by-Fee | Mempool (opt-in + fullrbf, fee checks, eviction limits) |
| 130 | sendheaders | P2P (header-based block announcements) |
| 133 | feefilter | P2P (per-peer minimum fee rate for tx relay) |
| 137 | Signatures of Messages | RPC (signmessagewithprivkey, verifymessage) |
| 141 | Segregated Witness (Consensus) | Script interpreter, consensus validation |
| 143 | Segwit Sighash (v0) | Sighash computation + caching |
| 144 | Segregated Witness (Peer Services) | P2P (NODE_WITNESS service bit) |
| 152 | Compact Block Relay | P2P (send + receive, SipHash short IDs, reconstruction) |
| 155 | addrv2 | P2P (addr relay, address manager, v1↔v2 conversion) |
| 159 | NODE_NETWORK_LIMITED | P2P (service bit for nodes serving recent 288 blocks) |
| 157 | Client Side Block Filtering | P2P (serve getcfilters/getcfheaders/getcfcheckpt) |
| 158 | Compact Block Filters (Basic) | GCS construction, filter building, filter DB |
| 173 | Bech32 Addresses (v0) | Address encoding/decoding (P2WPKH, P2WSH) |
| 300 | Hashrate Escrows (Drivechain) | `drivechain/` package: M1-M6 message codecs, D1/D2 databases, CTIP tracking, OP_DRIVECHAIN — opt-in via `--drivechain` |
| 301 | Blind Merged Mining | `drivechain/` package: BMM accept/request parsing and matching — opt-in via `--drivechain` |
| 324 | Version 2 P2P Encrypted Transport | P2P (ElligatorSwift ECDH, FSChaCha20Poly1305, v1 fallback) |
| 325 | Signet | Chain params, signet challenge validation |
| 339 | wtxid-based Transaction Relay | P2P (wtxid inv, wtxid→txid index, relay) |
| 340 | Schnorr Signatures | Crypto (secp256k1 schnorrsig verification) |
| 341 | Taproot (SegWit v1) | Script interpreter, sighash computation + caching |
| 342 | Tapscript | Script interpreter (OP_CHECKSIGADD, leaf versioning) |
| 350 | Bech32m Addresses (v1+) | Address encoding/decoding (P2TR) |

## BIP300/301 (Drivechain) notes

Neither BIP is activated on any public Bitcoin network, so support is strictly
opt-in via `--drivechain=off|track|enforce` (default `off` — byte-for-byte the
non-drivechain behavior):

- **`track`** parses the six BIP300 messages (M1 sidechain proposal, M2 ack,
  M3 withdrawal-bundle proposal, M4 ack votes, M5 deposit, M6 withdrawal) and
  BIP301 BMM accepts/requests from connected blocks and maintains the
  sidechain database (D1, 256 slots) and withdrawal database (D2) — without
  rejecting anything. Zero-risk observation mode.
- **`enforce`** additionally applies the consensus rules: OP_DRIVECHAIN escrow
  (CTIP) tracking, M5/M6 validity (deposit must increase the treasury; a
  withdrawal must match an approved bundle by its blinded hash), and BIP301
  BMM request/accept matching. Violating blocks are rejected. **Warning:**
  this is CUSF-style voluntary enforcement — while the rest of the network
  does not enforce these rules, a violating block forks this node off.

Where the BIP text is ambiguous, the implementation follows the
[CUSF enforcer](https://github.com/LayerTwo-Labs/bip300301_enforcer/) (the
living reference the BIP defers to) — notably the blinded M6 hash: the
withdrawal tx with inputs cleared and output 0 replaced by a zero-value
`OP_RETURN <8-byte big-endian fee>`.

D1/D2 persist in the chainstate LevelDB atomically with the UTXO flush tip;
per-block undo snapshots (written only when a block changes the state) make
reorgs exact. Read the state via the `listsidechains`, `getsidechaininfo`,
and `listwithdrawalstatus` RPCs. State is tracked from the height the flag is
first enabled; resync with the flag on for full-history tracking.

**On the announced "eCash" fork (block ~964,000, ~August 2026):** if that
BIP300-activating hard fork ships and you want this node to follow the fork
chain, `--drivechain=enforce` alone will not be enough. Peer discovery is the
first problem: the DNS seeds and the address manager serve majority-chain
peers, which will ban/ignore a fork follower — expect to need explicit
fork-aware peers via `--connect=<ip:port>` (or future `addnode`) rather than
normal discovery. The fork also reportedly changes more than BIP300 (coin
split), so consensus-side work beyond this implementation would be required;
out of scope until something concrete ships to validate against.
