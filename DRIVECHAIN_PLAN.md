# Drivechain (BIP300/301) Plan for bitcoin-node-odin

## Goal

Add opt-in BIP300 (Hashrate Escrows) and BIP301 (Blind Merged Mining) support
behind a `--drivechain=off|track|enforce` CLI flag (default **off**). `off` is
byte-for-byte today's behavior. `track` parses the six BIP300 messages and
maintains the sidechain/withdrawal databases without rejecting anything —
zero-risk observation mode. `enforce` additionally applies OP_DRIVECHAIN
semantics and rejects violating blocks — natively, with no sidecar process.

## Background / Status (as of July 2026)

- Neither BIP is activated in Bitcoin Core. Luke-jr's consensus PR
  ([bitcoin/bitcoin#28311](https://github.com/bitcoin/bitcoin/pull/28311)) stalled.
- LayerTwo Labs ships a **CUSF enforcer** ("Core Untouched Soft Fork",
  [bip300301_enforcer](https://github.com/LayerTwo-Labs/bip300301_enforcer/)) — a
  sidecar that pairs with unmodified Bitcoin Core over RPC+ZMQ and enforces the
  rules for nodes that opt in. No L1 code changes; enforcement is voluntary.
- Sztorc has announced an **"eCash" hard fork at block 964,000 (~August 2026)**
  activating BIP300/301 with a 1:1 BTC split, cancelled only if Bitcoin activates
  first. Whatever happens there, a native toggle in btcnode covers both worlds:
  CUSF-style voluntary enforcement today, and ready-made validation if any chain
  activates the rules for real.
- Because btcnode *is* the full node, we implement the rules in-process — strictly
  less machinery than the enforcer (no ZMQ, no gRPC, no second process).

**The opt-in caveat (must go in `--help`):** enabling enforcement while the rest of
the network doesn't enforce means a block violating BIP300 rules would be rejected
by us but accepted by everyone else → we fork ourselves off. That is inherent to
CUSF-style activation, not a btcnode defect. Default-off, clearly documented.

---

## Consensus Rules Summary

### BIP300 — the six messages

| Msg | Meaning | Where | Format |
|-----|---------|-------|--------|
| M1 | Propose sidechain | coinbase OP_RETURN | `6a` + header `D5E0C4AF` + nSidechain(1) + nVersion(4) + title + description + hashID1(32) + hashID2(20) |
| M2 | ACK proposal | coinbase OP_RETURN | `6a` + header `D6E1C5BF` + sha256d(sidechain serialization)(32) |
| M3 | Propose withdrawal bundle | coinbase OP_RETURN | `6a` + header `D45AA943` + bundleHash(32) + nSidechain(1) |
| M4 | ACK bundles | coinbase OP_RETURN | `6a` + header `D77D1776` + version(1) + upvote vector |
| M5 | Deposit (main→side) | regular tx | spends CTIP, one OP_DRIVECHAIN output, escrow amount must increase |
| M6 | Withdrawal (side→main) | regular tx | spends CTIP; output0 = new CTIP (OP_DRIVECHAIN), output1 = 10-byte OP_RETURN with 8-byte fee amount; blinded hash must match an approved bundle |

Rules: max one M1/M2/M3 per sidechain per block; a bundle hash may appear in D2
only once; every escrow spend produces exactly one replacement CTIP UTXO.

### Databases

- **D1 — sidechain list** (256 slots): escrow number(u8), version(i32), name,
  description, hash1(u256), hash2(u160), active(bool), activation status
  (age, fail count), CTIP txid(u256) + vout(i32).
- **D2 — withdrawal list**: sidechain number(u8), bundle hash(u256),
  ACK count(u16), blocks remaining(u16).

### Thresholds

- Sidechain activation (new slot): 2,016-block window, fails at 1,008 fail-blocks.
- Slot override (replace existing sidechain): 26,300-block window, 13,150 fails.
- Withdrawal bundle: starts ACKs=1, blocksRemaining=26,299; M4 upvote = +1,
  every non-upvoted bundle = −1; approved at **13,150 ACKs**; pruned when
  `13,150 − ACKs > blocksRemaining`. M4 virtual votes: 0xFF abstain, 0xFE alarm
  (downvote everything).

### OP_DRIVECHAIN

Redefines `OP_NOP5` (0xb4). Valid only when the entire scriptPubKey is exactly:

```
0xb4 <1-byte push: sidechain number> OP_TRUE     (4 bytes total)
```

Legacy nodes see anyone-can-spend → soft-fork compatible. In `enforce` mode,
spends of OP_DRIVECHAIN outputs must be valid M5 or M6.

### BIP301 — Blind Merged Mining

- **BMM Accept** (coinbase OP_RETURN): `6a` + header `D1617368` + nSidechain(1) + h*(32).
- **BMM Request** (regular tx OP_RETURN): `6a` + header `00bf00` + nSidechain(1) +
  h*(32) + prevMainBlock(32).
- Rules: each request must match an accept; max one request per sidechain per
  block; prevMainBlock must equal the actual previous block hash.

---

## Design Mapped to This Codebase

### New package: `drivechain/`

Keeps BIP300/301 logic out of `consensus/` core. Contents:

- `messages.odin` — parse/serialize M1–M4, BMM Accept/Request from OP_RETURN
  payloads (fixed 4-byte headers make detection cheap; reuse wire reader).
- `state.odin` — `Drivechain_State` holding D1 (fixed `[256]Sidechain_Slot`) and
  D2 (dynamic bundle list), plus per-block apply/undo:
  `drivechain_connect_block(state, block, height) -> (undo, err)` and
  `drivechain_disconnect_block(state, undo)`.
- `validate.odin` — M5/M6 transaction validation against D1/D2 (CTIP tracking,
  amount rules, bundle-hash matching), BMM request/accept matching.

### Storage (`storage/`)

- D1/D2 persisted in the **chainstate LevelDB** under a new key prefix
  (`dc:s:<n>` slots, `dc:w:<hash>` bundles, `dc:meta`), written in the **same
  WriteBatch** as UTXO flushes → crash consistency inherited for free.
- Undo data: append drivechain undo records to the existing per-block `rev*.dat`
  stream (extend `chain/undo.odin` serialization with a versioned optional
  section so old rev files still parse).

### Chain (`chain/`)

- `chainstate.odin` `connect_block`: after tx validation, when enabled, call
  `drivechain_connect_block`. Failure = block invalid (same path as `.Bad_Script`).
- Reorg path calls `drivechain_disconnect_block` with the undo records.
- In-memory `Drivechain_State` lives on `Chain_State`, flushed with the coins
  cache (it is tiny — ≤256 slots + pending bundles — so it can also be written
  every block without cost; decide during implementation).

### Script (`script/`)

- New `Verify_Flag.Drivechain`. In the interpreter, `OP_NOP5` with the flag set
  and the exact 4-byte script form → drivechain semantics; any other use of
  0xb4 with the flag set remains a NOP (per BIP300, only the exact form changes).
- Spend-side enforcement (M5/M6) happens in `drivechain/validate.odin` at the tx
  level, not inside the script interpreter — mirrors how BIP300 is specified.

### Consensus (`consensus/`)

- `get_script_flags`: add `.Drivechain` **only when the CLI flag is on** (no
  height gating on mainnet today; if a chain ever buries an activation height we
  add it to `Chain_Params` like `p2sh_height`).

### Main / config

- `--drivechain=off|track|enforce` CLI flag + `drivechain=` config file key,
  default `off`. Internally an enum `Drivechain_Mode :: enum {Off, Track, Enforce}`
  on the config; `track` gates state tracking, `enforce` additionally gates the
  script flag and block rejection.
- `--help` text carries the CUSF warning (see caveat above) on the `enforce` mode.

### RPC (optional, phase 2)

- `listsidechains`, `getsidechaininfo <n>`, `listwithdrawalstatus <n>` — read-only
  views of D1/D2 for debugging and for sidechain software polling us the way the
  enforcer's gRPC ValidatorService is polled. btcnode does not mine, so the
  miner-side messages (generating M2/M4/BMM Accepts) are out of scope.

---

## Phases

1. **Phase 1 — parse + track (no enforcement).** Build `drivechain/` package,
   parse M1–M4/BMM from connected blocks, maintain D1/D2 + undo, add RPC
   read-only views. Runs safely with the flag on against today's mainnet because
   nothing is rejected. This is the "watch mode" that proves state tracking
   against real chain data.
2. **Phase 2 — full enforcement.** M5/M6 validation, OP_DRIVECHAIN script flag,
   block rejection on rule violations — everything behind `enforce` mode. `track`
   remains available long-term as the safe observation mode.
3. **Phase 3 (only if wanted) — sidechain-facing service.** Serve BMM/deposit
   queries to sidechain nodes (equivalent of enforcer's gRPC surface) via our
   JSON-RPC.

## Testing

- Unit tests per message codec (byte vectors straight from the BIP).
- State-machine tests: ACK counting, bundle expiry (`13,150 − ACKs > remaining`),
  slot activation/failure windows, M4 upvote-vector application, one-per-block
  rules — all pure-data tests in the `drivechain` package.
- Regression-style tests with real coinbase hexes once any test network carries
  BIP300 traffic (LayerTwo's signet-like test chains are candidates; same
  save-hex-to-testdata pattern used in `script/testdata/`).
- Reorg test: connect N blocks with M1–M4 traffic, disconnect, verify D1/D2
  byte-identical to before.

## Open Questions

1. ~~Track-vs-enforce as one flag or two?~~ **Decided: `--drivechain=off|track|enforce`.**
   Track mode is genuinely useful and zero-risk.
2. If the August block-964,000 fork happens and btcnode should *follow* that
   chain, enforcement flag alone is not enough — that fork reportedly changes
   more than BIP300 (coin split). Out of scope until the fork ships something
   concrete to validate against.
3. D2 upper bound: bundles are per-sidechain-slot and pruned aggressively by the
   ACK math, so D2 stays small; confirm worst-case growth during implementation.

## References

- [BIP300 spec](https://github.com/bitcoin/bips/blob/master/bip-0300.mediawiki)
- [BIP301 spec](https://github.com/bitcoin/bips/blob/master/bip-0301.mediawiki)
- [drivechain.info](https://drivechain.info/)
- [LayerTwo-Labs/bip300301_enforcer](https://github.com/LayerTwo-Labs/bip300301_enforcer/)
- [Bitcoin Core PR #28311 (stalled)](https://github.com/bitcoin/bitcoin/pull/28311)
