# Chain Reorganization Plan for bitcoin-node-odin

## Problem

The node cannot reorganize. The primitives exist — undo data per block,
`disconnect_block` (zero callers), all fork headers retained in the index —
but there is no fork choice by work and no orchestration. Today a competing
branch that overtakes our tip gets stored and never connected: the node
wedges at the stale tip. Mainnet produces a stale tip roughly weekly.

## Design (Bitcoin Core shaped)

1. **Cumulative chainwork** — `chain_work: u256` per index entry:
   `work(header) = 2^256 / (target(nBits) + 1)`, accumulated from parent.
   Persisted in index records with the same backward-compatible append used
   for `num_tx`. Recomputed for pre-upgrade records on load.
2. **Work-based fork choice** — everywhere "best" currently means highest
   height (best_header tracking, header sync targets) it becomes most
   cumulative work, ties broken first-seen.
3. **`activate_best_chain(cs)`** — after any block connect/accept: if the
   most-work *connectable* chain's tip ≠ active tip:
   - find fork point (walk prev pointers from both tips),
   - `disconnect_block` active blocks down to the fork (undo application,
     newest first), pushing their txs aside,
   - connect branch blocks upward with full validation,
   - on branch-block failure: mark branch `Failed` (+ descendants),
     reconnect the original chain (its blocks + undo still on disk),
   - update `active_chain`, chain_tx, meta tip flush at the end.
4. **Sync/P2P integration** — header acceptance recomputes best-work tip;
   the download queue targets the best-work chain's missing blocks;
   `connect_pending_blocks` and block arrival call `activate_best_chain`
   instead of assuming parent == tip.
5. **Mempool** — disconnected txs are resurrected via `mempool_add`
   (best effort; conflicts silently dropped). Phase 2 nicety.
6. **Pruning interplay** — 288-block undo horizon already enforced. A reorg
   deeper than the prune horizon is fatal-by-design (same as Core).

## Constraints

- `disconnect_block` order: strictly newest-first, one block at a time,
  each verified against its undo record.
- Every state change in a reorg must flow through the same WriteBatch
  crash-consistency path as normal connects; a crash mid-reorg must recover
  to a consistent chain (recovery already replays from the flush point —
  the reorg only moves meta tip after completing).
- GUI/status: reorg surfaces in the log (`Reorg: N blocks disconnected,
  M connected, fork at H`) and bumps a counter in Node_Status.

## Tests (regtest, all local)

- Two branches, heavier wins: build A(3 blocks), competing B(4) → reorg to B.
- Equal work: first-seen chain stays active.
- Deep-ish reorg: 5-block disconnect/reconnect, UTXO set equality check
  against a straight-line sync of the same final chain.
- Invalid branch mid-reorg: B(4) with an invalid 3rd block → node rolls
  back to A, marks B failed, stays consistent.
- Mempool resurrection: tx in disconnected block reappears in mempool.
- Chainwork: known-vector unit tests for work-from-nBits math.
