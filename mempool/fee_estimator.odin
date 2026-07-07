// Fee estimation — a port of Bitcoin Core's CBlockPolicyEstimator.
//
// Transactions entering the mempool are bucketed by feerate (buckets spaced
// ×1.05 from 1,000 to 10,000,000 sat/kvB) with their entry height. When a
// block confirms a tracked tx, its "blocks to confirm" is recorded into
// exponentially-decaying moving averages; txs that leave the mempool
// unconfirmed count as failures. Three horizons track short/medium/long
// targets exactly like Core: (decay 0.962, scale 1), (0.9952, 2),
// (0.99931, 24). An estimate for a confirmation target is the lowest
// feerate bucket range whose historical success rate clears the threshold.
package mempool

FEE_SPACING :: 1.05
MIN_BUCKET_FEERATE :: 1000.0 // sat/kvB — below this nothing is tracked
MAX_BUCKET_FEERATE :: 1.0e7
INF_FEERATE :: 1.0e99

SHORT_DECAY :: 0.962
MED_DECAY :: 0.9952
LONG_DECAY :: 0.99931

SHORT_SCALE :: 1
MED_SCALE :: 2
LONG_SCALE :: 24

SHORT_PERIODS :: 12 // × scale 1  = 12 blocks
MED_PERIODS :: 24   // × scale 2  = 48 blocks
LONG_PERIODS :: 42  // × scale 24 = 1008 blocks

HALF_SUCCESS_PCT :: 0.6
SUCCESS_PCT :: 0.85
DOUBLE_SUCCESS_PCT :: 0.95

SUFFICIENT_FEETXS :: 0.1  // per-block tx flow required to trust a bucket range
SUFFICIENT_TXS_SHORT :: 0.5

// One horizon's decaying statistics. Row i of conf_avg counts txs confirmed
// within (i+1)*scale blocks (cumulative at record time, like Core).
Confirm_Stats :: struct {
	scale:    int,
	decay:    f64,
	periods:  int,
	conf_avg: [][]f64, // [periods][buckets]
	fail_avg: [][]f64, // [periods][buckets]
	tx_ct:    []f64,   // decayed count per bucket
	fee_sum:  []f64,   // decayed feerate sum per bucket (for the median value)
	unconf:   [][]int, // ring by entry height [scale*periods][buckets]
	old_unconf: []int, // aged out of the ring, still unconfirmed
}

Tracked_Tx :: struct {
	height: int,
	bucket: int,
}

Fee_Estimator :: struct {
	buckets:      []f64, // upper bound of each bucket (sat/kvB)
	tracked:      map[Hash256]Tracked_Tx,
	best_height:  int,
	first_height: int, // first block we recorded (est. quality gate)
	short:        Confirm_Stats,
	med:          Confirm_Stats,
	long:         Confirm_Stats,
}

_stats_init :: proc(st: ^Confirm_Stats, n_buckets: int, periods: int, decay: f64, scale: int) {
	st.scale = scale
	st.decay = decay
	st.periods = periods
	st.conf_avg = make([][]f64, periods)
	st.fail_avg = make([][]f64, periods)
	for i in 0 ..< periods {
		st.conf_avg[i] = make([]f64, n_buckets)
		st.fail_avg[i] = make([]f64, n_buckets)
	}
	st.tx_ct = make([]f64, n_buckets)
	st.fee_sum = make([]f64, n_buckets)
	max_confirms := scale * periods
	st.unconf = make([][]int, max_confirms)
	for i in 0 ..< max_confirms {
		st.unconf[i] = make([]int, n_buckets)
	}
	st.old_unconf = make([]int, n_buckets)
}

_stats_destroy :: proc(st: ^Confirm_Stats) {
	for row in st.conf_avg { delete(row) }
	for row in st.fail_avg { delete(row) }
	for row in st.unconf { delete(row) }
	delete(st.conf_avg)
	delete(st.fail_avg)
	delete(st.unconf)
	delete(st.tx_ct)
	delete(st.fee_sum)
	delete(st.old_unconf)
}

