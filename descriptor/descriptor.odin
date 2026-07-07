// Output script descriptors (Bitcoin Core dialect): parsing, BIP32 public
// derivation, script/address generation, and the descriptor checksum.
//
// Supported: pkh(KEY), wpkh(KEY), sh(wpkh(KEY)), tr(KEY) (key-path only,
// BIP86 tweak), multi/sortedmulti inside sh()/wsh()/sh(wsh()), addr(ADDR),
// raw(HEX). KEY = hex pubkey (compressed/uncompressed/x-only for tr) or
// xpub/tpub with an optional [origin] prefix, derivation path, and a
// trailing /* wildcard. Private keys (xprv/WIF) and hardened derivation
// steps are rejected — this is a watch-only engine.
package descriptor

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:fmt"
import "core:strconv"
import "core:strings"
import btccrypto "../crypto"

// Network parameters needed for addr() decoding and address encoding.
Net_Params :: struct {
	p2pkh_version: u8,
	p2sh_version:  u8,
	hrp:           string,
}

// --- checksum (Core's descriptor.cpp) ---

@(private) INPUT_CHARSET :: "0123456789()[],'/*abcdefgh@:$%{}IJKLMNOPQRSTUVWXYZ&+-.;<=>?!^_|~ijklmnopqrstuvwxyzABCDEFGH`#\"\\ "
@(private) CHECKSUM_CHARSET :: "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

@(private)
_descsum_polymod :: proc(c: u64, val: u64) -> u64 {
	GEN := [5]u64{0xf5dee51989, 0xa9fdca3312, 0x1bab10e32d, 0x3706b1677a, 0x644d626ffd}
	c0 := c >> 35
	out := ((c & 0x7ffffffff) << 5) ~ val
	for i in 0 ..< 5 {
		if c0 >> uint(i) & 1 != 0 {
			out ~= GEN[i]
		}
	}
	return out
}

// Compute the 8-character checksum of a descriptor body (no '#').
checksum_create :: proc(s: string, allocator := context.temp_allocator) -> (string, bool) {
	c := u64(1)
	cls := u64(0)
	clscount := 0
	for i in 0 ..< len(s) {
		pos := strings.index_byte(INPUT_CHARSET, s[i])
		if pos < 0 {
			return "", false
		}
		c = _descsum_polymod(c, u64(pos) & 31)
		cls = cls * 3 + (u64(pos) >> 5)
		clscount += 1
		if clscount == 3 {
			c = _descsum_polymod(c, cls)
			cls = 0
			clscount = 0
		}
	}
	if clscount > 0 {
		c = _descsum_polymod(c, cls)
	}
	for _ in 0 ..< 8 {
		c = _descsum_polymod(c, 0)
	}
	c ~= 1

	charset := CHECKSUM_CHARSET
	out := make([]byte, 8, allocator)
	for j in 0 ..< 8 {
		out[j] = charset[(c >> uint(5 * (7 - j))) & 31]
	}
	return string(out), true
}

// --- BIP32 public derivation ---

XPUB_MAINNET :: u32(0x0488B21E)
XPUB_TESTNET :: u32(0x043587CF) // tpub — testnet/signet/regtest

Xpub :: struct {
	depth:     u8,
	child_num: u32,
	chaincode: [32]byte,
	pubkey:    [33]byte,
}

parse_xpub :: proc(s: string) -> (x: Xpub, ok: bool) {
	payload, dec_ok := btccrypto.base58check_decode_raw(s, context.temp_allocator)
	if !dec_ok || len(payload) != 78 {
		return
	}
	version := u32(payload[0]) << 24 | u32(payload[1]) << 16 | u32(payload[2]) << 8 | u32(payload[3])
	if version != XPUB_MAINNET && version != XPUB_TESTNET {
		return
	}
	x.depth = payload[4]
	x.child_num = u32(payload[9]) << 24 | u32(payload[10]) << 16 | u32(payload[11]) << 8 | u32(payload[12])
	copy(x.chaincode[:], payload[13:45])
	if payload[45] != 0x02 && payload[45] != 0x03 {
		return
	}
	copy(x.pubkey[:], payload[45:78])
	return x, true
}

