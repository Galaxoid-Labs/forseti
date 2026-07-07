// BIP300/301 message codecs. All five coinbase messages are OP_RETURN
// outputs whose payload begins with a fixed 4-byte tag; the BMM request
// (BIP301 M8) rides in regular transactions.
//
// M1 spec looseness: title/description are raw undelimited bytes. The head
// (nSidechain + nVersion) and tail (hashID1 + hashID2) are fixed-size, so we
// parse from both ends and split the middle text blob at the first NUL
// (title\0description); no NUL = all title.
package drivechain

import btccrypto "../crypto"

TAG_M1_PROPOSE   :: [4]byte{0xd5, 0xe0, 0xc4, 0xaf}
TAG_M2_ACK       :: [4]byte{0xd6, 0xe1, 0xc5, 0xbf}
TAG_M3_BUNDLE    :: [4]byte{0xd4, 0x5a, 0xa9, 0x43}
TAG_M4_ACK_VOTES :: [4]byte{0xd7, 0x7d, 0x17, 0x76}
TAG_BMM_ACCEPT   :: [4]byte{0xd1, 0x61, 0x73, 0x68} // BIP301 h* commitment

M4_VOTE_ABSTAIN :: 0xff
M4_VOTE_ALARM   :: 0xfe

M1_Propose :: struct {
	sidechain:   u8,
	version:     i32,
	title:       string, // views into the parsed payload
	description: string,
	hash_id_1:   [32]byte,
	hash_id_2:   [20]byte,
	raw:         []byte, // full payload after the tag (for the M2 commitment hash)
}

M2_Ack :: struct {
	proposal_hash: [32]byte, // sha256d of the M1 serialization
}

M3_Bundle :: struct {
	bundle_hash: [32]byte,
	sidechain:   u8,
}

M4_Votes :: struct {
	version: u8,
	votes:   []u16, // one per active sidechain; ABSTAIN/ALARM appear as 0xff/0xfe (widened)
}

BMM_Accept :: struct {
	sidechain: u8,
	h_star:    [32]byte,
}

// Extract the OP_RETURN payload: 0x6a followed by pushdata opcodes.
// Returns nil if the script is not a parseable OP_RETURN data script.
op_return_payload :: proc(spk: []byte) -> []byte {
	if len(spk) < 2 || spk[0] != 0x6a {
		return nil
	}
	i := 1
	op := spk[i]
	switch {
	case op <= 75:
		i += 1
	case op == 0x4c: // OP_PUSHDATA1
		if len(spk) < 3 { return nil }
		i += 2
	case op == 0x4d: // OP_PUSHDATA2
		if len(spk) < 4 { return nil }
		i += 3
	case:
		return nil
	}
	return spk[i:]
}

_has_tag :: proc(payload: []byte, tag: [4]byte) -> bool {
	return len(payload) >= 4 &&
		payload[0] == tag[0] && payload[1] == tag[1] &&
		payload[2] == tag[2] && payload[3] == tag[3]
}

parse_m1 :: proc(payload: []byte) -> (m: M1_Propose, ok: bool) {
	if !_has_tag(payload, TAG_M1_PROPOSE) {
		return {}, false
	}
	body := payload[4:]
	// fixed head 1+4, fixed tail 32+20
	if len(body) < 5 + 52 {
		return {}, false
	}
	m.raw = body
	m.sidechain = body[0]
	m.version = i32(body[1]) | i32(body[2]) << 8 | i32(body[3]) << 16 | i32(body[4]) << 24
	tail := body[len(body) - 52:]
	copy(m.hash_id_1[:], tail[:32])
	copy(m.hash_id_2[:], tail[32:])
	text := body[5:len(body) - 52]
	split := -1
	for b, i in text {
		if b == 0 {
			split = i
			break
		}
	}
	if split >= 0 {
		m.title = string(text[:split])
		m.description = string(text[split + 1:])
	} else {
		m.title = string(text)
	}
	return m, true
}

// The hash M2 commits to: sha256d over the M1 body (everything after the tag).
m1_commitment_hash :: proc(m: ^M1_Propose) -> [32]byte {
	return btccrypto.sha256d(m.raw)
}

parse_m2 :: proc(payload: []byte) -> (m: M2_Ack, ok: bool) {
	if !_has_tag(payload, TAG_M2_ACK) || len(payload) != 4 + 32 {
		return {}, false
	}
	copy(m.proposal_hash[:], payload[4:])
	return m, true
}

parse_m3 :: proc(payload: []byte) -> (m: M3_Bundle, ok: bool) {
	if !_has_tag(payload, TAG_M3_BUNDLE) || len(payload) != 4 + 33 {
		return {}, false
	}
	copy(m.bundle_hash[:], payload[4:36])
	m.sidechain = payload[36]
	return m, true
}

// n_sidechains = number of ACTIVE sidechain slots (determines vector width).
parse_m4 :: proc(payload: []byte, n_sidechains: int, allocator := context.temp_allocator) -> (m: M4_Votes, ok: bool) {
	if !_has_tag(payload, TAG_M4_ACK_VOTES) || len(payload) < 5 {
		return {}, false
	}
	m.version = payload[4]
	vec := payload[5:]
	switch m.version {
	case 0x00, 0x03:
		// 0x00 repeats the previous block's M4; 0x03 upvotes leaders-by-50.
		// Both carry no vector; semantic handling is the state machine's job.
		if len(vec) != 0 {
			return {}, false
		}
		return m, true
	case 0x01:
		if len(vec) != n_sidechains {
			return {}, false
		}
		m.votes = make([]u16, n_sidechains, allocator)
		for b, i in vec {
			m.votes[i] = b == 0xff ? 0xff : b == 0xfe ? 0xfe : u16(b)
		}
		return m, true
	case 0x02:
		if len(vec) != n_sidechains * 2 {
			return {}, false
		}
		m.votes = make([]u16, n_sidechains, allocator)
		for i in 0 ..< n_sidechains {
			m.votes[i] = u16(vec[i * 2]) | u16(vec[i * 2 + 1]) << 8
		}
		return m, true
	}
	return {}, false
}

parse_bmm_accept :: proc(payload: []byte) -> (m: BMM_Accept, ok: bool) {
	if !_has_tag(payload, TAG_BMM_ACCEPT) || len(payload) != 4 + 33 {
		return {}, false
	}
	m.sidechain = payload[4]
	copy(m.h_star[:], payload[5:])
	return m, true
}
