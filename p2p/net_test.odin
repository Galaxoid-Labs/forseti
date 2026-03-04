package p2p

import "core:fmt"
import "core:testing"

import "../chain"
import "../consensus"
import "../crypto"
import "../storage"
import "../wire"

// Helper: build a minimal regtest block index with N blocks (headers only).
_make_test_chain_state :: proc(t: ^testing.T, num_blocks: int) -> (^chain.Chain_State, bool) {
	cs := new(chain.Chain_State, context.temp_allocator)
	cs.params = &consensus.REGTEST_PARAMS
	cs.block_index = chain.block_index_init(context.temp_allocator)
	cs.active_chain = make([dynamic]Hash256, 0, num_blocks + 1, context.temp_allocator)

	// Genesis block.
	genesis_header := wire.Block_Header{
		version     = 1,
		prev_hash   = HASH_ZERO,
		merkle_root = HASH_ZERO,
		timestamp   = 1296688602,
		bits        = 0x207fffff,
		nonce       = 0,
	}
	genesis_hash := wire.block_header_hash(&genesis_header)
	genesis_entry := chain.block_index_add(
		&cs.block_index,
		&genesis_header,
		0,
		storage.Block_Status{.Valid_Header, .Has_Data, .Valid_Chain},
	)
	append(&cs.active_chain, genesis_hash)

	prev_hash := genesis_hash
	for i in 1 ..= num_blocks {
		hdr := wire.Block_Header{
			version     = 1,
			prev_hash   = prev_hash,
			merkle_root = HASH_ZERO,
			timestamp   = u32(1296688602 + i * 600),
			bits        = 0x207fffff,
			nonce       = u32(i),
		}
		h := wire.block_header_hash(&hdr)
		chain.block_index_add(
			&cs.block_index,
			&hdr,
			i,
			storage.Block_Status{.Valid_Header, .Has_Data, .Valid_Chain},
		)
		append(&cs.active_chain, h)
		prev_hash = h
	}

	return cs, true
}

@(test)
test_build_block_locator :: proc(t: ^testing.T) {
	cs, ok := _make_test_chain_state(t, 100)
	testing.expect(t, ok, "failed to make test chain state")

	locator := build_block_locator(cs)
	defer delete(locator)

	// Locator should not be empty.
	testing.expect(t, len(locator) > 0, "locator should not be empty")

	// First entry should be the tip (height 100).
	tip_hash := cs.active_chain[100]
	testing.expect(t, locator[0] == tip_hash, "first locator entry should be tip")

	// Last entry should be genesis (height 0).
	genesis_hash := cs.active_chain[0]
	testing.expect(t, locator[len(locator) - 1] == genesis_hash, "last locator entry should be genesis")

	// After the first 10 entries, steps should double (exponential).
	// Locator should have reasonable size for 100 blocks (around 15-20 entries).
	testing.expect(t, len(locator) > 10, fmt.tprintf("locator should have >10 entries, got %d", len(locator)))
	testing.expect(t, len(locator) < 30, fmt.tprintf("locator should have <30 entries, got %d", len(locator)))
}

@(test)
test_block_locator_short_chain :: proc(t: ^testing.T) {
	cs, ok := _make_test_chain_state(t, 5)
	testing.expect(t, ok, "failed to make test chain state")

	locator := build_block_locator(cs)
	defer delete(locator)

	// Short chain: should have exactly 6 entries (heights 5,4,3,2,1,0).
	testing.expect_value(t, len(locator), 6)

	// Verify they're in descending height order.
	for i in 0 ..< len(locator) {
		expected_height := 5 - i
		testing.expect(t, locator[i] == cs.active_chain[expected_height],
			fmt.tprintf("locator[%d] should be height %d", i, expected_height))
	}
}

@(test)
test_block_locator_single_block :: proc(t: ^testing.T) {
	cs, ok := _make_test_chain_state(t, 0)
	testing.expect(t, ok, "failed to make test chain state")

	locator := build_block_locator(cs)
	defer delete(locator)

	// Genesis only: exactly 1 entry.
	testing.expect_value(t, len(locator), 1)
	testing.expect(t, locator[0] == cs.active_chain[0], "should be genesis")
}