estimator_init :: proc(est: ^Fee_Estimator) {
	n := 0
	for f := MIN_BUCKET_FEERATE; f < MAX_BUCKET_FEERATE; f *= FEE_SPACING {
		n += 1
	}
	n += 1 // infinity bucket
	est.buckets = make([]f64, n)
	i := 0
	for f := MIN_BUCKET_FEERATE; f < MAX_BUCKET_FEERATE; f *= FEE_SPACING {
		est.buckets[i] = f
		i += 1
	}
	est.buckets[i] = INF_FEERATE
	est.tracked = make(map[Hash256]Tracked_Tx, 1024)
	est.best_height = 0
	est.first_height = 0
	_stats_init(&est.short, n, SHORT_PERIODS, SHORT_DECAY, SHORT_SCALE)
	_stats_init(&est.med, n, MED_PERIODS, MED_DECAY, MED_SCALE)
	_stats_init(&est.long, n, LONG_PERIODS, LONG_DECAY, LONG_SCALE)
}

estimator_destroy :: proc(est: ^Fee_Estimator) {
	delete(est.buckets)
	delete(est.tracked)
	_stats_destroy(&est.short)
	_stats_destroy(&est.med)
	_stats_destroy(&est.long)
}

_bucket_index :: proc(est: ^Fee_Estimator, feerate_per_kvb: f64) -> int {
	// lowest bucket whose upper bound >= feerate
	lo, hi := 0, len(est.buckets) - 1
	for lo < hi {
		mid := (lo + hi) / 2
		if est.buckets[mid] < feerate_per_kvb {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

_stats_track :: proc(st: ^Confirm_Stats, height: int, bucket: int) {
	st.unconf[height % len(st.unconf)][bucket] += 1
}

// Start tracking a tx accepted to the mempool at `height` with `feerate`
// sat/kvB. Ignores anything below the minimum bucket.
estimator_process_tx :: proc(est: ^Fee_Estimator, txid: Hash256, height: int, feerate_per_kvb: i64) {
	if txid in est.tracked { return }
	if height != est.best_height {
		// Only track txs entering at the current tip — entries seen during
		// header races or replays would corrupt the ring accounting.
		return
	}
	f := f64(feerate_per_kvb)
	if f < MIN_BUCKET_FEERATE { return }
	bucket := _bucket_index(est, f)
	est.tracked[txid] = Tracked_Tx{height = height, bucket = bucket}
	_stats_track(&est.short, height, bucket)
	_stats_track(&est.med, height, bucket)
	_stats_track(&est.long, height, bucket)
}

_stats_remove :: proc(st: ^Confirm_Stats, entry_height: int, best_height: int, bucket: int, in_block: bool) {
	max_confirms := len(st.unconf)
	blocks_ago := best_height - entry_height
	if best_height == 0 { blocks_ago = 0 }
	if blocks_ago < 0 { return }

	if blocks_ago >= max_confirms {
		if st.old_unconf[bucket] > 0 {
			st.old_unconf[bucket] -= 1
		}
	} else {
		idx := entry_height % max_confirms
		if st.unconf[idx][bucket] > 0 {
			st.unconf[idx][bucket] -= 1
		}
	}
	// A tx leaving unconfirmed after waiting longer than a period counts as
	// a failure for every period it outlived (Core's fail_avg).
	if !in_block && blocks_ago >= st.scale {
		periods_ago := blocks_ago / st.scale
		for i in 0 ..< min(periods_ago, st.periods) {
			st.fail_avg[i][bucket] += 1
		}
	}
}

// Stop tracking (evicted / expired / replaced / conflicting). in_block=false
// records the failure; block confirmations go through estimator_process_block.
estimator_remove_tx :: proc(est: ^Fee_Estimator, txid: Hash256, in_block := false) {
	t, ok := est.tracked[txid]
	if !ok { return }
	delete_key(&est.tracked, txid)
	if in_block { return } // confirmation accounting happens in process_block
	_stats_remove(&est.short, t.height, est.best_height, t.bucket, false)
	_stats_remove(&est.med, t.height, est.best_height, t.bucket, false)
	_stats_remove(&est.long, t.height, est.best_height, t.bucket, false)
}

_stats_decay :: proc(st: ^Confirm_Stats) {
	n := len(st.tx_ct)
	for i in 0 ..< st.periods {
		for b in 0 ..< n {
			st.conf_avg[i][b] *= st.decay
			st.fail_avg[i][b] *= st.decay
		}
	}
	for b in 0 ..< n {
		st.tx_ct[b] *= st.decay
		st.fee_sum[b] *= st.decay
	}
}

_stats_record_confirm :: proc(st: ^Confirm_Stats, blocks_to_confirm: int, bucket: int, feerate: f64) {
	if blocks_to_confirm < 1 { return }
	periods_to_confirm := (blocks_to_confirm + st.scale - 1) / st.scale
	for i := periods_to_confirm; i <= st.periods; i += 1 {
		st.conf_avg[i - 1][bucket] += 1
	}
	st.tx_ct[bucket] += 1
	st.fee_sum[bucket] += feerate
}

_stats_age_ring :: proc(st: ^Confirm_Stats, new_height: int) {
	// The ring slot about to be reused belongs to (new_height - max_confirms);
	// anything still there has outlived the window — move it to old_unconf.
	idx := new_height % len(st.unconf)
	for b in 0 ..< len(st.old_unconf) {
		st.old_unconf[b] += st.unconf[idx][b]
		st.unconf[idx][b] = 0
	}
}

// A new block connected at `height`; confirmed_txids are the block's txs.
// Call BEFORE the mempool entries are removed (entry data must still exist).
estimator_process_block :: proc(est: ^Fee_Estimator, height: int, confirmed: []Hash256) {
	if height <= est.best_height {
		// Out-of-order or replayed block (reorg reconnect) — do not corrupt
		// the decay clock; just drop tracking for the confirmed txs.
		for txid in confirmed {
			estimator_remove_tx(est, txid, in_block = true)
		}
		return
	}
	for h := est.best_height + 1; h <= height; h += 1 {
		_stats_age_ring(&est.short, h)
		_stats_age_ring(&est.med, h)
		_stats_age_ring(&est.long, h)
	}
	est.best_height = height
	if est.first_height == 0 { est.first_height = height }

	_stats_decay(&est.short)
	_stats_decay(&est.med)
	_stats_decay(&est.long)

	for txid in confirmed {
		t, ok := est.tracked[txid]
		if !ok { continue }
		delete_key(&est.tracked, txid)
		blocks := height - t.height
		if blocks <= 0 { continue }
		// Feerate recorded as the bucket's representative value.
		f := est.buckets[t.bucket]
		if f >= INF_FEERATE { f = MAX_BUCKET_FEERATE }
		_stats_remove(&est.short, t.height, height, t.bucket, true)
		_stats_remove(&est.med, t.height, height, t.bucket, true)
		_stats_remove(&est.long, t.height, height, t.bucket, true)
		_stats_record_confirm(&est.short, blocks, t.bucket, f)
		_stats_record_confirm(&est.med, blocks, t.bucket, f)
		_stats_record_confirm(&est.long, blocks, t.bucket, f)
	}
}

// Core's EstimateMedianVal: scan bucket ranges from the most expensive down,
// and return the median feerate of the LOWEST range that still clears
// success_threshold for confirmation within conf_target blocks. Returns -1
// when there is not enough data.
_estimate_median :: proc(est: ^Fee_Estimator, st: ^Confirm_Stats, conf_target: int, sufficient_txs: f64, success_threshold: f64) -> f64 {
	if conf_target < 1 || conf_target > st.scale * st.periods {
		return -1
	}
	period_target := (conf_target + st.scale - 1) / st.scale
	n := len(est.buckets)
	max_confirms := len(st.unconf)
	required := sufficient_txs / (1.0 - st.decay)

	n_conf, total_num, fail_num, extra_num := 0.0, 0.0, 0.0, 0.0
	// "near" = high end of the range being accumulated, "far" = current
	// (lower) bucket. A failed check does NOT reset the range — it keeps
	// growing downward and may recover (Core semantics).
	cur_near, cur_far := n - 1, n - 1
	new_range := true
	best_near, best_far := -1, -1
	found_answer := false

	for b := n - 1; b >= 0; b -= 1 {
		if new_range {
			cur_near = b
			new_range = false
		}
		cur_far = b
		n_conf += st.conf_avg[period_target - 1][b]
		total_num += st.tx_ct[b]
		fail_num += st.fail_avg[period_target - 1][b]
		for h := conf_target; h < max_confirms; h += 1 {
			extra_num += f64(st.unconf[(est.best_height - h) %% max_confirms][b])
		}
		extra_num += f64(st.old_unconf[b])

		if total_num >= required {
			cur_pct := n_conf / (total_num + fail_num + extra_num)
			if cur_pct < success_threshold {
				continue
			}
			// Passing range: remember it (each pass is lower than the last)
			// and reset the accumulators to hunt for an even lower one.
			found_answer = true
			best_near = cur_near
			best_far = cur_far
			n_conf, total_num, fail_num, extra_num = 0, 0, 0, 0
			new_range = true
		}
	}

	if !found_answer { return -1 }

	// Median feerate within the best range, weighted by tx count.
	lo, hi := min(best_far, best_near), max(best_far, best_near)
	tx_sum := 0.0
	for b in lo ..= hi { tx_sum += st.tx_ct[b] }
	if tx_sum <= 0 { return -1 }
	tx_sum /= 2
	for b in lo ..= hi {
		if st.tx_ct[b] < tx_sum {
			tx_sum -= st.tx_ct[b]
		} else {
			return st.fee_sum[b] / st.tx_ct[b]
		}
	}
	return -1
}

_horizon_for_target :: proc(est: ^Fee_Estimator, conf_target: int) -> ^Confirm_Stats {
	if conf_target <= SHORT_SCALE * SHORT_PERIODS { return &est.short }
	if conf_target <= MED_SCALE * MED_PERIODS { return &est.med }
	return &est.long
}

_estimate_combined :: proc(est: ^Fee_Estimator, conf_target: int, threshold: f64) -> f64 {
	st := _horizon_for_target(est, conf_target)
	sufficient := st == &est.short ? f64(SUFFICIENT_TXS_SHORT) : f64(SUFFICIENT_FEETXS)
	return _estimate_median(est, st, conf_target, sufficient, threshold)
}

// estimatesmartfee: Core-style combination — the max of the half-target,
// full-target, and double-target estimates (each at its threshold), so a
// short-horizon blip can't undercut a longer-horizon requirement.
// conservative additionally consults the double target on longer horizons.
// Returns sat/kvB, or -1 if no estimate is available.
estimator_smart_fee :: proc(est: ^Fee_Estimator, conf_target_in: int, conservative := false) -> (feerate_per_kvb: i64, found: bool) {
	conf_target := clamp(conf_target_in, 1, LONG_SCALE * LONG_PERIODS)
	if est.best_height == 0 || est.first_height == 0 {
		return -1, false
	}

	median := -1.0
	if conf_target >= 2 {
		if half := _estimate_combined(est, conf_target / 2, HALF_SUCCESS_PCT); half > median {
			median = half
		}
	}
	if actual := _estimate_combined(est, conf_target, SUCCESS_PCT); actual > median {
		median = actual
	}
	// Core includes the double-target estimate in the max UNCONDITIONALLY
	// (the audit caught the economical path computing and discarding it,
	// which made economical estimates lower than Core's).
	if conf_target * 2 <= LONG_SCALE * LONG_PERIODS {
		if double := _estimate_combined(est, conf_target * 2, DOUBLE_SUCCESS_PCT); double > median {
			median = double
		}
	}
	// Conservative mode additionally consults every LONGER horizon at the
	// doubled target (Core's EstimateConservativeFee): a short-horizon dip
	// can't undercut what the long history says is needed.
	if conservative {
		double_target := conf_target * 2
		horizons := [2]^Confirm_Stats{&est.med, &est.long}
		for st in horizons {
			if double_target > st.scale * st.periods { continue }
			if st == _horizon_for_target(est, double_target) { continue } // natural horizon already counted
			if v := _estimate_median(est, st, double_target, SUFFICIENT_FEETXS, DOUBLE_SUCCESS_PCT); v > median {
				median = v
			}
		}
	}
	if median < 0 {
		return -1, false
	}
	return i64(median + 0.5), true
}
