package drivechain

import "core:testing"

_mk_m1 :: proc(sidechain: u8, title: string, allocator := context.temp_allocator) -> []byte {
	out := make([dynamic]byte, 0, 128, allocator)
	append(&out, 0xd5, 0xe0, 0xc4, 0xaf)
	append(&out, sidechain)
	append(&out, 1, 0, 0, 0)
	append(&out, title)
	append(&out, 0)
	append(&out, "test sidechain")
	for _ in 0 ..< 32 { append(&out, 0xaa) }
	for _ in 0 ..< 20 { append(&out, 0xbb) }
	return out[:]
}

_mk_m2 :: proc(commitment: [32]byte, allocator := context.temp_allocator) -> []byte {
	out := make([dynamic]byte, 0, 36, allocator)
	append(&out, 0xd6, 0xe1, 0xc5, 0xbf)
	c := commitment
	append(&out, ..c[:])
	return out[:]
}

_mk_m3 :: proc(sidechain: u8, seed: byte, allocator := context.temp_allocator) -> []byte {
	out := make([dynamic]byte, 0, 37, allocator)
	append(&out, 0xd4, 0x5a, 0xa9, 0x43)
	for _ in 0 ..< 32 { append(&out, seed) }
	append(&out, sidechain)
	return out[:]
}

_mk_m4_v1 :: proc(votes: []byte, allocator := context.temp_allocator) -> []byte {
	out := make([dynamic]byte, 0, 8, allocator)
	append(&out, 0xd7, 0x7d, 0x17, 0x76)
	append(&out, 0x01)
	append(&out, ..votes)
	return out[:]
}

@(test)
test_codec_roundtrips :: proc(t: ^testing.T) {
	m1_raw := _mk_m1(5, "TestChain")
	m1, ok := parse_m1(m1_raw)
	testing.expect(t, ok, "m1 parses")
	testing.expect_value(t, m1.sidechain, u8(5))
	testing.expect_value(t, m1.version, i32(1))
	testing.expect_value(t, m1.title, "TestChain")
	testing.expect_value(t, m1.description, "test sidechain")
	testing.expect_value(t, m1.hash_id_1[0], byte(0xaa))
	testing.expect_value(t, m1.hash_id_2[19], byte(0xbb))

	c := m1_commitment_hash(&m1)
	m2, ok2 := parse_m2(_mk_m2(c))
	testing.expect(t, ok2, "m2 parses")
	testing.expect_value(t, m2.proposal_hash, c)

	m3, ok3 := parse_m3(_mk_m3(7, 0xcd))
	testing.expect(t, ok3, "m3 parses")
	testing.expect_value(t, m3.sidechain, u8(7))
	testing.expect_value(t, m3.bundle_hash[0], byte(0xcd))

	m4, ok4 := parse_m4(_mk_m4_v1([]byte{0x00, 0xff, 0xfe}), 3)
	testing.expect(t, ok4, "m4 parses")
	testing.expect_value(t, m4.votes[0], u16(0))
	testing.expect_value(t, m4.votes[1], u16(0xff))
	testing.expect_value(t, m4.votes[2], u16(0xfe))

	_, bad := parse_m4(_mk_m4_v1([]byte{0x00}), 3)
	testing.expect(t, !bad, "m4 wrong width rejected")
}

@(test)
test_activation_and_failout :: proc(t: ^testing.T) {
	st: State
	state_init(&st)
	defer state_destroy(&st)

	m1_raw := _mk_m1(3, "Activates")
	m1, _ := parse_m1(m1_raw)
	ack := _mk_m2(m1_commitment_hash(&m1))
	apply_block(&st, [][]byte{m1_raw}, 100)
	testing.expect_value(t, len(st.proposals), 1)

	// ACK every block through the 2016-block window -> activates.
	for h in 101 ..< 101 + NEW_SLOT_WINDOW {
		apply_block(&st, [][]byte{ack}, h)
	}
	testing.expect_value(t, len(st.proposals), 0)
	testing.expect(t, st.slots[3].active, "slot 3 active")
	testing.expect_value(t, st.slots[3].title, "Activates")

	// A second proposal that nobody acks fails out at 1008 fails.
	m1b_raw := _mk_m1(9, "FailsOut")
	apply_block(&st, [][]byte{m1b_raw}, 5000)
	for h in 5001 ..< 5001 + NEW_SLOT_MAX_FAILS {
		apply_block(&st, [][]byte{}, h)
	}
	testing.expect_value(t, len(st.proposals), 0)
	testing.expect(t, !st.slots[9].active, "slot 9 never activates")
}

