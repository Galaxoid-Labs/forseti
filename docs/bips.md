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
| 324 | Version 2 P2P Encrypted Transport | P2P (ElligatorSwift ECDH, FSChaCha20Poly1305, v1 fallback) |
| 325 | Signet | Chain params, signet challenge validation |
| 339 | wtxid-based Transaction Relay | P2P (wtxid inv, wtxid→txid index, relay) |
| 340 | Schnorr Signatures | Crypto (secp256k1 schnorrsig verification) |
| 341 | Taproot (SegWit v1) | Script interpreter, sighash computation + caching |
| 342 | Tapscript | Script interpreter (OP_CHECKSIGADD, leaf versioning) |
| 350 | Bech32m Addresses (v1+) | Address encoding/decoding (P2TR) |