@(test)
test_sync_manager_state_transitions :: proc(t: ^testing.T) {
	sm: Sync_Manager
	cs, ok := _make_test_chain_state(t, 10)
	testing.expect(t, ok, "failed to make test chain state")

	sync_manager_init(&sm, cs, &consensus.REGTEST_PARAMS)
	defer sync_manager_destroy(&sm)

	testing.expect_value(t, sm.state, Sync_State.Idle)

	// Simulate header sync transition.
	sm.state = .Syncing_Headers
	testing.expect_value(t, sm.state, Sync_State.Syncing_Headers)

	// Simulate block download transition.
	sm.state = .Downloading_Blocks
	testing.expect_value(t, sm.state, Sync_State.Downloading_Blocks)

	// Simulate completion.
	sm.state = .In_Sync
	testing.expect_value(t, sm.state, Sync_State.In_Sync)
}

@(test)
test_peer_message_framing :: proc(t: ^testing.T) {
	// Build a version message payload through the wire serialization path.
	ver := wire.Version_Message{
		version      = i32(wire.PROTOCOL_VERSION),
		services     = LOCAL_SERVICES,
		timestamp    = 1234567890,
		addr_recv    = wire.Net_Address{services = 0},
		addr_from    = wire.Net_Address{services = LOCAL_SERVICES},
		nonce        = 0xDEADBEEFCAFEBABE,
		user_agent   = "/test:0.1/",
		start_height = 100,
		relay        = true,
	}

	w := wire.writer_init(context.temp_allocator)
	wire.serialize_version(&w, &ver)
	payload := wire.writer_bytes(&w)

	// Frame it as a complete message.
	framed := wire.build_message(wire.REGTEST_MAGIC, wire.CMD_VERSION, payload, context.temp_allocator)

	// Parse it back.
	r := wire.reader_init(framed)
	hdr, hdr_err := wire.deserialize_message_header(&r)
	testing.expect_value(t, hdr_err, wire.Wire_Error.None)

	// Validate header fields.
	testing.expect_value(t, hdr.magic, wire.REGTEST_MAGIC)
	testing.expect_value(t, hdr.payload_size, u32(len(payload)))

	cmd := wire.command_from_bytes(hdr.command)
	testing.expect(t, cmd == wire.CMD_VERSION, "command should be version")

	// Validate checksum.
	parsed_payload := framed[wire.MESSAGE_HEADER_SIZE:]
	testing.expect(t, wire.validate_checksum(&hdr, parsed_payload), "checksum should be valid")

	// Deserialize the version payload.
	r2 := wire.reader_init(parsed_payload)
	ver2, ver_err := wire.deserialize_version(&r2, context.temp_allocator)
	testing.expect_value(t, ver_err, wire.Wire_Error.None)
	testing.expect_value(t, ver2.version, i32(wire.PROTOCOL_VERSION))
	testing.expect_value(t, ver2.start_height, i32(100))
	testing.expect_value(t, ver2.nonce, u64(0xDEADBEEFCAFEBABE))
}

// --- Bandwidth scoring tests ---

@(test)
test_peer_block_limit_trial :: proc(t: ^testing.T) {
	// During trial period (< PEER_TRIAL_SECS), should get PEER_TRIAL_BLOCKS
	ps := Peer_Sync_State{
		tracking_since   = 100,
		blocks_delivered = 0,
	}
	now := i64(100 + PEER_TRIAL_SECS - 1) // still in trial
	limit := _peer_block_limit(ps, now, 10.0, 3)
	testing.expect_value(t, limit, PEER_TRIAL_BLOCKS)
}

@(test)
test_peer_block_limit_scored :: proc(t: ^testing.T) {
	// After trial, scoring kicks in based on throughput share
	ps := Peer_Sync_State{
		tracking_since   = 0,
		blocks_delivered = 100,
	}
	now := i64(100) // 100 seconds elapsed → 1 block/sec

	// If total rate = 4 blocks/sec across 4 peers, this peer has 25% share
	// budget = MAX_BLOCKS_PER_PEER * 4 = 64, share = 0.25 → limit = 16
	limit := _peer_block_limit(ps, now, 4.0, 4)
	testing.expect(t, limit >= MIN_BLOCKS_PER_PEER, "should be at least min")
	testing.expect(t, limit <= MAX_BLOCKS_PER_PEER, "should be at most max")
}

