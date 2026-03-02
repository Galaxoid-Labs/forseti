package mempool

import "../chain"
import "../consensus"
import "../wire"
import "core:fmt"
import "core:testing"

@(test)
test_mempool_save_load_roundtrip :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "persist_rt", 103)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	subsidy := consensus.get_block_subsidy(0, &consensus.REGTEST_PARAMS)

	// Add 2 txs to mempool.
	for i in 0 ..< 2 {
		cb_txid := _get_coinbase_txid(i)
		outpoint := wire.Outpoint{hash = cb_txid, index = 0}
		tx := _make_spend_tx(outpoint, subsidy, subsidy - i64(1000 * (i + 1)))

		err := mempool_add(mp, &tx)
		testing.expect(t, err == .None, fmt.tprintf("add tx %d: %v", i, err))
	}
	testing.expect_value(t, mempool_count(mp), 2)

	// Collect txids and fees before save.
	saved_fees := make(map[Hash256]i64, 4, context.temp_allocator)
	saved_times := make(map[Hash256]i64, 4, context.temp_allocator)
	for txid, entry in mp.entries {
		saved_fees[txid] = entry.fee
		saved_times[txid] = entry.time
	}

	// Save mempool.
	ok := mempool_save(mp, dir)
	testing.expect(t, ok, "mempool_save should succeed")

	// Create a fresh mempool on the same chain state and load.
	mp2 := new(Mempool)
	mempool_init(mp2, cs, params)
	defer {
		mempool_destroy(mp2)
		free(mp2)
	}

	loaded, skipped := mempool_load(mp2, dir)
	testing.expect_value(t, loaded, 2)
	testing.expect_value(t, skipped, 0)
	testing.expect_value(t, mempool_count(mp2), 2)

	// Verify all txids, fees and timestamps match.
	for txid, fee in saved_fees {
		entry, found := mempool_get(mp2, txid)
		testing.expect(t, found, fmt.tprintf("txid should be in loaded mempool"))
		if found {
			testing.expect(t, entry.fee == fee, fmt.tprintf("fee mismatch: got %d, want %d", entry.fee, fee))
			expected_time := saved_times[txid]
			testing.expect(t, entry.time == expected_time, fmt.tprintf("time mismatch: got %d, want %d", entry.time, expected_time))
		}
	}
}

@(test)
test_mempool_load_nonexistent :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "persist_nofile", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	// No mempool.dat exists — should return (0, 0).
	loaded, skipped := mempool_load(mp, dir)
	testing.expect_value(t, loaded, 0)
	testing.expect_value(t, skipped, 0)
	testing.expect_value(t, mempool_count(mp), 0)
}

@(test)
test_mempool_save_empty :: proc(t: ^testing.T) {
	mp, cs, params, dir := _make_test_mempool(t, "persist_empty", 101)
	defer {
		mempool_destroy(mp)
		free(mp)
		chain.chain_state_destroy(cs)
		free(cs)
		free(params)
		_remove_test_dir(dir)
	}

	// Save empty mempool.
	ok := mempool_save(mp, dir)
	testing.expect(t, ok, "mempool_save should succeed for empty mempool")

	// Load into fresh mempool.
	mp2 := new(Mempool)
	mempool_init(mp2, cs, params)
	defer {
		mempool_destroy(mp2)
		free(mp2)
	}

	loaded, skipped := mempool_load(mp2, dir)
	testing.expect_value(t, loaded, 0)
	testing.expect_value(t, skipped, 0)
	testing.expect_value(t, mempool_count(mp2), 0)
}
