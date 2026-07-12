# Eliminate connect-order flat-tip stalls (escalating multi-peer block racing)

> **STATUS: TICKET — not implemented.** Extend the existing tip-block racing so a
> single slow peer holding the connect-order-blocking block can't flatten the tip
> for up to 30s waiting on the stall-disconnect. Observed live during fresh
> mainnet IBD (2026-07-12): recurring "waiting for blocks — tip flat" banner and
> `Peer N stalling chain … no progress for 29s/30s — disconnecting` log lines,
> especially early while the peer set is still churning.

## Symptom

During IBD the tip goes flat in bursts and the GUI shows the "tip flat / catching
up" banner. The log shows the blocking peer being dropped only after ~30s:

```
Peer 151 stalling chain at height 8691 (no progress for 30s, block in-flight 47s) — disconnecting
```

Block download otherwise proceeds (tens of blk/s), so this is not a global stall
— it's *one* peer holding the single block that connect-order needs next, and the
tip can't advance past it until that peer is dropped and the block re-fetched.

## Why it happens (current mechanics)

Connect is strictly in-order (`connect_pending_blocks` advances the tip only over
consecutive heights). So the download's critical path is the **lowest-height
in-flight block above the tip** — the "window staller." Everything else in the
1024-wide window (`BLOCK_DOWNLOAD_WINDOW`) can arrive out of order and just buffers
in RAM; only that one block gates tip progress.

Two mechanisms interact today (`p2p/sync.odin`):

1. **Stall-disconnect** (`sync_check_stalls`, ~L679): finds the lowest in-flight
   block within 64 of tip; if its owner has held it past
   `BLOCK_STALL_TIMEOUT_DEFAULT` (10s) it disconnects that peer — but **rate-limited
   to one disconnect per 30s** (`last_disconnect`). The rate limit is deliberate:
   mass-evicting during early IBD strands the node on a thin peer pool. So clearing
   a run of slow peers happens one-every-30s, which is exactly the flat-tip cadence.

2. **Tip-block racing** (~L758, `TIP_BLOCK_RACE_SECS` = 3): for in-flight blocks
   **within 16 of tip** that have waited >3s, send a *duplicate* getdata to one
   other peer (`best_racer` = highest `blocks_delivered`). First response wins;
   the duplicate is a no-op once `Has_Data` is set. This is meant to route around a
   slow owner *without* waiting for the disconnect.

The racer is the right idea but underpowered in exactly the situation that
produces the banner:

- **Single racer.** It duplicates to one peer (the best deliverer). During early
  churn the "best" peer has barely delivered anything and may itself be slow or
  congested, so the duplicate lands on another slow path and the block still
  doesn't arrive until the 30s disconnect fires.
- **No escalation.** Every 1s tick it re-sends to the *same* `best_racer`; it never
  fans out to a second or third peer as the wait grows.
- **Ownership unchanged.** Racing doesn't touch `blocks_in_flight[hash]` or
  `block_request_time[hash]`, so the stall-disconnect clock keeps running against
  the original owner regardless of the race — the 30s path still governs recovery
  when the single race fails.
- **Coverage vs the staller.** The racer caps at tip+16 while the stall detector
  looks to tip+64. The connect-order blocker is normally within a few of tip, so
  tip+16 is usually enough — but the two thresholds should be reconciled so the
  racer is guaranteed to cover whatever the stall detector considers the blocker.

## Proposal

Make the **connect-order blocker** recover in seconds via escalating, bounded,
multi-peer racing — so the 30s stall-disconnect becomes the rare fallback, not the
normal recovery path. Keep the anti-churn disconnect throttle untouched.

1. **Identify the one blocker explicitly.** Reuse the stall detector's "lowest
   in-flight block above tip" as *the* race target (single hash), rather than the
   racer's separate tip+16 scan. One clear critical-path block, one policy.

2. **Escalating fan-out with backoff.** Track per-block race attempts + last-race
   time. Race schedule for the blocker (tunable):
   - t ≥ 3s in-flight: duplicate to 1 fresh peer (not the owner, not a prior racer).
   - t ≥ 6s: duplicate to a 2nd distinct peer.
   - t ≥ 10s: duplicate to a 3rd.
   Cap at e.g. 3 concurrent racers so a genuinely-rare block still gets breadth
   without a broadcast storm. Pick racers by delivered-rate but **exclude peers
   already carrying this hash** and prefer ones not currently at their in-flight
   limit.

