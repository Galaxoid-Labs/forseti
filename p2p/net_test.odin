package p2p

import "core:encoding/hex"
import "core:fmt"
import "core:testing"

import "../chain"
import "../consensus"
import crypto "../crypto"
import "../storage"
import "../wire"

// Helper: decode hex string to byte slice (temp allocated).
_hex :: proc(s: string) -> []u8 {
	bytes, _ := hex.decode(transmute([]u8)s, context.temp_allocator)
	return bytes
}

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

// --- Compact block reconstruction tests ---

// Helper: make a simple tx with a given "fingerprint" byte in the locktime field
// so we can verify it's the right tx after reconstruction.
_make_cmpct_test_tx :: proc(fingerprint: u32) -> wire.Tx {
	inputs := make([]wire.Tx_In, 1, context.temp_allocator)
	inputs[0] = wire.Tx_In{
		previous_output = wire.Outpoint{hash = HASH_ZERO, index = fingerprint},
		script_sig      = nil,
		sequence        = 0xffffffff,
	}
	outputs := make([]wire.Tx_Out, 1, context.temp_allocator)
	outputs[0] = wire.Tx_Out{value = i64(fingerprint) * 1000, script_pubkey = nil}
	return wire.Tx{version = 2, inputs = inputs, outputs = outputs, locktime = fingerprint}
}

@(test)
test_compact_block_reconstruction :: proc(t: ^testing.T) {
	// Build a compact block with 3 txs: coinbase (prefilled) + 2 regular txs (as shortids).
	// Populate a mock shortid→tx map simulating mempool match.

	coinbase_tx := _make_cmpct_test_tx(0)
	tx1 := _make_cmpct_test_tx(1)
	tx2 := _make_cmpct_test_tx(2)

	// Compute wtxids for the two regular txs.
	wtxid1 := wire.tx_witness_id(&tx1)
	wtxid2 := wire.tx_witness_id(&tx2)

	// Use a fixed nonce and block header for key derivation.
	header := wire.Block_Header{version = 1, timestamp = 12345, bits = 0x1d00ffff, nonce = 99}
	block_hash := wire.block_header_hash(&header)
	cmpct_nonce: u64 = 42

	// Compute SipHash keys (same logic as sync_handle_compact_block).
	key_buf: [40]byte
	copy(key_buf[:32], block_hash[:])
	key_buf[32] = u8(cmpct_nonce)
	key_hash := crypto.sha256_hash(key_buf[:])
	k0 := _u64le(key_hash[:8])
	k1 := _u64le(key_hash[8:16])

	// Compute shortids.
	sid1 := crypto.compact_block_shortid(k0, k1, wtxid1)
	sid2 := crypto.compact_block_shortid(k0, k1, wtxid2)

	// Verify shortids are 6 bytes.
	testing.expect(t, sid1 & 0xffff000000000000 == 0, "sid1 should be 6 bytes")
	testing.expect(t, sid2 & 0xffff000000000000 == 0, "sid2 should be 6 bytes")

	// Build shortid→tx map (simulating mempool lookup).
	sid_map := make(map[u64]^wire.Tx, 4, context.temp_allocator)
	sid_map[sid1] = &tx1
	sid_map[sid2] = &tx2

	// Build the compact block message.
	prefilled := []wire.Prefilled_Tx{{index = 0, tx = coinbase_tx}}
	shortids := []u64{sid1, sid2}

	// Simulate reconstruction: total_txs = 3 (1 prefilled + 2 shortids).
	total_txs := len(shortids) + len(prefilled)
	testing.expect_value(t, total_txs, 3)

	// Build tx_ptrs.
	tx_ptrs := make([]^wire.Tx, total_txs, context.temp_allocator)
	shortid_cursor := 0
	missing_count := 0

	prefilled_positions := make(map[u64]int, len(prefilled), context.temp_allocator)
	for i in 0 ..< len(prefilled) {
		prefilled_positions[prefilled[i].index] = i
	}

	for pos in 0 ..< total_txs {
		pi, is_prefilled := prefilled_positions[u64(pos)]
		if is_prefilled {
			tx_ptrs[pos] = &prefilled[pi].tx
		} else {
			sid := shortids[shortid_cursor]
			shortid_cursor += 1
			mp_tx, found := sid_map[sid]
			if found {
				tx_ptrs[pos] = mp_tx
			} else {
				missing_count += 1
			}
		}
	}

	// All txs should be found.
	testing.expect_value(t, missing_count, 0)

	// Verify correct txs at each position.
	testing.expect_value(t, tx_ptrs[0].locktime, u32(0)) // coinbase
	testing.expect_value(t, tx_ptrs[1].locktime, u32(1)) // tx1
	testing.expect_value(t, tx_ptrs[2].locktime, u32(2)) // tx2

	// Assemble block and verify.
	block := _assemble_block(&header, tx_ptrs)
	testing.expect_value(t, len(block.txs), 3)
	testing.expect_value(t, block.txs[0].locktime, u32(0))
	testing.expect_value(t, block.txs[1].locktime, u32(1))
	testing.expect_value(t, block.txs[2].locktime, u32(2))
}

