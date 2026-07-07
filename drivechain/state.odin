// BIP300 databases D1 (sidechain slots) and D2 (withdrawal bundles) with
// per-block apply/undo. Pure data — no chain or storage dependencies; the
// chain layer feeds coinbase OP_RETURN payloads in and persists snapshots.
package drivechain

Mode :: enum {
	Off,
	Track,   // maintain D1/D2, reject nothing
	Enforce, // + OP_DRIVECHAIN semantics and block rejection (phase 2)
}

// Activation windows (BIP300).
NEW_SLOT_WINDOW    :: 2016
NEW_SLOT_MAX_FAILS :: 1008
USED_SLOT_WINDOW    :: 26_300
USED_SLOT_MAX_FAILS :: 13_150

BUNDLE_START_ACKS      :: 1
BUNDLE_START_REMAINING :: 26_299
BUNDLE_SUCCESS_ACKS    :: 13_150

Proposal :: struct {
	sidechain:   u8,
	version:     i32,
	title:       string, // owned clones
	description: string,
	hash_id_1:   [32]byte,
	hash_id_2:   [20]byte,
	commitment:  [32]byte, // sha256d(M1 body) — what M2s reference
	age:         int,
	fails:       int,
	overwriting: bool, // proposing over an active slot → long window
}

Sidechain :: struct {
	active:      bool,
	version:     i32,
	title:       string,
	description: string,
	hash_id_1:   [32]byte,
	hash_id_2:   [20]byte,
	activated_h: int,
	ctip_txid:   [32]byte, // current escrow tip (phase 2 maintains it)
	ctip_vout:   i32,
	ctip_amount: i64,
}

Bundle :: struct {
	sidechain:   u8,
	hash:        [32]byte,
	acks:        u16,
	remaining:   u16,
	approved:    bool,
}

State :: struct {
	slots:     [256]Sidechain,
	proposals: [dynamic]Proposal, // pending M1s under vote
	bundles:   [dynamic]Bundle,
	last_m4:   []u16, // previous block's vote vector (for version 0x00)
}

state_init :: proc(st: ^State) {
	st.proposals = make([dynamic]Proposal, 0, 4)
	st.bundles = make([dynamic]Bundle, 0, 8)
}

state_destroy :: proc(st: ^State) {
	for p in st.proposals {
		delete(p.title)
		delete(p.description)
	}
	delete(st.proposals)
	delete(st.bundles)
	for &s in st.slots {
		delete(s.title)
		delete(s.description)
	}
	delete(st.last_m4)
}


active_count :: proc(st: ^State) -> int {
	n := 0
	for s in st.slots {
		if s.active { n += 1 }
	}
	return n
}

// Per-sidechain vote decision for one block: >=0 upvotes the nth bundle
// (age order) and decays that sidechain's others; ALARM decays them all;
// NONE (abstain / no vote) leaves them untouched.
VOTE_NONE :: -1
VOTE_ALARM :: -2

