package chain

import "core:log"
import "core:mem"
import "core:sync"
import "core:thread"
import "../script"
import "../wire"

// Minimum number of checks before using parallel verification.
// Below this threshold, serial verification avoids thread pool overhead.
PARALLEL_THRESHOLD :: 16

// A single script verification task (one input).
Script_Check :: struct {
	tx:            ^wire.Tx,
	input_idx:     int,
	amount:        i64,
	flags:         script.Verify_Flags,
	spent_outputs: []wire.Tx_Out,
	sighash_cache: ^script.Sighash_Cache, // pre-computed, read-only
	script_sig:    []byte,
	script_pubkey: []byte,
	witness:       [][]byte,
	control:       ^Script_Check_Control,
	tx_idx:        int, // block tx index, for error logging
	height:        int, // block height, for error logging
}

// Shared control structure for a batch of parallel checks.
Script_Check_Control :: struct {
	wg:              ^sync.Wait_Group,
	first_error:     i32, // 0 = no error, >0 = Script_Error ordinal (atomic)
	error_check_idx: i32, // index into checks[] that caused first error (atomic)
	cs:              ^Chain_State, // for arena pool access
}

// Per-block batch of script checks collected during Phase 1.
Script_Check_Batch :: struct {
	checks: [dynamic]Script_Check,
	caches: [dynamic]script.Sighash_Cache, // one per non-coinbase tx
}

// Thread pool worker: verifies a single script check.
script_check_worker :: proc(task: thread.Task) {
	check := cast(^Script_Check)task.data

	// Acquire a pre-allocated 4 MB arena buffer from the pool.
	arena_buf := _arena_pool_acquire(check.control.cs)
	defer _arena_pool_release(check.control.cs, arena_buf)

	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	alloc := mem.arena_allocator(&arena)
	context.temp_allocator = alloc

	verifier := script.Script_Verifier {
		tx            = check.tx,
		input_idx     = check.input_idx,
		amount        = check.amount,
		flags         = check.flags,
		spent_outputs = check.spent_outputs,
		sighash_cache = check.sighash_cache,
	}

	serr := script.verify_script(&verifier, check.script_sig, check.script_pubkey, check.witness)

	if serr != .None {
		// First error wins — store atomically.
		_, ok := sync.atomic_compare_exchange_strong(&check.control.first_error, i32(0), i32(serr))
		if ok {
			sync.atomic_store(&check.control.error_check_idx, i32(task.user_index))
		}
	}

	sync.wait_group_done(check.control.wg)
}

// Acquire a pre-allocated arena buffer from the pool. Spins if none available.
_arena_pool_acquire :: proc(cs: ^Chain_State) -> []byte {
	for {
		sync.mutex_lock(&cs.arena_pool_mu)
		if len(cs.arena_pool_stack) > 0 {
			idx := pop(&cs.arena_pool_stack)
			sync.mutex_unlock(&cs.arena_pool_mu)
			return cs.arena_pool_bufs[idx]
		}
		sync.mutex_unlock(&cs.arena_pool_mu)
		// All buffers in use — brief yield and retry.
		thread.yield()
	}
}

// Return an arena buffer to the pool.
_arena_pool_release :: proc(cs: ^Chain_State, buf: []byte) {
	sync.mutex_lock(&cs.arena_pool_mu)
	// Find the index by pointer identity.
	for i in 0 ..< len(cs.arena_pool_bufs) {
		if raw_data(cs.arena_pool_bufs[i]) == raw_data(buf) {
			append(&cs.arena_pool_stack, i)
			break
		}
	}
	sync.mutex_unlock(&cs.arena_pool_mu)
}

// Dispatch all checks to the thread pool for parallel verification.
verify_checks_parallel :: proc(
	cs: ^Chain_State,
	pool: ^thread.Pool,
	wg: ^sync.Wait_Group,
	checks: []Script_Check,
	height: int,
) -> script.Script_Error {
	if len(checks) == 0 {
		return .None
	}

	ctrl := Script_Check_Control {
		wg          = wg,
		first_error = 0,
		cs          = cs,
	}

	// Wire control into each check.
	for i in 0 ..< len(checks) {
		checks[i].control = &ctrl
	}

	// Add all checks to the wait group before adding tasks.
	sync.wait_group_add(wg, len(checks))

	// Dispatch tasks to pool.
	for i in 0 ..< len(checks) {
		thread.pool_add_task(pool, context.allocator, script_check_worker, &checks[i], user_index = i)
	}

	// Block until all checks complete.
	sync.wait_group_wait(wg)

	// Check for errors.
	err_val := sync.atomic_load(&ctrl.first_error)
	if err_val != 0 {
		err_idx := sync.atomic_load(&ctrl.error_check_idx)
		if int(err_idx) >= 0 && int(err_idx) < len(checks) {
			c := checks[err_idx]
			txid := wire.tx_id(c.tx)
			txid_rev: Hash256
			for b in 0 ..< 32 { txid_rev[b] = txid[31 - b] }
			log.errorf(
				"Script FAIL (parallel) height=%d tx_idx=%d in_idx=%d/%d err=%v txid=%02x%02x%02x%02x%02x%02x%02x%02x...",
				c.height, c.tx_idx, c.input_idx, len(c.tx.inputs), script.Script_Error(err_val),
				txid_rev[0], txid_rev[1], txid_rev[2], txid_rev[3],
				txid_rev[4], txid_rev[5], txid_rev[6], txid_rev[7],
			)
		}
		return script.Script_Error(err_val)
	}

	return .None
}

// Serial fallback: verify all checks using the Chain_State's verify arena.
verify_checks_serial :: proc(cs: ^Chain_State, checks: []Script_Check, height: int) -> script.Script_Error {
	saved_temp := context.temp_allocator

	for i in 0 ..< len(checks) {
		check := &checks[i]

		mem.arena_free_all(&cs.verify_arena)
		context.temp_allocator = cs.verify_alloc

		verifier := script.Script_Verifier {
			tx            = check.tx,
			input_idx     = check.input_idx,
			amount        = check.amount,
			flags         = check.flags,
			spent_outputs = check.spent_outputs,
			sighash_cache = check.sighash_cache,
		}

		serr := script.verify_script(&verifier, check.script_sig, check.script_pubkey, check.witness)
		if serr != .None {
			context.temp_allocator = saved_temp
			txid := wire.tx_id(check.tx)
			txid_rev: Hash256
			for b in 0 ..< 32 { txid_rev[b] = txid[31 - b] }
			log.errorf(
				"Script FAIL height=%d tx_idx=%d in_idx=%d/%d err=%v txid=%02x%02x%02x%02x%02x%02x%02x%02x... scriptPubKey_len=%d num_inputs=%d",
				height, check.tx_idx, check.input_idx, len(check.tx.inputs), serr,
				txid_rev[0], txid_rev[1], txid_rev[2], txid_rev[3],
				txid_rev[4], txid_rev[5], txid_rev[6], txid_rev[7],
				len(check.script_pubkey), len(check.tx.inputs),
			)
			return serr
		}
	}

	context.temp_allocator = saved_temp
	return .None
}
