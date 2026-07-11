# Reorg testing for the address index / Esplora wallet backend

> **STATUS: PLAN — run later.** Forcing a real chain reorg on regtest and
> verifying the scripthash index (and everything served on top of it — Esplora,
> BDK) converges to the new chain. This is the **fund-safety-critical** path: a
> stale `H`/`U` row after a reorg = a wrong wallet balance or a tx shown
> confirmed after it was reorged out.

## Why this matters (beyond the existing tests)

Reorg handling for the address index already has **unit coverage**:

- `chain/addrindex.odin` disconnect hook + `test_addr_index_spend_disconnect`
  (`chain/chain_test.odin`) — connects a spending block, disconnects it, asserts
  the exact H/U/T rows are removed and the spent UTXO is **restored** from the
  undo data.
- Chain-level reorg is covered by `test_reorg_heavier_branch_wins`,
  `test_reorg_equal_work_keeps_first_seen`, `test_reorg_invalid_branch_rolls_back`
  and the design in `docs/plans/reorg.md` (`activate_best_chain`).

**The gap this test closes:** an *end-to-end* reorg driven through the real
`activate_best_chain` machinery (disconnect down to the fork, reconnect the new
branch), observed through the **live Esplora API and a BDK wallet** — not just a
single `disconnect_block` call in a unit test. It proves the whole stack
(index → Esplora → BDK) reconverges, including a tx that un-confirms and then
re-confirms at a *different height*.

## The scenario (what makes it a real test)

The two competing branches must **differ in transactions that touch a
scripthash**, or the reorg proves nothing about the index. Concretely:

```
            ┌─ A1 ─ A2                (branch A: 2 blocks; contains TX_A)
  … ─ Nfork ┤
            └─ B1 ─ B2 ─ B3           (branch B: 3 blocks, heavier; no TX_A)
```

- `TX_A` spends a mature coin and pays **10 BTC to address X**, confirmed in `A1`.
- Branch B does **not** contain `TX_A` (or contains a conflicting spend of the
  same coin to a **different** address Y).
- Node-under-test starts on branch A (tip A2), then sees heavier branch B and
  **reorgs**: disconnect A2, A1 (index unwinds TX_A's rows, restores its inputs),
  connect B1..B3.

## Method 1 — two nodes over P2P (preferred; exercises the real path)

One host caveat: there's no P2P-port flag, so **only one node may listen** on the
regtest P2P port (18444). Give the *builder* the listener and have the
*node-under-test* dial out.

- **Node U (under test)** — the wallet backend, own datadir, `--rpcport=18443`,
  `--index-addresses --esplora=1`, `--listen=0` (dials out, never binds 18444).
- **Node B (builder)** — throwaway, own datadir, `--rpcport=18453`, `--listen=1`.

Flow:

1. **Common prefix.** Start both. Mine ~110 blocks on U to a BDK/wallet address so
   coins mature. Replicate the exact same chain to B so they share a fork point —
   easiest: connect them (`addnode 127.0.0.1:18444 add` on U), let B sync to U,
   then **disconnect** (`addnode … remove` / `disconnectnode`). Now both share
   blocks `0..Nfork`, isolated.
2. **Diverge (isolated).**
   - On **U**: build `TX_A` (10 BTC → address X), broadcast, mine `A1`, mine `A2`.
     Record: `getbestblockhash` (A2), address X history/balance via Esplora.
   - On **B**: mine `B1 B2 B3` (3 blocks, so branch B has more work). Do **not**
     include `TX_A`.
3. **Trigger the reorg.** Connect U to B (`addnode 127.0.0.1:18444 add` on U, **or**
   restart U with `--connect=127.0.0.1:18444`). U downloads B's headers, sees more
   work, and reorgs A2→A1→(fork)→B1→B2→B3. Watch U's log for
   `Reorg: N disconnected, M connected, fork at H`.
4. **Verify (see checklist).**

## Method 2 — single node via `submitblock` (fallback, no P2P timing)

If the P2P isolate/connect dance is fiddly, feed the competing branch by RPC:

- Node B (builder, `--no-p2p`, own datadir) mines branch B's blocks.
- Pull each block hex from B (`getblock <hash> 0`) and `submitblock` it to U in
  order. When branch B outweighs U's active chain, U reorgs on the last submit.
- Requires B to share U's fork prefix first (mirror `0..Nfork` the same way, or
  `submitblock` the common blocks into B). `preciousblock` can also force fork
  choice among branches already present in one node's index.

## Verification checklist (the point of the test)

After the reorg on node U, assert **all** of:

1. **Chain switched** — `getbestblockhash` == B3; `getchaintips` shows A2's branch
   as `valid-fork`/`headers-only`, B active.
2. **Esplora tip** — `GET /blocks/tip/hash` == B3 (index tracked the reorg).
3. **`TX_A` un-confirmed** — `GET /tx/TX_A/status` is now `confirmed:false`
   (resurrected to mempool) **or** 404 if dropped — NOT confirmed at A1's height.
4. **Address X history/UTXO reversed** — `GET /scripthash/X/utxo` no longer lists
   the 10-BTC output; `…/txs` no longer shows `TX_A` as confirmed. **This is the
   fund-safety assertion** — a stale U row here would be a phantom balance.
5. **Spent inputs restored** — the coin `TX_A` spent is unspent again (visible
   under its owner scripthash's `/utxo`).
6. **Conflicting-spend variant** — if B rewrote `TX_A`'s coin to address Y, then
   X's balance drops to 0 and Y's rises — both correct.
7. **Re-confirm at a new height** — mine one more block on U including `TX_A`
   again; `GET /tx/TX_A/status` shows `confirmed:true` at the **new** height, and
   X's UTXO reappears with the new `block_height`. (Confirms re-index on
   reconnect, not just delete.)
8. **BDK ground truth** — point the `test/bdk-esplora` harness at U before and
   after: `balance` must match the active chain at each step (no phantom funds).
9. **Consistency** — `gettxoutsetinfo` / the supply invariant hold; `addrindex`
   `best` marker == B3; a restart of U recovers to B3 (no re-scan surprises).

## Pass criteria

The address index, Esplora responses, and the BDK wallet all reflect **branch B
only** — zero residue from branch A — and a subsequent re-confirmation of `TX_A`
re-indexes it at its new height. Any lingering A-branch H/U row is a bug.

## Open questions to resolve when implementing

- Exact runtime connect mechanism on one host: `addnode add`/`remove` at runtime
  vs. restart-with-`--connect`. Confirm `addnode`/`disconnectnode` behavior and
  that a `--listen=0` node with P2P enabled will still dial out.
- Does forseti resurrect disconnected-block txs into the mempool
  (`docs/plans/reorg.md` step 5 calls it a "Phase 2 nicety")? If not,
  expectation #3 is "dropped (404)" rather than "back in mempool" — verify and
  pin the expectation.
- Deep reorg vs. the 288-block undo horizon — keep the fork shallow (a few
  blocks) so undo data is guaranteed present.

## Related

- Unit level: `chain/chain_test.odin` `test_addr_index_spend_disconnect`.
- Reorg engine: `chain/reorg.odin`, `docs/plans/reorg.md`.
- BDK harness to reuse for step 8: `test/bdk-esplora/`.