@(test)
test_compact_block_missing_tx :: proc(t: ^testing.T) {
	// Same as above but one tx is NOT in the simulated mempool.
	coinbase_tx := _make_cmpct_test_tx(0)
	tx1 := _make_cmpct_test_tx(1)
	tx2 := _make_cmpct_test_tx(2)

	wtxid1 := wire.tx_witness_id(&tx1)
	wtxid2 := wire.tx_witness_id(&tx2)

	header := wire.Block_Header{version = 1, timestamp = 54321, bits = 0x1d00ffff, nonce = 77}
	block_hash := wire.block_header_hash(&header)
	cmpct_nonce: u64 = 99

	key_buf: [40]byte
	copy(key_buf[:32], block_hash[:])
	key_buf[32] = u8(cmpct_nonce)
	key_hash := crypto.sha256_hash(key_buf[:])
	k0 := _u64le(key_hash[:8])
	k1 := _u64le(key_hash[8:16])

	sid1 := crypto.compact_block_shortid(k0, k1, wtxid1)
	sid2 := crypto.compact_block_shortid(k0, k1, wtxid2)

	// Only tx1 is in the "mempool" — tx2 is missing.
	sid_map := make(map[u64]^wire.Tx, 4, context.temp_allocator)
	sid_map[sid1] = &tx1

	prefilled := []wire.Prefilled_Tx{{index = 0, tx = coinbase_tx}}
	shortids := []u64{sid1, sid2}
	total_txs := len(shortids) + len(prefilled)

	tx_ptrs := make([]^wire.Tx, total_txs, context.temp_allocator)
	shortid_cursor := 0
	missing_count := 0
	missing_indices := make([dynamic]u64, 0, 4, context.temp_allocator)

	prefilled_positions := make(map[u64]int, len(prefilled), context.temp_allocator)
	for i in 0 ..< len(prefilled) {
		prefilled_positions[prefilled[i].index] = i
	}

	for pos in 0 ..< total_txs {
		pi, is_prefilled := prefilled_positions[u64(pos)]
		if is_prefilled {
			tx_ptrs[pos] = &prefilled[pi].tx
		} else {
			sid := shortids[shortid_cursor]
			shortid_cursor += 1
			mp_tx, found := sid_map[sid]
			if found {
				tx_ptrs[pos] = mp_tx
			} else {
				missing_count += 1
				append(&missing_indices, u64(pos))
			}
		}
	}

	// Exactly 1 tx should be missing.
	testing.expect_value(t, missing_count, 1)
	testing.expect_value(t, len(missing_indices), 1)
	testing.expect_value(t, missing_indices[0], u64(2)) // tx2 was at position 2

	// Simulate blocktxn response: fill the missing slot.
	tx_ptrs[missing_indices[0]] = &tx2

	// Assemble block and verify.
	block := _assemble_block(&header, tx_ptrs)
	testing.expect_value(t, len(block.txs), 3)
	testing.expect_value(t, block.txs[0].locktime, u32(0))
	testing.expect_value(t, block.txs[1].locktime, u32(1))
	testing.expect_value(t, block.txs[2].locktime, u32(2))
}

// --- BIP324 Crypto Primitive Tests ---

@(test)
test_bip324_key_derivation :: proc(t: ^testing.T) {
	// Derive keys from a known shared secret and verify both sides get matching session_id.
	shared_secret: [32]byte
	shared_secret[0] = 0xAB
	shared_secret[31] = 0xCD

	test_magic: u32 = 0xD9B4BEF9  // mainnet magic

	keys_init := bip324_derive_keys(shared_secret, true, test_magic)
	keys_resp := bip324_derive_keys(shared_secret, false, test_magic)

	// Session IDs must match.
	testing.expect_value(t, keys_init.session_id, keys_resp.session_id)

	// Initiator's send keys should be responder's recv keys.
	testing.expect_value(t, keys_init.send_L_key, keys_resp.recv_L_key)
	testing.expect_value(t, keys_init.send_P_key, keys_resp.recv_P_key)
	testing.expect_value(t, keys_init.recv_L_key, keys_resp.send_L_key)
	testing.expect_value(t, keys_init.recv_P_key, keys_resp.send_P_key)

	// Garbage terminators: initiator's send = responder's recv, vice versa.
	testing.expect_value(t, keys_init.send_garbage_term, keys_resp.recv_garbage_term)
	testing.expect_value(t, keys_init.recv_garbage_term, keys_resp.send_garbage_term)
}