@(test)
test_bundle_ack_mechanics :: proc(t: ^testing.T) {
	st: State
	state_init(&st)
	defer state_destroy(&st)
	st.slots[0].active = true // hand-activate slot 0

	apply_block(&st, [][]byte{_mk_m3(0, 0x11)}, 10)
	testing.expect_value(t, len(st.bundles), 1)
	testing.expect_value(t, st.bundles[0].acks, u16(BUNDLE_START_ACKS))

	// Upvote it (vote index 0 of sidechain 0) for 5 blocks.
	up := _mk_m4_v1([]byte{0x00})
	for h in 11 ..< 16 {
		apply_block(&st, [][]byte{up}, h)
	}
	testing.expect_value(t, st.bundles[0].acks, u16(BUNDLE_START_ACKS + 5))

	// Abstain: acks unchanged.
	abstain := _mk_m4_v1([]byte{0xff})
	apply_block(&st, [][]byte{abstain}, 16)
	testing.expect_value(t, st.bundles[0].acks, u16(BUNDLE_START_ACKS + 5))

	// Alarm: everything decays.
	alarm := _mk_m4_v1([]byte{0xfe})
	apply_block(&st, [][]byte{alarm}, 17)
	testing.expect_value(t, st.bundles[0].acks, u16(BUNDLE_START_ACKS + 4))

	// M4 version 0x00 repeats the previous explicit vote (the alarm block
	// stored [0xfe]; a 0x00 M4 repeats that = decay again).
	repeat := []byte{0xd7, 0x7d, 0x17, 0x76, 0x00}
	apply_block(&st, [][]byte{repeat}, 18)
	testing.expect_value(t, st.bundles[0].acks, u16(BUNDLE_START_ACKS + 3))
}

@(test)
test_bundle_impossible_pruned :: proc(t: ^testing.T) {
	st: State
	state_init(&st)
	defer state_destroy(&st)
	st.slots[0].active = true

	apply_block(&st, [][]byte{_mk_m3(0, 0x22)}, 10)
	// Force the impossible condition: 13150 - acks > remaining.
	st.bundles[0].remaining = 100
	st.bundles[0].acks = 10
	apply_block(&st, [][]byte{}, 11)
	testing.expect_value(t, len(st.bundles), 0)
}

@(test)
test_snapshot_roundtrip :: proc(t: ^testing.T) {
	st: State
	state_init(&st)
	defer state_destroy(&st)

	m1_raw := _mk_m1(3, "Snap")
	apply_block(&st, [][]byte{m1_raw}, 100)
	st.slots[7].active = true
	st.slots[7].title = _clone_string("Existing")
	st.slots[7].ctip_amount = 12345
	apply_block(&st, [][]byte{_mk_m3(7, 0x33)}, 101)
	apply_block(&st, [][]byte{_mk_m4_v1([]byte{0x00})}, 102)

	blob := serialize_state(&st)
	defer delete(blob)

	st2: State
	state_init(&st2)
	defer state_destroy(&st2)
	ok := deserialize_state(blob, &st2)
	testing.expect(t, ok, "deserializes")

	testing.expect_value(t, st2.slots[7].active, true)
	testing.expect_value(t, st2.slots[7].title, "Existing")
	testing.expect_value(t, st2.slots[7].ctip_amount, i64(12345))
	testing.expect_value(t, len(st2.proposals), len(st.proposals))
	testing.expect_value(t, len(st2.bundles), len(st.bundles))
	testing.expect_value(t, st2.bundles[0].acks, st.bundles[0].acks)
	testing.expect_value(t, len(st2.last_m4), len(st.last_m4))

	blob2 := serialize_state(&st2)
	defer delete(blob2)
	testing.expect_value(t, len(blob2), len(blob))
	same := true
	for b, i in blob {
		if blob2[i] != b { same = false; break }
	}
	testing.expect(t, same, "byte-identical re-serialization")
}