// CKDpub: non-hardened child derivation (BIP32).
ckd_pub :: proc(x: ^Xpub, index: u32) -> (child: Xpub, ok: bool) {
	if index >= 0x80000000 {
		return // hardened derivation impossible from a public key
	}
	data: [37]byte
	copy(data[:33], x.pubkey[:])
	data[33] = byte(index >> 24)
	data[34] = byte(index >> 16)
	data[35] = byte(index >> 8)
	data[36] = byte(index)

	i_out: [64]byte
	hmac.sum(hash.Algorithm.SHA512, i_out[:], data[:], x.chaincode[:])

	tweaked, tweak_ok := btccrypto.pubkey_tweak_add(x.pubkey[:], i_out[:32])
	if !tweak_ok {
		return
	}
	child.depth = x.depth + 1
	child.child_num = index
	copy(child.chaincode[:], i_out[32:])
	child.pubkey = tweaked
	return child, true
}

// --- descriptor model ---

Desc_Type :: enum {
	Pkh,
	Wpkh,
	Sh_Wpkh,
	Sh_Multi,
	Wsh_Multi,
	Sh_Wsh_Multi,
	Tr,
	Addr,
	Raw,
}

Desc_Key :: struct {
	is_xpub:  bool,
	xpub:     Xpub,
	path:     [dynamic]u32, // non-hardened steps after the xpub
	wildcard: bool,
	raw_key:  []byte, // hex key bytes (33/65, or 32 x-only for tr)
}

Descriptor :: struct {
	type:         Desc_Type,
	keys:         [dynamic]Desc_Key,
	threshold:    int,  // multi
	sorted:       bool, // sortedmulti
	fixed_script: []byte, // addr()/raw()
	is_range:     bool,
	body:         string, // descriptor string without checksum (owned clone)
}

descriptor_destroy :: proc(d: ^Descriptor) {
	for &k in d.keys {
		delete(k.path)
		delete(k.raw_key)
	}
	delete(d.keys)
	delete(d.fixed_script)
	delete(d.body)
}

// --- parsing ---

@(private)
_hex_decode :: proc(s: string, allocator := context.temp_allocator) -> ([]byte, bool) {
	if len(s) % 2 != 0 {
		return nil, false
	}
	out := make([]byte, len(s) / 2, allocator)
	for i in 0 ..< len(out) {
		hi, lo := _hex_val(s[i * 2]), _hex_val(s[i * 2 + 1])
		if hi < 0 || lo < 0 {
			return nil, false
		}
		out[i] = byte(hi << 4 | lo)
	}
	return out, true
}

@(private)
_hex_val :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a' + 10)
	case 'A' ..= 'F': return int(c - 'A' + 10)
	}
	return -1
}