@(test)
test_bip324_key_derivation_vector :: proc(t: ^testing.T) {
	// BIP324 test vector 1: verify HKDF key derivation against known values.
	// mid_shared_secret from packet_encoding_test_vectors.csv (in_initiating=1).
	shared_secret: [32]byte
	copy(shared_secret[:], _hex("c6992a117f5edbea70c3f511d32d26b9798be4b81a62eaee1a5acaa8459a3592"))

	keys := bip324_derive_keys(shared_secret, true, 0xD9B4BEF9)

	expected_init_L: [32]byte
	copy(expected_init_L[:], _hex("9a6478b5fbab1f4dd2f78994b774c03211c78312786e602da75a0d1767fb55cf"))
	testing.expect(t, keys.send_L_key == expected_init_L,
		fmt.tprintf("initiator_L mismatch: got %s", string(hex.encode(keys.send_L_key[:], context.temp_allocator))))

	expected_init_P: [32]byte
	copy(expected_init_P[:], _hex("7d0c7820ba6a4d29ce40baf2caa6035e04f1e1cefd59f3e7e59e9e5af84f1f51"))
	testing.expect(t, keys.send_P_key == expected_init_P,
		fmt.tprintf("initiator_P mismatch: got %s", string(hex.encode(keys.send_P_key[:], context.temp_allocator))))

	expected_resp_L: [32]byte
	copy(expected_resp_L[:], _hex("17bc726421e4054ac6a1d54915085aaa766f4d3cf67bbd168e6080eac289d15e"))
	testing.expect(t, keys.recv_L_key == expected_resp_L,
		fmt.tprintf("responder_L mismatch: got %s", string(hex.encode(keys.recv_L_key[:], context.temp_allocator))))

	expected_resp_P: [32]byte
	copy(expected_resp_P[:], _hex("9f0fc1c0e85fd9a8eee07e6fc41dba2ff54c7729068a239ac97c37c524cca1c0"))
	testing.expect(t, keys.recv_P_key == expected_resp_P,
		fmt.tprintf("responder_P mismatch: got %s", string(hex.encode(keys.recv_P_key[:], context.temp_allocator))))

	expected_send_garbage: [16]byte
	copy(expected_send_garbage[:], _hex("faef555dfcdb936425d84aba524758f3"))
	testing.expect(t, keys.send_garbage_term == expected_send_garbage,
		fmt.tprintf("send_garbage_term mismatch: got %s", string(hex.encode(keys.send_garbage_term[:], context.temp_allocator))))

	expected_recv_garbage: [16]byte
	copy(expected_recv_garbage[:], _hex("02cb8ff24307a6e27de3b4e7ea3fa65b"))
	testing.expect(t, keys.recv_garbage_term == expected_recv_garbage,
		fmt.tprintf("recv_garbage_term mismatch: got %s", string(hex.encode(keys.recv_garbage_term[:], context.temp_allocator))))

	expected_session_id: [32]byte
	copy(expected_session_id[:], _hex("ce72dffb015da62b0d0f5474cab8bc72605225b0cee3f62312ec680ec5f41ba5"))
	testing.expect(t, keys.session_id == expected_session_id,
		fmt.tprintf("session_id mismatch: got %s", string(hex.encode(keys.session_id[:], context.temp_allocator))))
}

