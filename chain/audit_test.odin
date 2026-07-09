package chain

import "../consensus"
import "../storage"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:testing"

foreign import leveldb "../deps/lib/libleveldb.a"

// Ground-truth audit of a REAL datadir's chainstate: scans the DB, decodes each
// UTXO's height + is_coinbase + amount, and buckets the total amount by coin
// height to localize corruption. Env-gated so `make test` skips it.
//   BTCNODE_AUDIT_DIR=/path/to/datadir odin test chain -define:ODIN_TEST_NAMES=chain.test_audit_datadir
@(test)
test_audit_datadir :: proc(t: ^testing.T) {
	dir, has := os.lookup_env("BTCNODE_AUDIT_DIR", context.temp_allocator)
	if !has || dir == "" {
		return
	}

	params := consensus.MAINNET_PARAMS
	cs: Chain_State
	err := chain_state_init(&cs, dir, &params)
	testing.expect_value(t, err, Chain_Error.None)
	defer chain_state_destroy(&cs)
	_, height := chain_tip(&cs)

	// Height buckets of 100k, plus a fine split around the recovery range.
	NB :: 12
	bucket_amt: [NB]i64 // 0-100k,100-200k,...,900k-1M, 1M+
	bucket_cnt: [NB]i64
	// Fine buckets for the recovery-replayed window [770k, 810k) in 5k steps.
	FB :: 8
	fine_amt: [FB]i64
	fine_cnt: [FB]i64
	max_amt: i64 = 0
	over_50btc_cnt: i64 = 0
	over_50btc_amt: i64 = 0
	total_amt: i64 = 0
	total_cnt: i64 = 0
	// Coins above a cutoff (crash-recovery straggler check).
	cutoff_s, _ := os.lookup_env("BTCNODE_AUDIT_CUTOFF", context.temp_allocator)
	cutoff := -1
	if cutoff_s != "" { cutoff, _ = strconv.parse_int(cutoff_s) }
	above_cnt: i64 = 0
	min_above := max(int)
	above_heights: [12]int  // first few offending heights
	above_n := 0

	iter := leveldb_create_iterator(cs.utxo_db.store.chainstate_db, cs.utxo_db.store.read_opts)
	defer leveldb_iter_destroy(iter)
	leveldb_iter_seek_to_first(iter)
	for leveldb_iter_valid(iter) != 0 {
		klen: c.size_t
		_ = leveldb_iter_key(iter, &klen)
		if klen == 36 {
			vlen: c.size_t
			vptr := leveldb_iter_value(iter, &vlen)
			if vptr != nil && vlen >= 13 {
				val := ([^]byte)(vptr)[:vlen]
				h := u32(val[0]) | u32(val[1]) << 8 | u32(val[2]) << 16 | u32(val[3]) << 24
				amt_u := u64(val[5]) | u64(val[6]) << 8 | u64(val[7]) << 16 | u64(val[8]) << 24 |
				         u64(val[9]) << 32 | u64(val[10]) << 40 | u64(val[11]) << 48 | u64(val[12]) << 56
				amt := transmute(i64)amt_u
				total_amt += amt
				total_cnt += 1
				if amt > max_amt { max_amt = amt }
				if amt > 50_0000_0000 { over_50btc_cnt += 1; over_50btc_amt += amt }
				if cutoff >= 0 && int(h) > cutoff {
					above_cnt += 1
					if int(h) < min_above { min_above = int(h) }
					if above_n < len(above_heights) { above_heights[above_n] = int(h); above_n += 1 }
				}
				bi := int(h) / 100_000
				if bi >= NB { bi = NB - 1 }
				bucket_amt[bi] += amt
				bucket_cnt[bi] += 1
				if h >= 770_000 && h < 810_000 {
					fi := (int(h) - 770_000) / 5_000
					if fi >= 0 && fi < FB { fine_amt[fi] += amt; fine_cnt[fi] += 1 }
				}
			}
		}
		leveldb_iter_next(iter)
	}

	fmt.printf("\n===== UTXO AMOUNT AUDIT (tip %d) =====\n", height)
	fmt.printf("total: %d coins, %.8f BTC\n", total_cnt, f64(total_amt)/1e8)
	if cutoff >= 0 {
		fmt.printf("coins with height > %d: %d (min height %d) sample=%v\n",
			cutoff, above_cnt, min_above if above_cnt > 0 else 0, above_heights[:above_n])
	}
	fmt.printf("max single UTXO: %.8f BTC\n", f64(max_amt)/1e8)
	fmt.printf("coins > 50 BTC: %d, summing %.8f BTC\n", over_50btc_cnt, f64(over_50btc_amt)/1e8)
	fmt.printf("--- amount by 100k height bucket ---\n")
	for i in 0 ..< NB {
		lo := i * 100_000
		fmt.printf("  h[%7d..): %14.4f BTC   (%d coins)\n", lo, f64(bucket_amt[i])/1e8, bucket_cnt[i])
	}
	fmt.printf("--- fine buckets 770k..810k (recovery-replay window) ---\n")
	for i in 0 ..< FB {
		lo := 770_000 + i * 5_000
		fmt.printf("  h[%7d..%7d): %14.4f BTC   (%d coins)\n", lo, lo+5_000, f64(fine_amt[i])/1e8, fine_cnt[i])
	}
	fmt.printf("=====================================\n")
}

@(default_calling_convention="c")
foreign leveldb {
	leveldb_create_iterator :: proc(db: rawptr, options: rawptr) -> rawptr ---
	leveldb_iter_destroy :: proc(iter: rawptr) ---
	leveldb_iter_seek_to_first :: proc(iter: rawptr) ---
	leveldb_iter_valid :: proc(iter: rawptr) -> u8 ---
	leveldb_iter_next :: proc(iter: rawptr) ---
	leveldb_iter_key :: proc(iter: rawptr, klen: ^c.size_t) -> [^]byte ---
	leveldb_iter_value :: proc(iter: rawptr, vlen: ^c.size_t) -> rawptr ---
}