// Parse a KEY expression. x_only allows 64-hex keys (tr context).
@(private)
_parse_key :: proc(s: string, x_only: bool, allocator := context.allocator) -> (k: Desc_Key, err: string) {
	rest := s
	// Optional key-origin prefix [fingerprint/path] — informational, skipped.
	if len(rest) > 0 && rest[0] == '[' {
		end := strings.index_byte(rest, ']')
		if end < 0 {
			return {}, "unterminated key origin"
		}
		rest = rest[end + 1:]
	}
	if strings.contains(rest, "xprv") || strings.contains(rest, "tprv") {
		return {}, "private keys are not supported (watch-only descriptor engine)"
	}

	if strings.has_prefix(rest, "xpub") || strings.has_prefix(rest, "tpub") {
		key_end := strings.index_byte(rest, '/')
		key_str := key_end < 0 ? rest : rest[:key_end]
		xp, xp_ok := parse_xpub(key_str)
		if !xp_ok {
			return {}, "invalid extended public key"
		}
		k.is_xpub = true
		k.xpub = xp
		k.path = make([dynamic]u32, 0, 4, allocator)
		if key_end >= 0 {
			for seg in strings.split(rest[key_end + 1:], "/", context.temp_allocator) {
				if seg == "*" {
					k.wildcard = true
					continue
				}
				if k.wildcard {
					return {}, "wildcard must be the last path element"
				}
				if strings.has_suffix(seg, "'") || strings.has_suffix(seg, "h") || strings.has_suffix(seg, "H") {
					return {}, "hardened derivation requires a private key"
				}
				n, n_ok := strconv.parse_uint(seg, 10)
				if !n_ok || n >= 0x80000000 {
					return {}, "invalid derivation path element"
				}
				append(&k.path, u32(n))
			}
		}
		return k, ""
	}

	// Hex public key.
	raw, hex_ok := _hex_decode(rest, allocator)
	if !hex_ok {
		return {}, "invalid key expression"
	}
	valid := (len(raw) == 33 && (raw[0] == 0x02 || raw[0] == 0x03)) ||
		(len(raw) == 65 && raw[0] == 0x04) ||
		(x_only && len(raw) == 32)
	if !valid {
		return {}, "invalid public key"
	}
	k.raw_key = raw
	return k, ""
}

@(private)
_parse_multi :: proc(d: ^Descriptor, inner: string, allocator := context.allocator) -> string {
	parts := strings.split(inner, ",", context.temp_allocator)
	if len(parts) < 2 {
		return "multi() needs a threshold and at least one key"
	}
	thr, thr_ok := strconv.parse_int(parts[0], 10)
	if !thr_ok || thr < 1 || thr > len(parts) - 1 || len(parts) - 1 > 16 {
		return "invalid multisig threshold or key count"
	}
	d.threshold = thr
	for p in parts[1:] {
		k, kerr := _parse_key(p, false, allocator)
		if kerr != "" {
			return kerr
		}
		if k.wildcard {
			d.is_range = true
		}
		append(&d.keys, k)
	}
	return ""
}

// Parse a descriptor string. The trailing #checksum is verified when
// present. Returns an owned Descriptor (descriptor_destroy to free).
parse :: proc(desc_in: string, net: Net_Params, allocator := context.allocator) -> (d: Descriptor, err: string) {
	context.allocator = allocator
	s := desc_in

	// Split + verify checksum.
	if hash_pos := strings.index_byte(s, '#'); hash_pos >= 0 {
		body := s[:hash_pos]
		want := s[hash_pos + 1:]
		got, cs_ok := checksum_create(body)
		if !cs_ok || len(want) != 8 || got != want {
			return {}, "invalid descriptor checksum"
		}
		s = body
	}

	d.keys = make([dynamic]Desc_Key, 0, 4)
	d.body = strings.clone(s)
	ok_err := _parse_body(&d, s, net)
	if ok_err != "" {
		descriptor_destroy(&d)
		return {}, ok_err
	}
	for k in d.keys {
		if k.wildcard {
			d.is_range = true
		}
	}
	return d, ""
}

@(private)
_inner :: proc(s: string, prefix: string) -> (string, bool) {
	if strings.has_prefix(s, prefix) && strings.has_suffix(s, ")") {
		return s[len(prefix):len(s) - 1], true
	}
	return "", false
}

