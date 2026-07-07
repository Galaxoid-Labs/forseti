// Snapshot (de)serialization — used both for LevelDB persistence and as the
// per-block undo record (D1+D2 are small enough that full snapshots beat
// operation logs on simplicity and reorg-safety).
package drivechain

import "core:encoding/endian"

serialize_state :: proc(st: ^State, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, 0, 1024, allocator)

	w_u16 :: proc(out: ^[dynamic]byte, v: u16) { b: [2]byte; endian.unchecked_put_u16le(b[:], v); append(out, ..b[:]) }
	w_u32 :: proc(out: ^[dynamic]byte, v: u32) { b: [4]byte; endian.unchecked_put_u32le(b[:], v); append(out, ..b[:]) }
	w_u64 :: proc(out: ^[dynamic]byte, v: u64) { b: [8]byte; endian.unchecked_put_u64le(b[:], v); append(out, ..b[:]) }
	w_str :: proc(out: ^[dynamic]byte, s: string) { w_u16(out, u16(len(s))); append(out, s) }

	append(&out, byte(1)) // version

	n_active := 0
	for s in st.slots { if s.active { n_active += 1 } }
	w_u16(&out, u16(n_active))
	for &s, i in st.slots {
		if !s.active { continue }
		append(&out, byte(i))
		w_u32(&out, u32(s.version))
		w_str(&out, s.title)
		w_str(&out, s.description)
		append(&out, ..s.hash_id_1[:])
		append(&out, ..s.hash_id_2[:])
		w_u32(&out, u32(s.activated_h))
		append(&out, ..s.ctip_txid[:])
		w_u32(&out, u32(s.ctip_vout))
		w_u64(&out, u64(s.ctip_amount))
	}

	w_u16(&out, u16(len(st.proposals)))
	for &p in st.proposals {
		append(&out, p.sidechain)
		w_u32(&out, u32(p.version))
		w_str(&out, p.title)
		w_str(&out, p.description)
		append(&out, ..p.hash_id_1[:])
		append(&out, ..p.hash_id_2[:])
		append(&out, ..p.commitment[:])
		w_u32(&out, u32(p.age))
		w_u32(&out, u32(p.fails))
		append(&out, p.overwriting ? 1 : 0)
	}

	w_u16(&out, u16(len(st.bundles)))
	for &b in st.bundles {
		append(&out, b.sidechain)
		append(&out, ..b.hash[:])
		w_u16(&out, b.acks)
		w_u16(&out, b.remaining)
		append(&out, b.approved ? 1 : 0)
	}

	w_u16(&out, u16(len(st.last_m4)))
	for v in st.last_m4 { w_u16(&out, v) }

	return out[:]
}

deserialize_state :: proc(data: []byte, st: ^State) -> bool {
	// st must be freshly initialized (state_init) and empty.
	pos := 0
	r_bytes :: proc(data: []byte, pos: ^int, n: int) -> ([]byte, bool) {
		if pos^ + n > len(data) { return nil, false }
		s := data[pos^:pos^ + n]
		pos^ += n
		return s, true
	}
	r_u16 :: proc(data: []byte, pos: ^int) -> (u16, bool) {
		s, ok := r_bytes(data, pos, 2)
		if !ok { return 0, false }
		return endian.unchecked_get_u16le(s), true
	}
	r_u32 :: proc(data: []byte, pos: ^int) -> (u32, bool) {
		s, ok := r_bytes(data, pos, 4)
		if !ok { return 0, false }
		return endian.unchecked_get_u32le(s), true
	}
	r_u64 :: proc(data: []byte, pos: ^int) -> (u64, bool) {
		s, ok := r_bytes(data, pos, 8)
		if !ok { return 0, false }
		return endian.unchecked_get_u64le(s), true
	}
	r_str :: proc(data: []byte, pos: ^int) -> (string, bool) {
		n, ok := r_u16(data, pos)
		if !ok { return "", false }
		s, ok2 := r_bytes(data, pos, int(n))
		if !ok2 { return "", false }
		return _clone_string(string(s)), true
	}

	ver, vok := r_bytes(data, &pos, 1)
	if !vok || ver[0] != 1 { return false }

	n_active, ok := r_u16(data, &pos)
	if !ok { return false }
	for _ in 0 ..< n_active {
		idx, i_ok := r_bytes(data, &pos, 1)
		if !i_ok { return false }
		s := &st.slots[idx[0]]
		s.active = true
		v, _ := r_u32(data, &pos); s.version = i32(v)
		t, t_ok := r_str(data, &pos); if !t_ok { return false }
		s.title = t
		d, d_ok := r_str(data, &pos); if !d_ok { return false }
		s.description = d
		h1, _ := r_bytes(data, &pos, 32); copy(s.hash_id_1[:], h1)
		h2, h2_ok := r_bytes(data, &pos, 20); if !h2_ok { return false }
		copy(s.hash_id_2[:], h2)
		ah, _ := r_u32(data, &pos); s.activated_h = int(ah)
		ct, ct_ok := r_bytes(data, &pos, 32); if !ct_ok { return false }
		copy(s.ctip_txid[:], ct)
		cv, _ := r_u32(data, &pos); s.ctip_vout = i32(cv)
		ca, ca_ok := r_u64(data, &pos); if !ca_ok { return false }
		s.ctip_amount = i64(ca)
	}

	n_props, p_ok := r_u16(data, &pos)
	if !p_ok { return false }
	for _ in 0 ..< n_props {
		p: Proposal
		sc, sc_ok := r_bytes(data, &pos, 1); if !sc_ok { return false }
		p.sidechain = sc[0]
		v, _ := r_u32(data, &pos); p.version = i32(v)
		t, t_ok := r_str(data, &pos); if !t_ok { return false }
		p.title = t
		d, d_ok := r_str(data, &pos); if !d_ok { return false }
		p.description = d
		h1, _ := r_bytes(data, &pos, 32); copy(p.hash_id_1[:], h1)
		h2, _ := r_bytes(data, &pos, 20); copy(p.hash_id_2[:], h2)
		cm, cm_ok := r_bytes(data, &pos, 32); if !cm_ok { return false }
		copy(p.commitment[:], cm)
		age, _ := r_u32(data, &pos); p.age = int(age)
		fl, fl_ok := r_u32(data, &pos); if !fl_ok { return false }
		p.fails = int(fl)
		ow, ow_ok := r_bytes(data, &pos, 1); if !ow_ok { return false }
		p.overwriting = ow[0] == 1
		append(&st.proposals, p)
	}

	n_bundles, b_ok := r_u16(data, &pos)
	if !b_ok { return false }
	for _ in 0 ..< n_bundles {
		b: Bundle
		sc, sc_ok := r_bytes(data, &pos, 1); if !sc_ok { return false }
		b.sidechain = sc[0]
		h, _ := r_bytes(data, &pos, 32); copy(b.hash[:], h)
		b.acks, _ = r_u16(data, &pos)
		b.remaining, _ = r_u16(data, &pos)
		ap, ap_ok := r_bytes(data, &pos, 1); if !ap_ok { return false }
		b.approved = ap[0] == 1
		append(&st.bundles, b)
	}

	n_votes, v_ok := r_u16(data, &pos)
	if !v_ok { return false }
	if n_votes > 0 {
		st.last_m4 = make([]u16, n_votes)
		for i in 0 ..< int(n_votes) {
			st.last_m4[i], _ = r_u16(data, &pos)
		}
	}
	return true
}