@(test)
test_fschacha20 :: proc(t: ^testing.T) {
	// Encrypt then decrypt should roundtrip.
	key: [32]byte
	key[0] = 0x42

	enc_ctx: FSChaCha20
	dec_ctx: FSChaCha20
	fschacha20_init(&enc_ctx, key)
	fschacha20_init(&dec_ctx, key)

	plaintext := [8]byte{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
	ciphertext: [8]byte
	recovered: [8]byte

	fschacha20_crypt(&enc_ctx, ciphertext[:], plaintext[:])
	fschacha20_crypt(&dec_ctx, recovered[:], ciphertext[:])

	testing.expect_value(t, recovered, plaintext)

	// Ciphertext should differ from plaintext.
	testing.expect(t, ciphertext != plaintext, "ciphertext should differ from plaintext")
}

@(test)
test_fschacha20_rekey :: proc(t: ^testing.T) {
	// Verify that after 2^24 encryptions, the key changes (rekey).
	key: [32]byte
	key[0] = 0x99

	ctx: FSChaCha20
	fschacha20_init(&ctx, key)

	// Encrypt REKEY_INTERVAL messages.
	dummy_in := [3]byte{0x00, 0x00, 0x00}
	dummy_out: [3]byte
	for i in u64(0) ..< REKEY_INTERVAL {
		fschacha20_crypt(&ctx, dummy_out[:], dummy_in[:])
	}

	// After REKEY_INTERVAL encryptions, rekey should have occurred.
	testing.expect_value(t, ctx.chunk_counter, u32(0))
	testing.expect_value(t, ctx.rekey_counter, u64(1))
}

@(test)
test_fschacha20poly1305 :: proc(t: ^testing.T) {
	key: [32]byte
	key[0] = 0x77

	// Seal
	seal_ctx: FSChaCha20Poly1305
	fschacha20poly1305_init(&seal_ctx, key)

	plaintext := [16]byte{0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x42, 0x49, 0x50, 0x33, 0x32, 0x34, 0x21, 0x00, 0x00}
	aad := [4]byte{0xAA, 0xBB, 0xCC, 0xDD}
	ciphertext: [16]byte
	tag: [16]byte

	fschacha20poly1305_seal(&seal_ctx, ciphertext[:], tag[:], aad[:], plaintext[:])

	// Open
	open_ctx: FSChaCha20Poly1305
	fschacha20poly1305_init(&open_ctx, key)

	recovered: [16]byte
	ok := fschacha20poly1305_open(&open_ctx, recovered[:], aad[:], ciphertext[:], tag[:])
	testing.expect(t, ok, "AEAD open should succeed")
	testing.expect_value(t, recovered, plaintext)

	// Tampered tag should fail.
	tamper_ctx: FSChaCha20Poly1305
	fschacha20poly1305_init(&tamper_ctx, key)
	bad_tag := tag
	bad_tag[0] ~= 0xFF
	bad_out: [16]byte
	bad_ok := fschacha20poly1305_open(&tamper_ctx, bad_out[:], aad[:], ciphertext[:], bad_tag[:])
	testing.expect(t, !bad_ok, "tampered tag should fail AEAD open")
}

@(test)
test_bip324_short_command_ids :: proc(t: ^testing.T) {
	// All 28 commands should roundtrip.
	for i in 0 ..< 28 {
		cmd := V2_SHORT_COMMANDS[i]
		id, ok := bip324_command_to_short_id(cmd)
		testing.expect(t, ok, "should find short ID for command")
		testing.expect_value(t, id, u8(i + 1))

		back_cmd, back_ok := bip324_short_id_to_command(id)
		testing.expect(t, back_ok, "should find command for short ID")
		testing.expect_value(t, back_cmd, cmd)
	}

	// Unknown command should not have a short ID.
	_, unk_ok := bip324_command_to_short_id("unknown")
	testing.expect(t, !unk_ok, "unknown command should not have short ID")

	// Invalid ID should fail.
	_, inv_ok := bip324_short_id_to_command(0)
	testing.expect(t, !inv_ok, "ID 0 should not map to a command")
	_, inv2_ok := bip324_short_id_to_command(29)
	testing.expect(t, !inv2_ok, "ID 29 should not map to a command")
}

@(test)
test_bip324_message_encode_decode :: proc(t: ^testing.T) {
	// Short command (ping = ID 18).
	payload := [8]byte{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
	encoded := bip324_encode_message_content("ping", payload[:], context.temp_allocator)
	testing.expect_value(t, len(encoded), 1 + 1 + 8) // header + msg_type_id + payload
	testing.expect_value(t, encoded[0], u8(0))        // header: ignore=false
	testing.expect_value(t, encoded[1], u8(18))        // msg_type_id=18 (ping)

	cmd, dec_payload, ignore, ok := bip324_decode_message_content(encoded)
	testing.expect(t, ok, "decode should succeed")
	testing.expect(t, !ignore, "should not be ignore")
	testing.expect_value(t, cmd, "ping")
	testing.expect_value(t, len(dec_payload), 8)
	for i in 0 ..< 8 {
		testing.expect_value(t, dec_payload[i], payload[i])
	}

	// Long command (not in short ID table).
	long_encoded := bip324_encode_message_content("version", nil, context.temp_allocator)
	testing.expect_value(t, len(long_encoded), 1 + 1 + 12) // header + 0x00 + 12-byte cmd
	testing.expect_value(t, long_encoded[0], u8(0))         // header: ignore=false
	testing.expect_value(t, long_encoded[1], u8(0))         // msg_type=0 (long form)

	long_cmd, long_payload, long_ignore, long_ok := bip324_decode_message_content(long_encoded)
	testing.expect(t, long_ok, "long decode should succeed")
	testing.expect(t, !long_ignore, "should not be ignore")
	testing.expect_value(t, long_cmd, "version")
	testing.expect_value(t, len(long_payload), 0)
}

// --- BIP324 V2 Transport Tests ---

@(test)
test_v2_transport_handshake :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	// Simulate initiator and responder handshake.
	initiator: V2_Transport
	responder: V2_Transport

	ok_i := v2_transport_init(&initiator, true, wire.SIGNET_MAGIC)
	testing.expect(t, ok_i, "initiator init should succeed")
	defer v2_transport_destroy(&initiator)

	ok_r := v2_transport_init(&responder, false, wire.SIGNET_MAGIC)
	testing.expect(t, ok_r, "responder init should succeed")
	defer v2_transport_destroy(&responder)

	// Exchange ell64 bytes.
	init_ell := v2_transport_get_ell64(&initiator)
	resp_ell := v2_transport_get_ell64(&responder)

	// Initiator receives responder's ell64.
	msgs_i, err_i := v2_transport_receive(&initiator, resp_ell[:])
	testing.expect(t, err_i == .None || err_i == .Need_More_Data, "initiator should accept ell64")

	// Send handshake bytes (garbage term + auth + version).
	testing.expect(t, initiator.handshake_to_send != nil, "initiator should have handshake bytes to send")
	init_hs := initiator.handshake_to_send
	initiator.handshake_to_send = nil // caller takes ownership

	// Responder receives initiator's ell64.
	msgs_r, err_r := v2_transport_receive(&responder, init_ell[:])
	testing.expect(t, err_r == .None || err_r == .Need_More_Data, "responder should accept ell64")

	// Responder sends handshake bytes.
	testing.expect(t, responder.handshake_to_send != nil, "responder should have handshake bytes to send")
	resp_hs := responder.handshake_to_send
	responder.handshake_to_send = nil

	// Session IDs should match.
	testing.expect_value(t, initiator.keys.session_id, responder.keys.session_id)

	// Feed handshake bytes to the other side.
	// Responder gets initiator's handshake.
	msgs_r2, err_r2 := v2_transport_receive(&responder, init_hs)
	testing.expect(t, err_r2 == .None || err_r2 == .Need_More_Data,
		fmt.tprintf("responder handshake completion: %v", err_r2))

	// Initiator gets responder's handshake.
	msgs_i2, err_i2 := v2_transport_receive(&initiator, resp_hs)
	testing.expect(t, err_i2 == .None || err_i2 == .Need_More_Data,
		fmt.tprintf("initiator handshake completion: %v", err_i2))

	// Both should be Active.
	testing.expect_value(t, initiator.state, V2_State.Active)
	testing.expect_value(t, responder.state, V2_State.Active)

	delete(init_hs)
	delete(resp_hs)
}

@(test)
test_v2_transport_encrypt_decrypt :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	// Set up a connected pair.
	initiator: V2_Transport
	responder: V2_Transport
	v2_transport_init(&initiator, true, wire.REGTEST_MAGIC)
	defer v2_transport_destroy(&initiator)
	v2_transport_init(&responder, false, wire.REGTEST_MAGIC)
	defer v2_transport_destroy(&responder)

	// Exchange ell64.
	init_ell := v2_transport_get_ell64(&initiator)
	resp_ell := v2_transport_get_ell64(&responder)

	v2_transport_receive(&initiator, resp_ell[:])
	init_hs := initiator.handshake_to_send
	initiator.handshake_to_send = nil

	v2_transport_receive(&responder, init_ell[:])
	resp_hs := responder.handshake_to_send
	responder.handshake_to_send = nil

	v2_transport_receive(&responder, init_hs)
	v2_transport_receive(&initiator, resp_hs)

	testing.expect_value(t, initiator.state, V2_State.Active)
	testing.expect_value(t, responder.state, V2_State.Active)

	// Encrypt a ping message from initiator.
	ping_payload := [8]byte{0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE}
	encrypted := v2_transport_encrypt(&initiator, "ping", ping_payload[:])
	defer delete(encrypted)

	// Decrypt on responder side.
	msgs, err := v2_transport_receive(&responder, encrypted)
	testing.expect_value(t, err, V2_Error.None)
	testing.expect_value(t, len(msgs), 1)

	if len(msgs) > 0 {
		testing.expect_value(t, msgs[0].command, "ping")
		testing.expect_value(t, len(msgs[0].payload), 8)
		for i in 0 ..< 8 {
			testing.expect_value(t, msgs[0].payload[i], ping_payload[i])
		}
	}

	// And the reverse direction: responder → initiator.
	pong_payload := [8]byte{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08}
	encrypted2 := v2_transport_encrypt(&responder, "pong", pong_payload[:])
	defer delete(encrypted2)

	msgs2, err2 := v2_transport_receive(&initiator, encrypted2)
	testing.expect_value(t, err2, V2_Error.None)
	testing.expect_value(t, len(msgs2), 1)
	if len(msgs2) > 0 {
		testing.expect_value(t, msgs2[0].command, "pong")
	}

	delete(init_hs)
	delete(resp_hs)
}