@(private)
_parse_body :: proc(d: ^Descriptor, s: string, net: Net_Params) -> string {
	if inner, ok := _inner(s, "pkh("); ok {
		d.type = .Pkh
		k, kerr := _parse_key(inner, false)
		if kerr != "" { return kerr }
		append(&d.keys, k)
		return ""
	}
	if inner, ok := _inner(s, "wpkh("); ok {
		d.type = .Wpkh
		k, kerr := _parse_key(inner, false)
		if kerr != "" { return kerr }
		if len(k.raw_key) == 65 { return "uncompressed keys are invalid in wpkh()" }
		append(&d.keys, k)
		return ""
	}
	if inner, ok := _inner(s, "tr("); ok {
		if strings.contains(inner, ",") {
			return "tr() script trees are not supported (key-path only)"
		}
		d.type = .Tr
		k, kerr := _parse_key(inner, true)
		if kerr != "" { return kerr }
		if len(k.raw_key) == 65 { return "uncompressed keys are invalid in tr()" }
		append(&d.keys, k)
		return ""
	}
	if inner, ok := _inner(s, "wsh("); ok {
		m, m_ok := _inner(inner, "multi(")
		if !m_ok {
			if sm, sm_ok := _inner(inner, "sortedmulti("); sm_ok {
				d.sorted = true
				m = sm
				m_ok = true
			}
		}
		if !m_ok { return "wsh() supports only multi()/sortedmulti()" }
		d.type = .Wsh_Multi
		return _parse_multi(d, m)
	}
	if inner, ok := _inner(s, "sh("); ok {
		if w, w_ok := _inner(inner, "wpkh("); w_ok {
			d.type = .Sh_Wpkh
			k, kerr := _parse_key(w, false)
			if kerr != "" { return kerr }
			if len(k.raw_key) == 65 { return "uncompressed keys are invalid in sh(wpkh())" }
			append(&d.keys, k)
			return ""
		}
		if ws, ws_ok := _inner(inner, "wsh("); ws_ok {
			m, m_ok := _inner(ws, "multi(")
			if !m_ok {
				if sm, sm_ok := _inner(ws, "sortedmulti("); sm_ok {
					d.sorted = true
					m = sm
					m_ok = true
				}
			}
			if !m_ok { return "sh(wsh()) supports only multi()/sortedmulti()" }
			d.type = .Sh_Wsh_Multi
			return _parse_multi(d, m)
		}
		m, m_ok := _inner(inner, "multi(")
		if !m_ok {
			if sm, sm_ok := _inner(inner, "sortedmulti("); sm_ok {
				d.sorted = true
				m = sm
				m_ok = true
			}
		}
		if !m_ok { return "sh() supports wpkh(), wsh(multi()), or multi()" }
		d.type = .Sh_Multi
		return _parse_multi(d, m)
	}
	if inner, ok := _inner(s, "addr("); ok {
		d.type = .Addr
		spk, spk_ok := _address_to_spk(inner, net)
		if !spk_ok { return "invalid address in addr()" }
		d.fixed_script = spk
		return ""
	}
	if inner, ok := _inner(s, "raw("); ok {
		d.type = .Raw
		spk, hex_ok := _hex_decode(inner, context.allocator)
		if !hex_ok { return "invalid hex in raw()" }
		d.fixed_script = spk
		return ""
	}
	if strings.has_prefix(s, "combo(") {
		return "combo() is not supported"
	}
	return "unsupported descriptor"
}

@(private)
_address_to_spk :: proc(addr: string, net: Net_Params, allocator := context.allocator) -> ([]byte, bool) {
	if hrp, ver, prog, prog_len, ok := btccrypto.bech32_decode(addr); ok && hrp == net.hrp {
		if ver == 0 && (prog_len == 20 || prog_len == 32) || ver == 1 && prog_len == 32 {
			spk := make([]byte, 2 + prog_len, allocator)
			spk[0] = ver == 0 ? 0x00 : byte(0x50 + ver)
			spk[1] = byte(prog_len)
			copy(spk[2:], prog[:prog_len])
			return spk, true
		}
		return nil, false
	}
	if version, payload, ok := btccrypto.base58check_decode(addr); ok {
		if version == net.p2pkh_version {
			spk := make([]byte, 25, allocator)
			spk[0] = 0x76; spk[1] = 0xa9; spk[2] = 0x14
			copy(spk[3:23], payload[:])
			spk[23] = 0x88; spk[24] = 0xac
			return spk, true
		}
		if version == net.p2sh_version {
			spk := make([]byte, 23, allocator)
			spk[0] = 0xa9; spk[1] = 0x14
			copy(spk[2:22], payload[:])
			spk[22] = 0x87
			return spk, true
		}
	}
	return nil, false
}

