// fee_estimates.dat — persist the estimator's decaying statistics across
// restarts (Core parity: without this, every restart forgets weeks of
// long-horizon history). Tracked-but-unconfirmed txs are NOT persisted;
// mempool.dat re-adds them through the normal path on load.
//
// Format (all LE):
// [version:u64][n_buckets:u64][best_height:u64][first_height:u64]
// then 3 horizons (short, med, long), each:
//   [tx_ct: n f64][fee_sum: n f64][conf_avg: periods*n f64][fail_avg: periods*n f64]
// (bucket boundaries and horizon parameters are code constants; a mismatch
// in n_buckets rejects the file.)
package mempool

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/posix"

FEE_ESTIMATES_VERSION :: u64(1)

estimator_save :: proc(est: ^Fee_Estimator, data_dir: string) -> bool {
	tmp_path := fmt.tprintf("%s/fee_estimates.dat.tmp", data_dir)
	final_path := fmt.tprintf("%s/fee_estimates.dat", data_dir)

	fd, ferr := os.open(tmp_path, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Read_All + {.Write_User})
	if ferr != nil {
		log.warnf("Failed to open %s for writing: %v", tmp_path, ferr)
		return false
	}
	defer os.close(fd)

	n := len(est.buckets)
	if !_write_u64le(fd, FEE_ESTIMATES_VERSION) { return false }
	if !_write_u64le(fd, u64(n)) { return false }
	if !_write_u64le(fd, u64(est.best_height)) { return false }
	if !_write_u64le(fd, u64(est.first_height)) { return false }

	horizons := [3]^Confirm_Stats{&est.short, &est.med, &est.long}
	for st in horizons {
		if !_write_f64_slice(fd, st.tx_ct) { return false }
		if !_write_f64_slice(fd, st.fee_sum) { return false }
		for i in 0 ..< st.periods {
			if !_write_f64_slice(fd, st.conf_avg[i]) { return false }
		}
		for i in 0 ..< st.periods {
			if !_write_f64_slice(fd, st.fail_avg[i]) { return false }
		}
	}

	tmp_cstr := fmt.ctprintf("%s", tmp_path)
	final_cstr := fmt.ctprintf("%s", final_path)
	if posix.rename(tmp_cstr, final_cstr) != 0 {
		log.warnf("Failed to rename fee_estimates.dat.tmp")
		return false
	}
	log.infof("Saved fee estimates (best height %d)", est.best_height)
	return true
}

estimator_load :: proc(est: ^Fee_Estimator, data_dir: string) -> bool {
	path := fmt.tprintf("%s/fee_estimates.dat", data_dir)
	if !os.exists(path) {
		return false
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		log.warnf("Failed to read %s", path)
		return false
	}

	pos := 0
	ver, ok1 := _read_u64le(data, &pos)
	n_buckets, ok2 := _read_u64le(data, &pos)
	best_h, ok3 := _read_u64le(data, &pos)
	first_h, ok4 := _read_u64le(data, &pos)
	if !ok1 || !ok2 || !ok3 || !ok4 || ver != FEE_ESTIMATES_VERSION || int(n_buckets) != len(est.buckets) {
		log.warnf("fee_estimates.dat: incompatible header — starting fresh")
		return false
	}

	horizons := [3]^Confirm_Stats{&est.short, &est.med, &est.long}
	for st in horizons {
		if !_read_f64_slice(data, &pos, st.tx_ct) { return false }
		if !_read_f64_slice(data, &pos, st.fee_sum) { return false }
		for i in 0 ..< st.periods {
			if !_read_f64_slice(data, &pos, st.conf_avg[i]) { return false }
		}
		for i in 0 ..< st.periods {
			if !_read_f64_slice(data, &pos, st.fail_avg[i]) { return false }
		}
	}

	est.best_height = max(int(best_h), est.best_height)
	est.first_height = int(first_h)
	log.infof("Loaded fee estimates (history through height %d)", int(best_h))
	return true
}

_write_f64_slice :: proc(fd: ^os.File, vals: []f64) -> bool {
	for v in vals {
		if !_write_u64le(fd, transmute(u64)v) { return false }
	}
	return true
}

_read_u64le :: proc(data: []byte, pos: ^int) -> (u64, bool) {
	if pos^ + 8 > len(data) { return 0, false }
	v := u64(0)
	for i in 0 ..< 8 {
		v |= u64(data[pos^ + i]) << uint(i * 8)
	}
	pos^ += 8
	return v, true
}

_read_f64_slice :: proc(data: []byte, pos: ^int, out: []f64) -> bool {
	for i in 0 ..< len(out) {
		v, ok := _read_u64le(data, pos)
		if !ok { return false }
		out[i] = transmute(f64)v
	}
	return true
}