// --- BIP324 Test Vector Verification ---

@(test)
test_bip324_test_vector_ecdh :: proc(t: ^testing.T) {
	// BIP324 packet_encoding_test_vectors.csv — Test Vector 1.
	// Verifies our ECDH output matches the official expected shared secret.
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	seckey_bytes := _hex("61062ea5071d800bbfd59e2e8b53d47d194b095ae5a4df04936b49772ef0d4d7")
	our_ell_bytes := _hex("ec0adff257bbfe500c188c80b4fdd640f6b45a482bbc15fc7cef5931deff0aa186f6eb9bba7b85dc4dcc28b28722de1e3d9108b985e2967045668f66098e475b")
	their_ell_bytes := _hex("a4a94dfce69b4a2a0a099313d10f9f7e7d649d60501c9e1d274c300e0d89aafaffffffffffffffffffffffffffffffffffffffffffffffffffffffff8faf88d5")
	expected_secret_bytes := _hex("c6992a117f5edbea70c3f511d32d26b9798be4b81a62eaee1a5acaa8459a3592")

	our_ell64: [64]byte
	their_ell64: [64]byte
	copy(our_ell64[:], our_ell_bytes)
	copy(their_ell64[:], their_ell_bytes)

	expected_secret: [32]byte
	copy(expected_secret[:], expected_secret_bytes)

	// Call ECDH as initiator (party=0).
	secret, ok := crypto.ellswift_ecdh_bip324(our_ell64, their_ell64, seckey_bytes, true)
	testing.expect(t, ok, "ECDH should succeed")
	testing.expect(t, secret == expected_secret,
		fmt.tprintf("ECDH secret mismatch:\n  got:      %s\n  expected: %s",
			string(hex.encode(secret[:], context.temp_allocator)),
			string(hex.encode(expected_secret[:], context.temp_allocator))))
}

