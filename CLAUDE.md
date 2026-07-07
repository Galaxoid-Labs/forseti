# Bitcoin Node Odin - Project Instructions

## Build & Test

```bash
make              # Build deps + binary
make test         # Run all tests (12 packages, ~362)
make gui          # Build standalone remote dashboard (btcnode-gui)
make debug        # Build with debug symbols
odin build . -out:btcnode   # Build binary only
odin test <pkg>   # Test single package (crypto, wire, script, consensus, storage, chain, p2p, mempool, rpc, zmq, drivechain)
```

Note: Script tests have a known flaky secp256k1 thread-safety issue with parallel test threads. Use `-define:ODIN_TEST_THREADS=1` if tests crash.

## Running

```bash
./btcnode --network=signet --datadir=/tmp/btcnode-signet   # Sync signet
./btcnode --network=regtest --no-p2p                       # RPC-only regtest
./btcnode --rpcuser=user --rpcpassword=pass                # Explicit RPC auth
./btcnode --server=0                                       # Disable RPC server
./btcnode --help                                           # All options
./btcnode --gui                                            # In-process dashboard window
./btcnode --prune=2000                                     # Prune old block files to ~2GB
./btcnode --drivechain=track                               # BIP300/301 observation mode (enforce = reject violations)
./btcnode-gui --connect=127.0.0.1:8332 --cookie=<datadir>/.cookie  # Remote dashboard (make gui)
```

## Project Structure