// Apply one block's coinbase OP_RETURN payloads. Track mode never errors —
// malformed or rule-violating messages are simply ignored (the chain is the
// chain); enforce-mode strictness arrives in phase 2.
apply_block :: proc(st: ^State, coinbase_payloads: [][]byte, height: int) {
	saw_m1 := false
	saw_m2 := false
	m4_applied := false
	have_votes := false
	decisions: [256]int
	for &d in decisions { d = VOTE_NONE }
	acked_commitment: [32]byte
	have_ack := false

	for payload in coinbase_payloads {
		if m1, ok := parse_m1(payload); ok {
			if saw_m1 { continue } // one M1 per block
			saw_m1 = true
			// no duplicate pending proposal for the same slot
			dup := false
			for p in st.proposals {
				if p.sidechain == m1.sidechain { dup = true; break }
			}
			if dup { continue }
			pr := Proposal{
				sidechain   = m1.sidechain,
				version     = m1.version,
				title       = _clone_string(m1.title),
				description = _clone_string(m1.description),
				hash_id_1   = m1.hash_id_1,
				hash_id_2   = m1.hash_id_2,
				commitment  = m1_commitment_hash(&m1),
				overwriting = st.slots[m1.sidechain].active,
			}
			append(&st.proposals, pr)
		} else if m2, ok2 := parse_m2(payload); ok2 {
			if saw_m2 { continue } // one M2 per block
			saw_m2 = true
			acked_commitment = m2.proposal_hash
			have_ack = true
		} else if m3, ok3 := parse_m3(payload); ok3 {
			if !st.slots[m3.sidechain].active { continue }
			dup := false
			for b in st.bundles {
				if b.hash == m3.bundle_hash { dup = true; break }
			}
			if dup { continue }
			append(&st.bundles, Bundle{
				sidechain = m3.sidechain,
				hash      = m3.bundle_hash,
				acks      = BUNDLE_START_ACKS,
				remaining = BUNDLE_START_REMAINING,
			})
		} else if m4, ok4 := parse_m4(payload, active_count(st)); ok4 {
			if m4_applied { continue }
			m4_applied = true
			switch m4.version {
			case 0x00:
				// repeat previous block's votes
				if st.last_m4 != nil {
					have_votes = true
					_apply_votes(st, st.last_m4, &decisions)
				}
			case 0x01, 0x02:
				have_votes = true
				_apply_votes(st, m4.votes, &decisions)
				delete(st.last_m4)
				st.last_m4 = _clone_votes(m4.votes)
			case 0x03:
				// upvote each sidechain's bundle leading by ≥50 acks; sidechains
				// with no clear leader abstain
				have_votes = true
				for slot, slot_num in st.slots {
					if !slot.active { continue }
					nth := 0
					for b in st.bundles {
						if int(b.sidechain) != slot_num { continue }
						lead := true
						for other in st.bundles {
							if other.sidechain == b.sidechain && other.hash != b.hash &&
							   int(b.acks) - int(other.acks) < 50 {
								lead = false
								break
							}
						}
						if lead {
							decisions[slot_num] = nth
							break
						}
						nth += 1
					}
				}
			}
		} else if _, ok5 := parse_bmm_accept(payload); ok5 {
			// BIP301 h* commitments: tracked implicitly (nothing stateful in D1/D2).
		}
	}

	// Bundle ACK mechanics, per sidechain: the upvoted bundle gains 1 and its
	// sidechain's other bundles lose 1; alarm decays them all; abstain (or no
	// vote, or no M4 at all) leaves them unchanged.
	if have_votes {
		nth_in_side: [256]int
		for &b in st.bundles {
			d := decisions[b.sidechain]
			nth := nth_in_side[b.sidechain]
			nth_in_side[b.sidechain] += 1
			switch {
			case d == VOTE_NONE:
				// abstain: unchanged
			case d == nth:
				b.acks += 1
			case:
				// alarm, or another bundle of this sidechain was upvoted
				if b.acks > 0 { b.acks -= 1 }
			}
		}
	}

	// Age bundles + prune the impossible/expired; mark approved. Ordered
	// removal — M4 vote indices address bundles by age order.
	for i := len(st.bundles) - 1; i >= 0; i -= 1 {
		b := &st.bundles[i]
		if b.remaining > 0 { b.remaining -= 1 }
		if b.acks >= BUNDLE_SUCCESS_ACKS { b.approved = true }
		if !b.approved && (b.remaining == 0 || int(BUNDLE_SUCCESS_ACKS) - int(b.acks) > int(b.remaining)) {
			ordered_remove(&st.bundles, i)
		}
	}

	// Proposal aging: every block ages the window; blocks whose M2 did not
	// ack a proposal count as fails for it.
	for i := len(st.proposals) - 1; i >= 0; i -= 1 {
		p := &st.proposals[i]
		window := p.overwriting ? USED_SLOT_WINDOW : NEW_SLOT_WINDOW
		max_fails := p.overwriting ? USED_SLOT_MAX_FAILS : NEW_SLOT_MAX_FAILS

		p.age += 1
		if !(have_ack && acked_commitment == p.commitment) {
			p.fails += 1
		}
		if p.fails >= max_fails {
			delete(p.title)
			delete(p.description)
			unordered_remove(&st.proposals, i)
			continue
		}
		if p.age >= window {
			// Window complete without failing out → activate.
			slot := &st.slots[p.sidechain]
			delete(slot.title)
			delete(slot.description)
			slot^ = Sidechain{
				active      = true,
				version     = p.version,
				title       = _clone_string(p.title),
				description = _clone_string(p.description),
				hash_id_1   = p.hash_id_1,
				hash_id_2   = p.hash_id_2,
				activated_h = height,
			}
			delete(p.title)
			delete(p.description)
			unordered_remove(&st.proposals, i)
		}
	}
}

_apply_votes :: proc(st: ^State, votes: []u16, decisions: ^[256]int) {
	// votes are indexed by ACTIVE sidechain order; each value selects which
	// of that sidechain's bundles (by age order) is upvoted.
	active_idx := 0
	for slot, slot_num in st.slots {
		if !slot.active { continue }
		defer active_idx += 1
		if active_idx >= len(votes) { break }
		switch v := votes[active_idx]; v {
		case M4_VOTE_ABSTAIN:
			// decisions[slot_num] stays VOTE_NONE
		case M4_VOTE_ALARM:
			decisions[slot_num] = VOTE_ALARM
		case:
			decisions[slot_num] = int(v)
		}
	}
}

_clone_string :: proc(s: string) -> string {
	buf := make([]byte, len(s))
	copy(buf, s)
	return string(buf)
}

_clone_votes :: proc(v: []u16) -> []u16 {
	out := make([]u16, len(v))
	copy(out, v)
	return out
}