@(test)
test_bip324_test_vector_keys :: proc(t: ^testing.T) {
	// BIP324 packet_encoding_test_vectors.csv — Test Vector 1.
	// Verifies key derivation from known shared secret.
	// Test vector is for initiator (in_initiating=1).
	shared_secret_bytes := _hex("c6992a117f5edbea70c3f511d32d26b9798be4b81a62eaee1a5acaa8459a3592")
	shared_secret: [32]byte
	copy(shared_secret[:], shared_secret_bytes)

	// Try with mainnet magic (test vectors default to mainnet).
	mainnet_magic: u32 = 0xD9B4BEF9
	keys := bip324_derive_keys(shared_secret, true, mainnet_magic)

	// Expected values from test vector (initiator side, so send=initiator, recv=responder).
	expected_session_id := _hex("ce72dffb015da62b0d0f5474cab8bc72605225b0cee3f62312ec680ec5f41ba5")
	expected_init_L := _hex("9a6478b5fbab1f4dd2f78994b774c03211c78312786e602da75a0d1767fb55cf")
	expected_init_P := _hex("7d0c7820ba6a4d29ce40baf2caa6035e04f1e1cefd59f3e7e59e9e5af84f1f51")
	expected_resp_L := _hex("17bc726421e4054ac6a1d54915085aaa766f4d3cf67bbd168e6080eac289d15e")
	expected_resp_P := _hex("9f0fc1c0e85fd9a8eee07e6fc41dba2ff54c7729068a239ac97c37c524cca1c0")
	expected_send_garbage := _hex("faef555dfcdb936425d84aba524758f3")
	expected_recv_garbage := _hex("02cb8ff24307a6e27de3b4e7ea3fa65b")

	// For initiator: send = initiator keys, recv = responder keys.
	session_ok := true
	for i in 0 ..< 32 { if keys.session_id[i] != expected_session_id[i] { session_ok = false; break } }
	testing.expect(t, session_ok,
		fmt.tprintf("session_id mismatch:\n  got:      %s\n  expected: %s",
			string(hex.encode(keys.session_id[:], context.temp_allocator)),
			string(hex.encode(expected_session_id, context.temp_allocator))))

	send_L_ok := true
	for i in 0 ..< 32 { if keys.send_L_key[i] != expected_init_L[i] { send_L_ok = false; break } }
	testing.expect(t, send_L_ok,
		fmt.tprintf("send_L_key (initiator_L) mismatch:\n  got:      %s\n  expected: %s",
			string(hex.encode(keys.send_L_key[:], context.temp_allocator)),
			string(hex.encode(expected_init_L, context.temp_allocator))))

	send_P_ok := true
	for i in 0 ..< 32 { if keys.send_P_key[i] != expected_init_P[i] { send_P_ok = false; break } }
	testing.expect(t, send_P_ok,
		fmt.tprintf("send_P_key (initiator_P) mismatch:\n  got:      %s\n  expected: %s",
			string(hex.encode(keys.send_P_key[:], context.temp_allocator)),
			string(hex.encode(expected_init_P, context.temp_allocator))))

	recv_L_ok := true
	for i in 0 ..< 32 { if keys.recv_L_key[i] != expected_resp_L[i] { recv_L_ok = false; break } }
	testing.expect(t, recv_L_ok,
		fmt.tprintf("recv_L_key (responder_L) mismatch:\n  got:      %s\n  expected: %s",
			string(hex.encode(keys.recv_L_key[:], context.temp_allocator)),
			string(hex.encode(expected_resp_L, context.temp_allocator))))

	recv_P_ok := true
	for i in 0 ..< 32 { if keys.recv_P_key[i] != expected_resp_P[i] { recv_P_ok = false; break } }
	testing.expect(t, recv_P_ok,
		fmt.tprintf("recv_P_key (responder_P) mismatch:\n  got:      %s\n  expected: %s",
			string(hex.encode(keys.recv_P_key[:], context.temp_allocator)),
			string(hex.encode(expected_resp_P, context.temp_allocator))))

	send_gt_ok := true
	for i in 0 ..< 16 { if keys.send_garbage_term[i] != expected_send_garbage[i] { send_gt_ok = false; break } }
	testing.expect(t, send_gt_ok, "send_garbage_term mismatch")

	recv_gt_ok := true
	for i in 0 ..< 16 { if keys.recv_garbage_term[i] != expected_recv_garbage[i] { recv_gt_ok = false; break } }
	testing.expect(t, recv_gt_ok, "recv_garbage_term mismatch")
}