- `crypto/` — (package btccrypto) SHA-256d (Bitcoin Core multi-backend FFI: SHA-NI/AVX2/SSE4.1/ARMv8/generic), RIPEMD-160, HASH160, secp256k1 bindings (verify+sign+ElligatorSwift), Merkle root (SHA256D64 SIMD), Base58Check, Bech32/Bech32m, WIF decode, SipHash-2-4
- `wire/` — Protocol types, CompactSize, tx/block serialization, message framing, compact block messages (BIP152), addrv2 messages (BIP155)
- `script/` — Script interpreter, opcodes, standard types, Taproot (BIP341/342)
- `consensus/` — Chain params, PoW, difficulty, block/tx validation, BIP325 signet
- `storage/` — LevelDB bindings + wrapper, flat files, block DB, index DB, UTXO DB (8 files)
- `chain/` — UTXO cache, block index with skip list, undo data, chain state, parallel verification, regtest miner, crash-recovery rollback, repairutxo sweep
- `p2p/` — Peer connections (outbound + inbound), sync manager, connection manager, address manager, BIP324 v2 transport, TCP listener (8 files)
- `mempool/` — Fee rates, relay policy, validation pipeline, RBF (BIP125), persistence, configurable limits (6 files)
- `rpc/` — JSON-RPC server, 73 methods (69/78 Core coverage + getnodestatus + 3 drivechain views), HTTP server
- `descriptor/` — output descriptors: checksum, BIP32 CKDpub (xpub-only, watch-only), parser (pkh/wpkh/sh/wsh/tr/multi/sortedmulti/addr/raw), script+address generation; feeds getdescriptorinfo/deriveaddresses/scantxoutset. Expected addresses cross-verified against an independent python EC impl
- `drivechain/` — BIP300/301: M1-M6 + BMM message codecs, D1/D2 state machine (apply/undo snapshots), enforce-mode validation (CTIP tracking, blinded m6id per CUSF enforcer), persistence codec (4 files + tests)
- `zmq/` — native ZMTP 3.0 PUB sockets (no libzmq): Core zmqpub* parity (hashblock/hashtx/rawblock/rawtx/sequence), verified against real libzmq
- `gui/` — raylib/raygui dashboard (in-process --gui and remote rendering; Cascadia Code embedded via #load)
- `guiapp/` — standalone `btcnode-gui` binary: polls getnodestatus RPC, renders the gui package remotely (--probe for one-shot CLI check, --tui for terminal rendering)
- `ncurses/` — minimal libncurses FFI bindings (system lib, secp256k1-binding style)
- `tui/` — terminal dashboard over Node_Status (`--tui`, SSH-friendly; ASCII-safe glyphs — non-wide system curses garbles multibyte). Wizard planned on same bindings (TUI_PLAN.md)
- `deps/` — libsecp256k1 (submodule), ripemd160 (vendored C), leveldb (vendored C++), sha256 (vendored from Bitcoin Core, multi-backend), static libs in deps/lib/

## Key Architecture

- **Storage**: Two LevelDB instances — `<datadir>/chainstate/` (UTXOs + meta tip) and `<datadir>/blocks/index/` (block index). Cache budget configurable via `--dbcache=<MB>` (default 450), split per Bitcoin Core's algorithm: index_db=min(total/8, 2MB), chainstate_db=min(remaining/2, 8MB), coins_cache=rest. 2MB write buffers, bloom filter, no Snappy. Blocks stored in flat files (`blk*.dat`, `rev*.dat`) under `<datadir>/blocks/` (legacy datadirs with files at the root are auto-detected by scanning for ANY prefix file — never key on file 0, pruning deletes it). blk and rev files roll over independently.
- **Crash consistency**: Flushes write chunked 16MB WriteBatches (Core dbbatchsize — one giant batch bloats the WAL and the next open replays it for minutes) with the tip marker LAST in its own synced batch. Recovery = undo-based rollback (Core ReplayBlocks style): force every key in (meta_tip, index_tip] to its pre-block value from the rev files — converges to the exact set @meta_tip regardless of which flush chunks landed — then replays forward from flat files. Rollback progress shows on the GUI loading screen + logs every 5k blocks. Stripped Valid_Chain flags are PERSISTED (in-memory-only stripping re-triggered full rollback every boot). If recovery cannot complete, the node refuses to start rather than run half-repaired. Undo locations persist in index records (v3, 117 bytes); undo records are framed in a single flat_file_write (two writes let file rollover strand header and payload in different files). Safety-net background flush every 25k blocks for ANY cache size bounds recovery depth (every 5k when budget < 1 GiB).
- **UTXO cache**: Write-back with Dirty/Fresh flags. Coin scripts live in a growing virtual arena owned by Coins_Cache — never individually freed; full eviction destroys+reinits the arena wholesale (returns memory to the OS; per-entry heap frees ratcheted RSS ~14GB/cycle). Budget checks use effective usage (arena bytes incl. dead + entry overhead). Budget-based flushing (or every 5000 blocks as safety net). Rollback on block validation failure. NOTE: derive the arena allocator at use time (`_script_alloc(cc)`) — Coins_Cache returns by value from init.
- **Sync**: Headers-first with batched WriteBatch, then multi-peer block download (getdata with Witness_Block, up to 64 blocks per peer). Bandwidth-based scoring allocates more slots to faster peers. Stall detection requeues blocks after 30s. Steady-state via BIP130 sendheaders + periodic getheaders. BIP152 compact block relay (send + receive) for bandwidth-efficient block propagation at tip. BIP133 feefilter + BIP339 wtxid relay for efficient tx propagation. BIP155 addr relay with address manager (sendaddrv2/addr/addrv2/getaddr, dedup, forwarding). BIP324 v2 encrypted transport with automatic v1 fallback, ON by default (`--v2transport=0` disables). `--proxy=<ip:port>` routes ALL outbound through SOCKS5 (async pre-phase before the transport; domain-CONNECT for .onion/seed hostnames — no local DNS; seeds contacted through the proxy; inbound auto-disabled; verified live: signet header sync through a local SOCKS5 server).
- **Sighash cache**: BIP143 + BIP341 intermediate hashes cached per-tx. Eagerly pre-computed before parallel dispatch so workers read immutable data.
- **Parallel script verification**: Two-phase `connect_block` — Phase 1 processes UTXOs sequentially, Phase 2 dispatches script checks to a persistent thread pool (`--par=N`, auto-detect by default). Serial fallback for small blocks (<16 inputs). Workers use growing virtual arenas (8MB initial block) from a mutex-protected pool — BIP342 tapscripts have no size cap, so fixed arenas are unsafe (mainnet 899747: 3.95MB single-input tx). Worker rule: capture locals, all cleanup BEFORE wait_group_done, done is the LAST statement (task memory is recycled the instant the dispatcher's wait returns).
- **Assumevalid**: Skip script verification below hardcoded heights (mainnet=880k, testnet3=2.1M, testnet4=200k, signet=267k). `--assumevalid=<height>` CLI flag (0=disable).
- **Pruning**: `--prune=<MB>` (min 550) deletes whole blk/rev files whose every block is below min(tip−288, last_flushed_height), oldest-first until under target, after each UTXO flush + once at startup. Index status (Has_Data/Has_Undo) batch-persisted BEFORE file deletion. Download queue must never include connected blocks (Valid_Chain) — pruned blocks lack Has_Data. Pruned nodes advertise NODE_NETWORK_LIMITED without NODE_NETWORK.
- **Sync progress/ETA**: measured in transactions (Core chainTxData style): Chain_Params carries an anchor (assumed_chain_tx/time/rate, mainnet anchored at block 956,927); verification_progress = tip chain_tx / extrapolated total; ETA from a 2-min throughput ring in the status tick.
- **Node status / GUI**: P2P thread publishes a Node_Status snapshot (1 Hz, mutex) — read by the in-process `--gui` dashboard and served by the `getnodestatus` RPC for the standalone `btcnode-gui` remote client (guiapp/). Closing the in-process window = graceful shutdown; the remote client is a pure viewer.
- **Txid optimization**: `deserialize_block_with_txids` computes txids from raw bytes during deserialization — non-witness: `sha256d(raw)`, witness: `sha256d_multi(version, body, locktime)`. Pre-computed txids passed through `connect_block` → `check_block`.
- **Outbound topology (p2p/topology.odin)**: 8 full-relay + 2 block-relay-only (fRelay=0, no tx/addr relay, skip feefilter/getaddr) + periodic feelers (probe-then-drop). anchors.dat persists block-relay peers on shutdown, redialed first at startup (deleted on read — crash loop can't re-pin). --maxuploadtarget MiB/day gates historical (>1wk) block serving to inbound once the rolling 24h budget is spent. getpeerinfo connection_type. Connection_Type enum on Peer; _count_outbound_peers counts Full_Relay+Manual only. GUARD: peer_start_connect dedups against already-connected addresses (addr manager returns randoms, multiple dial paths per tick) EXCEPT Manual. Bug fixed: getpeerinfo had a SECOND connection_type assignment hardcoding inbound/full-relay that overwrote the real conn_type.
- **Inbound connections**: TCP listener via `nbio.listen_tcp` + `nbio.accept_poly`. `--maxconnections=125` (default), `--listen=0|1`. Budget: 8 outbound + max(N-9,0) inbound. V2 responder mode with V1 fallback. 60s handshake timeout.
- **Thread model**: Main (setup+wait), RPC thread, P2P thread (`core:nbio` event loop — no per-peer threads), N script verification worker threads (`--par`).
- **RBF (BIP125)**: Full replace-by-fee with fullrbf=true default. `--mempoolfullrbf=0|1` CLI flag. Bandwidth fee uses configurable `--incrementalrelayfee`.
- **Mempool config**: `Mempool_Config` struct with 16 settings (Bitcoin Core parity). Memory-based size limiting (usage tracking, fee-based eviction, dynamic min_fee). Tx expiry (`--mempoolexpiry`). Ancestor/descendant chain limits (`--limitancestorcount/size`, `--limitdescendantcount/size`). Blocks-only mode (`--blocksonly`). Configurable relay/dust/incremental fees. 15 CLI flags + config file support.
- **Difficulty validation**: Header nBits verified against `get_next_work_required` (Bitcoin Core's GetNextWorkRequired). Testnet 20-minute minimum difficulty rule (`allow_min_difficulty`). BIP94 testnet4 retarget fix (`enforce_bip94`): uses first block of retarget period's nBits instead of parent's.
- **RPC**: 73 methods, 69/78 Core non-wallet coverage (getnodestatus feeds the GUI/remote dashboards) including getpeerinfo (18 fields), getmininginfo, getnetworkhashps, getnettotals, validateaddress, savemempool, ping, help, getmemoryinfo, getrpcinfo, logging, createrawtransaction, combinerawtransaction, signrawtransactionwithkey, getchaintxstats, gettxoutsetinfo, getmempoolancestors, getmempooldescendants, gettxoutproof, verifytxoutproof, signmessagewithprivkey, verifymessage. HTTP Basic Auth via `--rpcuser`/`--rpcpassword` or auto-generated `.cookie` file (Bitcoin Core compatible). `--server=0` disables RPC; `--rpcbind`/`--rpcallowip` (IPv4 CIDR allowlist enforced at accept; non-loopback bind refused without allowlist; 0.0.0.0 needs bind_set flag — zero value is a valid bind) open RPC to trusted LANs. Server is thread-per-connection with HTTP keep-alive and JSON-RPC batch (array) support; estimatesmartfee runs a Core CBlockPolicyEstimator port (3 decay horizons, fee_estimates.dat persistence, mempool-floor fallback until warmed). Electrum-server compatible: electrs v0.10 runs against btcnode (RPC + inbound P2P getheaders/getdata serving). Node-control RPCs (disconnect/precious/prune/setnetworkactive) route through a mutex-guarded control queue drained by the P2P tick. generatetoaddress/generateblock mine real regtest blocks through accept_block; getblocktemplate/submitblock/submitheader serve real miners (submitblock routes through the control queue and announces to peers + ZMQ); prioritisetransaction fee deltas apply in template selection. --repairutxo sweeps stale UTXO entries from block data.

- **Single-instance lock**: fcntl write-lock on `<datadir>/.lock`, held for the whole process lifetime; second instance on the same datadir refuses at startup (Core parity).
- **txindex** (`--txindex`): own LevelDB at <datadir>/txindex/, txid -> (block_hash, tx_index) + "best" marker; hooks in connect/disconnect (like filter_db); startup catch-up from best marker (walks back via coinbase probe if best left the active chain after an offline reorg); prune-incompatible (refused at startup); getrawtransaction historical path + getindexinfo. GOTCHA: tx_index_catchup free_alls the temp allocator per block — callers must not hold temp data across it.
- **Rolling UTXO stats**: coins_cache add/spend/restore maintain (count, amount); persisted under `"utxostats"` in the tip batch (atomic with tip, background flush snapshots at begin). BIP30 duplicate-coinbase overwrites handled (coinbase adds check for an existing live coin). Valid only from-genesis or when the key exists; --repairutxo invalidates. gettxoutsetinfo is instant when valid.
- **Drivechain (BIP300/301)**: `--drivechain=off|track|enforce` (default off = zero-cost, no hooks). `drivechain/` package holds D1 (256 slots) + D2 (bundles) as `drivechain.State` on `Chain_State`. `connect_block` step 4e calls `_dc_connect` (chain/drivechain_link.odin): apply coinbase M1-M4 + M5/M6 escrow txs + BMM checks; enforce violations return `.Drivechain_Violation` (UTXO changes rolled back, DC state restored from the pre-block snapshot). Undo = full pre-block snapshot in the INDEX LevelDB under `"dcu"+height(LE)` (value: block hash + snapshot), written only when the block changed the state; `disconnect_block` restores it (hash-checked against the entry). Persistence: `"dcstate"` key ([tip_hash][tip_height][snapshot]) written INSIDE the tip-marker batch of both flush paths (sync + background — background snapshots the blob at flush_begin since live state advances) → atomic with the meta tip, so recovery + pending-block replay reconverge it. `_dc_load` on startup: match → load; behind tip on active chain → coinbase replay catch-up from flat files; else reset-empty with warning (tracking starts at current tip; full history needs resync with the flag on). index_db_init skips non-32-byte keys. Blinded m6id = txid of tx with inputs cleared + output0 replaced by zero-value OP_RETURN 8-byte-BE fee (CUSF enforcer semantics, the BIP defers to it). Enforce = CUSF-style voluntary soft fork (self-fork risk documented in --help + docs/bips.md). RPCs: listsidechains, getsidechaininfo, listwithdrawalstatus.

## Build Notes

- **macOS deployment target**: Odin (via Homebrew LLVM) links with `-platform_version macos 16.0`. Apple clang on macOS 26+ forcibly overrides `-mmacosx-version-min` to the SDK version, producing objects with `minos 26.0` and causing linker warnings. The `deps/build.sh` script uses Homebrew LLVM clang instead of Apple clang to compile C/C++ deps with the matching deployment target. If you see `was built for newer 'macOS' version` warnings, rebuild deps: `rm -f deps/lib/*.a && ./deps/build.sh`.

## Conventions

- Package imports use relative paths: `import "../crypto"`
- Hash type: `wire.Hash256 :: crypto.Hash256` (aliased)
- Wire serialization: manual little-endian byte ops
- `or_return` for error propagation
- Tests use `context.temp_allocator` for temporary data
- Foreign C bindings follow `crypto/secp256k1.odin` pattern
- When a block fails validation during sync, write a regression test against the raw tx/block data (save hex to `script/testdata/`, fetch prevouts from mempool.space API). See `test_signet_250058_tx11_p2wpkh` as the pattern.