@(test)
test_peer_block_limit_fast_peer :: proc(t: ^testing.T) {
	// A fast peer delivering most blocks should get MAX
	ps := Peer_Sync_State{
		tracking_since   = 0,
		blocks_delivered = 1000,
	}
	now := i64(100) // 10 blocks/sec — very fast

	// total_rate = 11 (this peer + one slow peer at 1/sec)
	limit := _peer_block_limit(ps, now, 11.0, 2)
	testing.expect_value(t, limit, MAX_BLOCKS_PER_PEER)
}

@(test)
test_peer_block_limit_slow_peer :: proc(t: ^testing.T) {
	// A slow peer should get MIN
	ps := Peer_Sync_State{
		tracking_since   = 0,
		blocks_delivered = 5,
	}
	now := i64(100) // 0.05 blocks/sec — very slow

	// total_rate = 10 (mostly from fast peers)
	limit := _peer_block_limit(ps, now, 10.0, 4)
	testing.expect_value(t, limit, MIN_BLOCKS_PER_PEER)
}

// --- Stall timeout decay ---

@(test)
test_sync_decay_stall_timeout :: proc(t: ^testing.T) {
	sm: Sync_Manager
	cs, ok := _make_test_chain_state(t, 5)
	testing.expect(t, ok, "failed to make test chain")
	sync_manager_init(&sm, cs, &consensus.REGTEST_PARAMS)
	defer sync_manager_destroy(&sm)

	// Set elevated stall timeout
	sm.stall_timeout = BLOCK_STALL_TIMEOUT_MAX // 64

	// Decay should reduce by 15% each call
	sync_decay_stall_timeout(&sm)
	testing.expect(t, sm.stall_timeout < BLOCK_STALL_TIMEOUT_MAX, "should decay")
	testing.expect(t, sm.stall_timeout >= BLOCK_STALL_TIMEOUT_DEFAULT, "should not go below default")

	// Keep decaying until we hit the floor
	for i in 0 ..< 100 {
		sync_decay_stall_timeout(&sm)
	}
	testing.expect_value(t, sm.stall_timeout, i64(BLOCK_STALL_TIMEOUT_DEFAULT))
}

// --- Sync manager init/destroy ---

@(test)
test_sync_manager_init :: proc(t: ^testing.T) {
	sm: Sync_Manager
	cs, ok := _make_test_chain_state(t, 10)
	testing.expect(t, ok, "failed to make test chain")

	sync_manager_init(&sm, cs, &consensus.REGTEST_PARAMS)
	defer sync_manager_destroy(&sm)

	testing.expect_value(t, sm.state, Sync_State.Idle)
	testing.expect_value(t, sm.stall_timeout, i64(BLOCK_STALL_TIMEOUT_DEFAULT))
	testing.expect(t, sm.chain == cs, "chain should be set")
	testing.expect(t, sm.params == &consensus.REGTEST_PARAMS, "params should be set")
}

// --- DNS seed tests ---

@(test)
test_dns_seed_selection :: proc(t: ^testing.T) {
	// Verify correct seeds returned for each network.

	// Mainnet should have 4 seeds.
	testing.expect_value(t, len(MAINNET_SEEDS), 4)
	testing.expect(t, MAINNET_SEEDS[0] == "seed.bitcoin.sipa.be", "first mainnet seed")

	// Testnet3 should have 3 seeds.
	testing.expect_value(t, len(TESTNET3_SEEDS), 3)
	testing.expect(t, TESTNET3_SEEDS[0] == "testnet-seed.bitcoin.jonasschnelli.ch", "first testnet seed")

	// Regtest should have 0 seeds.
	testing.expect_value(t, len(REGTEST_SEEDS), 0)

	// Verify default ports.
	testing.expect_value(t, DEFAULT_PORT_MAINNET, 8333)
	testing.expect_value(t, DEFAULT_PORT_TESTNET3, 18333)
	testing.expect_value(t, DEFAULT_PORT_REGTEST, 18444)
}
