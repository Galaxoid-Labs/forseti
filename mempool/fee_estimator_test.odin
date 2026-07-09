package mempool

import "core:fmt"
import "core:os"
import "core:math/rand"
import "core:testing"

_mk_txid :: proc(seed: u64) -> Hash256 {
	h: Hash256
	for i in 0 ..< 8 {
		h[i] = byte(seed >> uint(i * 8))
	}
	h[31] = 0xfe
	return h
}

@(test)
test_estimator_buckets :: proc(t: ^testing.T) {
	est: Fee_Estimator
	estimator_init(&est)
	defer estimator_destroy(&est)

	// Monotone lookup; everything at/below min lands in bucket 0.
	testing.expect_value(t, _bucket_index(&est, 500), 0)
	testing.expect_value(t, _bucket_index(&est, 1000), 0)
	b1 := _bucket_index(&est, 5000)
	b2 := _bucket_index(&est, 50_000)
	testing.expect(t, b1 > 0 && b2 > b1, "buckets ordered")
	testing.expect(t, est.buckets[b1] >= 5000 && est.buckets[b1] / FEE_SPACING < 5000, "tight bucket")
	// Anything huge lands in the infinity bucket (the last one).
	testing.expect_value(t, _bucket_index(&est, 2.0e7), len(est.buckets) - 1)
}

// Feed a synthetic history: high-fee txs confirm next block, low-fee txs
// take ~4 blocks. The 1-2 block estimate must come out well above the
// 12-block estimate. (Core's smart-fee rule takes the max with the
// HALF-target estimate at a 60% threshold, so the slow lane must confirm
// within half of the queried target to be creditable at that target.)
@(test)
test_estimator_learns_feerates :: proc(t: ^testing.T) {
	est: Fee_Estimator
	estimator_init(&est)
	defer estimator_destroy(&est)
	est.best_height = 100

	seed := u64(1)
	pending_slow := make([dynamic]Hash256, context.temp_allocator)
	pending_slow_h := make([dynamic]int, context.temp_allocator)

	for h in 101 ..= 400 {
		confirmed := make([dynamic]Hash256, context.temp_allocator)

		// Fast lane: 5 txs at ~50k sat/kvB tracked at the current tip,
		// confirmed in the next block.
		fast := make([dynamic]Hash256, context.temp_allocator)
		for i in 0 ..< 5 {
			txid := _mk_txid(seed)
			seed += 1
			estimator_process_tx(&est, txid, est.best_height, 50_000)
			append(&fast, txid)
		}
		// Slow lane: 5 txs at ~1.5k sat/kvB, confirmed 4 blocks later.
		for i in 0 ..< 5 {
			txid := _mk_txid(seed)
			seed += 1
			estimator_process_tx(&est, txid, est.best_height, 1500)
			append(&pending_slow, txid)
			append(&pending_slow_h, est.best_height)
		}

		// Slow txs whose 4 blocks have elapsed confirm now.
		for len(pending_slow) > 0 && h - pending_slow_h[0] >= 4 {
			append(&confirmed, pending_slow[0])
			ordered_remove(&pending_slow, 0)
			ordered_remove(&pending_slow_h, 0)
		}
		append(&confirmed, ..fast[:])

		estimator_process_block(&est, h, confirmed[:])
	}

	fast_est, fast_ok := estimator_smart_fee(&est, 2)
	slow_est, slow_ok := estimator_smart_fee(&est, 12)
	testing.expect(t, fast_ok, "2-block estimate available")
	testing.expect(t, slow_ok, "12-block estimate available")
	testing.expect(t, fast_est > 20_000, fmt.tprintf("2-block estimate tracks the fast lane, got %d", fast_est))
	testing.expect(t, slow_est < fast_est, fmt.tprintf("12-block (%d) below 2-block (%d)", slow_est, fast_est))
	testing.expect(t, slow_est < 5000, fmt.tprintf("12-block estimate near the slow lane, got %d", slow_est))

	// Conservative >= economical at the same target.
	cons, _ := estimator_smart_fee(&est, 12, conservative = true)
	testing.expect(t, cons >= slow_est, "conservative not below economical")
}

// Low-fee txs that never confirm must drag down that bucket's success rate:
// the estimator should refuse to credit the low bucket for fast confirmation.
@(test)
test_estimator_failures_matter :: proc(t: ^testing.T) {
	est: Fee_Estimator
	estimator_init(&est)
	defer estimator_destroy(&est)
	est.best_height = 100

	seed := u64(1)
	evict_q := make([dynamic]Hash256, context.temp_allocator)
	for h in 101 ..= 300 {
		confirmed := make([dynamic]Hash256, context.temp_allocator)
		// 3 mid-fee txs confirm next block.
		for i in 0 ..< 3 {
			txid := _mk_txid(seed)
			seed += 1
			estimator_process_tx(&est, txid, est.best_height, 10_000)
			append(&confirmed, txid)
		}
		// 3 low-fee txs never confirm; evict them after ~20 blocks.
		txid := _mk_txid(seed)
		seed += 1
		estimator_process_tx(&est, txid, est.best_height, 1200)
		append(&evict_q, txid)
		if len(evict_q) > 20 {
			estimator_remove_tx(&est, evict_q[0]) // failure accounting
			ordered_remove(&evict_q, 0)
		}
		estimator_process_block(&est, h, confirmed[:])
	}

	est2, ok2 := estimator_smart_fee(&est, 2)
	testing.expect(t, ok2, "2-block estimate available")
	testing.expect(t, est2 >= 8000, fmt.tprintf("failing low bucket must not win: got %d", est2))
}

@(test)
test_estimator_persistence_roundtrip :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/forseti_feeest_%x", rand.uint64())
	os.make_directory(dir)
	defer {
		os.remove(fmt.tprintf("%s/fee_estimates.dat", dir))
		os.remove(dir)
	}

	est: Fee_Estimator
	estimator_init(&est)
	defer estimator_destroy(&est)
	est.best_height = 50

	seed := u64(9)
	for h in 51 ..= 120 {
		confirmed := make([dynamic]Hash256, context.temp_allocator)
		for i in 0 ..< 4 {
			txid := _mk_txid(seed)
			seed += 1
			estimator_process_tx(&est, txid, est.best_height, 25_000)
			append(&confirmed, txid)
		}
		estimator_process_block(&est, h, confirmed[:])
	}
	want, want_ok := estimator_smart_fee(&est, 2)
	testing.expect(t, want_ok, "estimate before save")
	testing.expect(t, estimator_save(&est, dir), "save succeeds")

	est2: Fee_Estimator
	estimator_init(&est2)
	defer estimator_destroy(&est2)
	testing.expect(t, estimator_load(&est2, dir), "load succeeds")
	got, got_ok := estimator_smart_fee(&est2, 2)
	testing.expect(t, got_ok, "estimate after load")
	testing.expect_value(t, got, want)
}