3. **Prefer fresh, capable peers over "most delivered."** Early in IBD, rank
   candidate racers by recent per-peer delivery *rate* (already tracked in
   `Peer_Sync_State`) with a small bonus for peers below their in-flight cap, so
   the duplicate goes to a peer that can actually answer now.

4. **(Optional) re-anchor the request clock on race.** When we escalate, optionally
   reset `block_request_time[hash]` to now so the stall-*disconnect* doesn't punish
   the original owner while a race is actively in progress — decouples "route around
   this block" from "this peer is bad." Leave the per-30s disconnect throttle as-is.

5. **Bound duplicate bandwidth.** Only ever race the *single* connect-order blocker
   (not a set), cap concurrent racers (≤3), and never race a block already
   `Has_Data`/`buffered`. Worst case extra traffic ≈ a couple of duplicate block
   bodies for the one gating block — negligible vs a 30s tip stall.

## Correctness / safety

- **No new correctness surface.** Duplicate getdata is already handled: the second
  copy is dropped by the `Has_Data in status || entry.buffered` check in the
  request builder and the block-arrival path (`sync.odin` ~L283, ~L556). This ticket
  only changes *how many* duplicates and *to whom*, not how arrivals are processed.
- **Don't loosen anti-churn.** The 1-disconnect-per-30s throttle and the thin-pool
  protection stay exactly as they are — this reduces reliance on disconnects, it
  doesn't speed them up. (See the "dropping unhealthy peers strands the node on
  thin peer pools" failure mode.)
- **Window/cursor untouched.** `download_cursor` is monotonic and the 1024 window
  gate is unchanged; racing never requests a block outside the window.
- **Hot path.** `sync_check_stalls` runs once per second (`STALL_CHECK_INTERVAL_SECS`)
  on the P2P thread; keep the added per-tick work O(in-flight-near-tip) as today.

## Testing

- **Regtest slow-peer harness:** two peers; one is told to withhold the
  connect-order block for N seconds. Assert the tip advances within ~racing-latency
  (single-digit seconds) **without** a disconnect firing — i.e., the raced peer
  delivered it. Today this test would wait ~30s for the disconnect.
- **Escalation:** withhold from the first racer too; assert a 2nd/3rd racer is tried
  on schedule and the tip recovers before the 30s disconnect.
- **No-storm bound:** assert at most `MAX_RACERS` duplicate getdata per gating block
  and none once `Has_Data` is set.
- **Regression:** the existing download-window bound test
  (`test_download_window_bounds_frontier`) must still pass; add a check that racing
  never advances `download_cursor` or requests beyond `window_max_height`.

## Touch points

- `p2p/sync.odin`: `sync_check_stalls` (L667) — merge the racer's target with the
  stall detector's blocker; add escalation state + fan-out. The racer block at
  ~L758 is replaced/subsumed.
- `p2p/types.odin`: constants `TIP_BLOCK_RACE_SECS` (L83), add `MAX_RACERS`, a
  second/third race threshold; possibly per-block race bookkeeping on the
  `Sync_Manager` (a small `map[Hash256]struct{attempts:int, last_race:i64}` or fold
  into existing in-flight tracking).

## Priority

Cosmetic-to-mild throughput impact — the sync still completes; this removes the
flat-tip pauses and shaves the wasted seconds spent gated on one slow peer,
biggest during the early peer-churn phase. Do it **after** the RocksDB fresh-sync
numbers are in; it touches the sync hot path so it shouldn't land mid-measurement.

## References

- Current mechanics: `p2p/sync.odin` `sync_check_stalls` (stall-disconnect + racer),
  request builder (~L505–575), block-arrival (~L280–350).
- Constants: `p2p/types.odin` L70–84.
- Prior art: Bitcoin Core requests the tip-critical block from a second peer and
  has a per-block download timeout; this ticket brings the same "route around the
  straggler" behavior with bounded escalation.
- Related failure mode to preserve: memory `sync-wedge-shutdown-bug` (thin peer
  pools).