// --- derivation ---

// Derive the concrete pubkey bytes for key k at wildcard position `index`.
@(private)
_derive_key :: proc(k: ^Desc_Key, index: int) -> (out: [65]byte, out_len: int, ok: bool) {
	if !k.is_xpub {
		copy(out[:], k.raw_key)
		return out, len(k.raw_key), true
	}
	x := k.xpub
	for step in k.path {
		child, c_ok := ckd_pub(&x, step)
		if !c_ok { return }
		x = child
	}
	if k.wildcard {
		child, c_ok := ckd_pub(&x, u32(index))
		if !c_ok { return }
		x = child
	}
	copy(out[:], x.pubkey[:])
	return out, 33, true
}

@(private)
_multi_script :: proc(d: ^Descriptor, index: int, allocator := context.temp_allocator) -> ([]byte, bool) {
	n := len(d.keys)
	keys := make([][]byte, n, context.temp_allocator)
	for i in 0 ..< n {
		kb, kl, ok := _derive_key(&d.keys[i], index)
		if !ok { return nil, false }
		keys[i] = make([]byte, kl, context.temp_allocator)
		copy(keys[i], kb[:kl])
	}
	if d.sorted {
		// lexicographic sort (BIP67)
		for i in 1 ..< n {
			j := i
			for j > 0 && string(keys[j]) < string(keys[j - 1]) {
				keys[j], keys[j - 1] = keys[j - 1], keys[j]
				j -= 1
			}
		}
	}
	script := make([dynamic]byte, 0, 3 + n * 34, allocator)
	append(&script, byte(0x50 + d.threshold)) // OP_k
	for kbytes in keys {
		append(&script, byte(len(kbytes)))
		append(&script, ..kbytes)
	}
	append(&script, byte(0x50 + n)) // OP_n
	append(&script, 0xae)           // OP_CHECKMULTISIG
	return script[:], true
}

@(private)
_sha256 :: proc(data: []byte) -> [32]byte {
	out: [32]byte
	hash.hash_bytes_to_buffer(hash.Algorithm.SHA256, data, out[:])
	return out
}