@(test)
test_bip324_packet_encoding_vector :: proc(t: ^testing.T) {
	// BIP324 packet_encoding_test_vectors.csv — rows 0 and 1 (in_initiating=1).
	// Verifies FSChaCha20 (continuous stream) + FSChaCha20Poly1305 encryption.

	send_L_key: [32]byte
	send_P_key: [32]byte
	copy(send_L_key[:], _hex("9a6478b5fbab1f4dd2f78994b774c03211c78312786e602da75a0d1767fb55cf"))
	copy(send_P_key[:], _hex("7d0c7820ba6a4d29ce40baf2caa6035e04f1e1cefd59f3e7e59e9e5af84f1f51"))

	send_L: FSChaCha20
	send_P: FSChaCha20Poly1305
	fschacha20_init(&send_L, send_L_key)
	fschacha20poly1305_init(&send_P, send_P_key)

	// --- Row 0: in_idx=0, in_contents="", in_ignore=0, in_aad="" ---
	// Process row 0 to advance FSChaCha20 stream and FSChaCha20Poly1305 counter.
	{
		len_plain_0 := [3]byte{0, 0, 0} // contents.size() = 0
		len_ct_0: [3]byte
		fschacha20_crypt(&send_L, len_ct_0[:], len_plain_0[:])

		aead_plain_0 := [1]byte{0x00} // header only
		aead_ct_0: [1]byte
		aead_tag_0: [16]byte
		fschacha20poly1305_seal(&send_P, aead_ct_0[:], aead_tag_0[:], nil, aead_plain_0[:])
	}

	// --- Row 1: in_idx=1, in_contents=0x8e, in_ignore=0, in_aad="" ---
	len_plain := [3]byte{1, 0, 0} // contents.size() = 1
	len_ct: [3]byte
	fschacha20_crypt(&send_L, len_ct[:], len_plain[:])

	aead_plain := [2]byte{0x00, 0x8e} // header + contents
	aead_ct: [2]byte
	aead_tag: [16]byte
	fschacha20poly1305_seal(&send_P, aead_ct[:], aead_tag[:], nil, aead_plain[:])

	wire: [21]byte
	copy(wire[:3], len_ct[:])
	copy(wire[3:5], aead_ct[:])
	copy(wire[5:], aead_tag[:])

	expected: [21]byte
	copy(expected[:], _hex("7530d2a18720162ac09c25329a60d75adf36eda3c3"))

	testing.expect(t, wire == expected,
		fmt.tprintf("packet encoding mismatch:\n  got:      %s\n  expected: %s",
			string(hex.encode(wire[:], context.temp_allocator)),
			string(hex.encode(expected[:], context.temp_allocator))))
}