// The scriptPubKey for the descriptor at wildcard `index` (ignored for
// non-range descriptors).
script_pubkey :: proc(d: ^Descriptor, index: int, allocator := context.temp_allocator) -> ([]byte, bool) {
	switch d.type {
	case .Addr, .Raw:
		out := make([]byte, len(d.fixed_script), allocator)
		copy(out, d.fixed_script)
		return out, true

	case .Pkh:
		kb, kl, ok := _derive_key(&d.keys[0], index)
		if !ok { return nil, false }
		h := btccrypto.hash160(kb[:kl])
		out := make([]byte, 25, allocator)
		out[0] = 0x76; out[1] = 0xa9; out[2] = 0x14
		copy(out[3:23], h[:])
		out[23] = 0x88; out[24] = 0xac
		return out, true

	case .Wpkh:
		kb, kl, ok := _derive_key(&d.keys[0], index)
		if !ok { return nil, false }
		h := btccrypto.hash160(kb[:kl])
		out := make([]byte, 22, allocator)
		out[0] = 0x00; out[1] = 0x14
		copy(out[2:], h[:])
		return out, true

	case .Sh_Wpkh:
		kb, kl, ok := _derive_key(&d.keys[0], index)
		if !ok { return nil, false }
		h := btccrypto.hash160(kb[:kl])
		redeem: [22]byte
		redeem[0] = 0x00; redeem[1] = 0x14
		copy(redeem[2:], h[:])
		rh := btccrypto.hash160(redeem[:])
		out := make([]byte, 23, allocator)
		out[0] = 0xa9; out[1] = 0x14
		copy(out[2:22], rh[:])
		out[22] = 0x87
		return out, true

	case .Tr:
		kb, kl, ok := _derive_key(&d.keys[0], index)
		if !ok { return nil, false }
		xonly := kl == 32 ? kb[:32] : kb[1:33]
		output_key, tweak_ok := btccrypto.taproot_output_key(xonly)
		if !tweak_ok { return nil, false }
		out := make([]byte, 34, allocator)
		out[0] = 0x51; out[1] = 0x20
		copy(out[2:], output_key[:])
		return out, true

	case .Sh_Multi:
		script, ok := _multi_script(d, index)
		if !ok { return nil, false }
		h := btccrypto.hash160(script)
		out := make([]byte, 23, allocator)
		out[0] = 0xa9; out[1] = 0x14
		copy(out[2:22], h[:])
		out[22] = 0x87
		return out, true

	case .Wsh_Multi:
		script, ok := _multi_script(d, index)
		if !ok { return nil, false }
		h := _sha256(script)
		out := make([]byte, 34, allocator)
		out[0] = 0x00; out[1] = 0x20
		copy(out[2:], h[:])
		return out, true

	case .Sh_Wsh_Multi:
		script, ok := _multi_script(d, index)
		if !ok { return nil, false }
		wh := _sha256(script)
		witness_spk: [34]byte
		witness_spk[0] = 0x00; witness_spk[1] = 0x20
		copy(witness_spk[2:], wh[:])
		h := btccrypto.hash160(witness_spk[:])
		out := make([]byte, 23, allocator)
		out[0] = 0xa9; out[1] = 0x14
		copy(out[2:22], h[:])
		out[22] = 0x87
		return out, true
	}
	return nil, false
}

// The address for the descriptor at `index`. raw() has no address form.
address :: proc(d: ^Descriptor, index: int, net: Net_Params, allocator := context.temp_allocator) -> (string, bool) {
	spk, ok := script_pubkey(d, index, context.temp_allocator)
	if !ok {
		return "", false
	}
	return script_to_address(spk, net, allocator)
}

// Encode a standard scriptPubKey as an address.
script_to_address :: proc(spk: []byte, net: Net_Params, allocator := context.temp_allocator) -> (string, bool) {
	switch {
	case len(spk) == 25 && spk[0] == 0x76 && spk[1] == 0xa9 && spk[2] == 0x14 && spk[23] == 0x88 && spk[24] == 0xac:
		return btccrypto.base58check_encode(net.p2pkh_version, spk[3:23], allocator), true
	case len(spk) == 23 && spk[0] == 0xa9 && spk[1] == 0x14 && spk[22] == 0x87:
		return btccrypto.base58check_encode(net.p2sh_version, spk[2:22], allocator), true
	case len(spk) == 22 && spk[0] == 0x00 && spk[1] == 0x14:
		return btccrypto.bech32_encode(net.hrp, 0, spk[2:], allocator), true
	case len(spk) == 34 && spk[0] == 0x00 && spk[1] == 0x20:
		return btccrypto.bech32_encode(net.hrp, 0, spk[2:], allocator), true
	case len(spk) == 34 && spk[0] == 0x51 && spk[1] == 0x20:
		return btccrypto.bech32_encode(net.hrp, 1, spk[2:], allocator), true
	}
	return "", false
}

// Canonical form with checksum appended (for getdescriptorinfo).
to_string_with_checksum :: proc(d: ^Descriptor, allocator := context.temp_allocator) -> string {
	sum, _ := checksum_create(d.body, context.temp_allocator)
	return fmt.aprintf("%s#%s", d.body, sum, allocator = allocator)
}