// --- Inbound Connection Tests ---

@(test)
test_connection_budget :: proc(t: ^testing.T) {
	// Verify max_inbound = max(max_connections - max_outbound - 1, 0)

	// Default: 125 total → 125 - 8 - 1 = 116 inbound
	testing.expect_value(t, max(125 - MAX_OUTBOUND_FULL_RELAY - 1, 0), 116)

	// Small: 10 total → 10 - 8 - 1 = 1 inbound
	testing.expect_value(t, max(10 - MAX_OUTBOUND_FULL_RELAY - 1, 0), 1)

	// Tight: 9 total → 9 - 8 - 1 = 0 inbound
	testing.expect_value(t, max(9 - MAX_OUTBOUND_FULL_RELAY - 1, 0), 0)

	// At outbound: 8 total → 8 - 8 - 1 = -1 → clamped to 0
	testing.expect_value(t, max(8 - MAX_OUTBOUND_FULL_RELAY - 1, 0), 0)

	// Zero: 0 total → 0 - 8 - 1 = -9 → clamped to 0
	testing.expect_value(t, max(0 - MAX_OUTBOUND_FULL_RELAY - 1, 0), 0)
}

@(test)
test_node_p2p_v2_service_bit :: proc(t: ^testing.T) {
	// Verify NODE_P2P_V2 == 2048 (1 << 11).
	testing.expect_value(t, NODE_P2P_V2, u64(2048))

	// Verify LOCAL_SERVICES includes NODE_NETWORK, NODE_NETWORK_LIMITED, NODE_WITNESS.
	testing.expect(t, LOCAL_SERVICES & NODE_NETWORK != 0, "LOCAL_SERVICES should include NODE_NETWORK")
	testing.expect(t, LOCAL_SERVICES & NODE_NETWORK_LIMITED != 0, "LOCAL_SERVICES should include NODE_NETWORK_LIMITED")
	testing.expect(t, LOCAL_SERVICES & NODE_WITNESS != 0, "LOCAL_SERVICES should include NODE_WITNESS")

	// DEFAULT_MAX_CONNECTIONS should be 125.
	testing.expect_value(t, DEFAULT_MAX_CONNECTIONS, 125)
	// MAX_OUTBOUND_FULL_RELAY should be 8.
	testing.expect_value(t, MAX_OUTBOUND_FULL_RELAY, 8)
}

@(test)
test_v2_responder_init :: proc(t: ^testing.T) {
	crypto.init_secp256k1()
	defer crypto.destroy_secp256k1()

	// Verify v2_transport_init succeeds in responder mode (initiating=false).
	transport: V2_Transport
	ok := v2_transport_init(&transport, false, wire.SIGNET_MAGIC)
	testing.expect(t, ok, "v2_transport_init should succeed for responder")
	defer v2_transport_destroy(&transport)

	// Should produce a valid ell64 (64 bytes, not all zeros).
	ell := v2_transport_get_ell64(&transport)
	all_zero := true
	for b in ell {
		if b != 0 {
			all_zero = false
			break
		}
	}
	testing.expect(t, !all_zero, "responder ell64 should not be all zeros")

	// State should be Awaiting_EllSwift (waiting for initiator's ell64).
	testing.expect_value(t, transport.state, V2_State.Awaiting_EllSwift)
}
