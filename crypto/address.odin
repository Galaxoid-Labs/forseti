package crypto

import "core:strings"

BASE58_ALPHABET := [58]byte{
	'1', '2', '3', '4', '5', '6', '7', '8', '9',
	'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J',
	'K', 'L', 'M', 'N', 'P', 'Q', 'R', 'S', 'T',
	'U', 'V', 'W', 'X', 'Y', 'Z',
	'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i',
	'j', 'k', 'm', 'n', 'o', 'p', 'q', 'r', 's',
	't', 'u', 'v', 'w', 'x', 'y', 'z',
}

BECH32_CHARSET := [32]byte{
	'q', 'p', 'z', 'r', 'y', '9', 'x', '8',
	'g', 'f', '2', 't', 'v', 'd', 'w', '0',
	's', '3', 'j', 'n', '5', '4', 'k', 'h',
	'c', 'e', '6', 'm', 'u', 'a', '7', 'l',
}

BECH32_CONST  :: u32(1)
BECH32M_CONST :: u32(0x2bc830a3)

// Encode a payload with Base58Check (version byte + payload + 4-byte checksum).
base58check_encode :: proc(version: u8, payload: []byte, allocator := context.temp_allocator) -> string {
	// Build versioned payload: [version || payload]
	vp_len := 1 + len(payload)
	vp: [25]byte // max 1 + 20 = 21, but checksum makes 25
	vp[0] = version
	copy(vp[1:], payload)

	// Checksum: first 4 bytes of sha256d(version || payload)
	checksum := sha256d(vp[:vp_len])
	vp[vp_len]     = checksum[0]
	vp[vp_len + 1] = checksum[1]
	vp[vp_len + 2] = checksum[2]
	vp[vp_len + 3] = checksum[3]

	total_len := vp_len + 4
	data := vp[:total_len]

	// Count leading zero bytes (each becomes a '1')
	leading_zeros := 0
	for i in 0 ..< total_len {
		if data[i] != 0 { break }
		leading_zeros += 1
	}

	// Convert to base58 using big-integer division
	buf: [64]byte
	buf_pos := len(buf)

	// Work on a copy to avoid modifying vp
	work: [25]byte
	copy(work[:], data)

	for {
		// Check if all zero
		all_zero := true
		for i in 0 ..< total_len {
			if work[i] != 0 { all_zero = false; break }
		}
		if all_zero { break }

		// Divide work[] by 58, get remainder
		remainder: u32 = 0
		for i in 0 ..< total_len {
			acc := remainder * 256 + u32(work[i])
			work[i] = u8(acc / 58)
			remainder = acc % 58
		}

		buf_pos -= 1
		buf[buf_pos] = BASE58_ALPHABET[remainder]
	}

	// Prepend '1' for each leading zero byte
	for _ in 0 ..< leading_zeros {
		buf_pos -= 1
		buf[buf_pos] = '1'
	}

	result := strings.clone_from_bytes(buf[buf_pos:], allocator)
	return result
}

// Bech32/Bech32m polymod checksum.
_bech32_polymod :: proc(values: []u8) -> u32 {
	GEN := [5]u32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk: u32 = 1
	for v in values {
		b := chk >> 25
		chk = (chk & 0x1ffffff) << 5 ~ u32(v)
		for i in 0 ..< 5 {
			if (b >> uint(i)) & 1 != 0 {
				chk ~= GEN[i]
			}
		}
	}
	return chk
}

// Expand HRP for checksum computation: high bits, 0, low bits.
_bech32_hrp_expand :: proc(hrp: string) -> (result: [16]u8, length: int) {
	n := len(hrp)
	hrp_bytes := transmute([]byte)hrp
	// high bits
	for i in 0 ..< n {
		result[i] = hrp_bytes[i] >> 5
	}
	result[n] = 0 // separator
	// low bits
	for i in 0 ..< n {
		result[n + 1 + i] = hrp_bytes[i] & 31
	}
	return result, n * 2 + 1
}

// Convert data between bit widths (e.g., 8-bit to 5-bit).
_convert_bits :: proc(data: []byte, from, to: int, pad: bool) -> (result: [64]u8, length: int, ok: bool) {
	acc: u32 = 0
	bits: int = 0
	pos := 0
	maxv := u32((1 << uint(to)) - 1)
	max_acc := u32((1 << uint(from + to - 1)) - 1)

	for d in data {
		acc = ((acc << uint(from)) | u32(d)) & max_acc
		bits += from
		for bits >= to {
			bits -= to
			result[pos] = u8((acc >> uint(bits)) & maxv)
			pos += 1
		}
	}

	if pad {
		if bits > 0 {
			result[pos] = u8((acc << uint(to - bits)) & maxv)
			pos += 1
		}
	} else if bits >= from || ((acc << uint(to - bits)) & maxv) != 0 {
		return result, 0, false
	}

	return result, pos, true
}

// Decode a Base58Check-encoded address into version byte and 20-byte payload.
base58check_decode :: proc(addr: string) -> (version: u8, payload: [20]u8, ok: bool) {
	if len(addr) < 25 || len(addr) > 34 {
		return 0, {}, false
	}

	// Build reverse lookup table
	rev: [128]i8
	for i in 0 ..< 128 {
		rev[i] = -1
	}
	alpha := BASE58_ALPHABET
	for i in 0 ..< 58 {
		rev[alpha[i]] = i8(i)
	}

	// Decode base58 to big integer in 25-byte buffer
	decoded: [25]byte
	for i in 0 ..< len(addr) {
		c := addr[i]
		if c >= 128 {
			return 0, {}, false
		}
		val := rev[c]
		if val < 0 {
			return 0, {}, false
		}

		carry := u32(val)
		for j := 24; j >= 0; j -= 1 {
			carry += u32(decoded[j]) * 58
			decoded[j] = u8(carry & 0xff)
			carry >>= 8
		}
		if carry != 0 {
			return 0, {}, false
		}
	}

	// Verify checksum: sha256d(first 21 bytes)[:4] == last 4 bytes
	checksum := sha256d(decoded[:21])
	if decoded[21] != checksum[0] || decoded[22] != checksum[1] ||
	   decoded[23] != checksum[2] || decoded[24] != checksum[3] {
		return 0, {}, false
	}

	version = decoded[0]
	copy(payload[:], decoded[1:21])
	return version, payload, true
}

// Decode a Bech32/Bech32m-encoded address into HRP, witness version, and program.
bech32_decode :: proc(addr: string) -> (hrp: string, version: int, program: [40]u8, prog_len: int, ok: bool) {
	// Find last '1' separator
	sep_pos := -1
	for i := len(addr) - 1; i >= 0; i -= 1 {
		if addr[i] == '1' {
			sep_pos = i
			break
		}
	}
	if sep_pos < 1 || sep_pos + 7 > len(addr) {
		return "", 0, {}, 0, false
	}

	hrp = addr[:sep_pos]
	data_part := addr[sep_pos + 1:]

	if len(data_part) < 6 {
		return "", 0, {}, 0, false
	}

	// Build reverse charset lookup
	rev: [128]i8
	for i in 0 ..< 128 {
		rev[i] = -1
	}
	cs := BECH32_CHARSET
	for i in 0 ..< 32 {
		rev[cs[i]] = i8(i)
	}

	// Decode data characters to 5-bit values
	data_values: [128]u8
	for i in 0 ..< len(data_part) {
		c := data_part[i]
		// Convert to lowercase if uppercase
		lc := c
		if lc >= 'A' && lc <= 'Z' {
			lc = lc + 32
		}
		if lc >= 128 {
			return "", 0, {}, 0, false
		}
		val := rev[lc]
		if val < 0 {
			return "", 0, {}, 0, false
		}
		data_values[i] = u8(val)
	}

	// Verify checksum
	hrp_exp, hrp_exp_len := _bech32_hrp_expand(hrp)
	chk_input: [256]u8
	pos := 0
	copy(chk_input[pos:], hrp_exp[:hrp_exp_len])
	pos += hrp_exp_len
	copy(chk_input[pos:], data_values[:len(data_part)])
	pos += len(data_part)

	polymod := _bech32_polymod(chk_input[:pos])

	// First data value is the witness version
	version = int(data_values[0])

	// Determine expected constant
	expected_const := version == 0 ? BECH32_CONST : BECH32M_CONST
	if polymod != expected_const {
		return "", 0, {}, 0, false
	}

	// Convert remaining 5-bit values (excluding checksum) to 8-bit program
	data_5bit_len := len(data_part) - 6 - 1 // exclude version and 6-byte checksum
	if data_5bit_len <= 0 {
		return "", 0, {}, 0, false
	}

	conv, conv_len, conv_ok := _convert_bits(data_values[1:len(data_part) - 6], 5, 8, false)
	if !conv_ok {
		return "", 0, {}, 0, false
	}

	// Witness programs must be 2-40 bytes
	if conv_len < 2 || conv_len > 40 {
		return "", 0, {}, 0, false
	}

	copy(program[:], conv[:conv_len])
	return hrp, version, program, conv_len, true
}

// Encode a witness program as Bech32 (v0) or Bech32m (v1+).
bech32_encode :: proc(hrp: string, version: int, program: []byte, allocator := context.temp_allocator) -> string {
	// Convert 8-bit program to 5-bit groups
	conv, conv_len, conv_ok := _convert_bits(program, 8, 5, true)
	if !conv_ok { return "" }

	// Build values for checksum: hrp_expand + [version] + conv + [0,0,0,0,0,0]
	hrp_exp, hrp_exp_len := _bech32_hrp_expand(hrp)

	// Total checksum input: hrp_expand + 1 (version) + conv_len + 6 (zeros)
	chk_input: [128]u8
	pos := 0
	copy(chk_input[pos:], hrp_exp[:hrp_exp_len])
	pos += hrp_exp_len
	chk_input[pos] = u8(version)
	pos += 1
	copy(chk_input[pos:], conv[:conv_len])
	pos += conv_len
	// 6 zero bytes for checksum computation
	for i in 0 ..< 6 {
		chk_input[pos + i] = 0
	}
	pos += 6

	constant := version == 0 ? BECH32_CONST : BECH32M_CONST
	polymod := _bech32_polymod(chk_input[:pos]) ~ constant

	// Build output string: hrp + "1" + data_chars + checksum_chars
	out_len := len(hrp) + 1 + 1 + conv_len + 6
	b := strings.builder_make(0, out_len, allocator)
	strings.write_string(&b, hrp)
	strings.write_byte(&b, '1')
	strings.write_byte(&b, BECH32_CHARSET[version])
	for i in 0 ..< conv_len {
		strings.write_byte(&b, BECH32_CHARSET[conv[i]])
	}
	for i in 0 ..< 6 {
		strings.write_byte(&b, BECH32_CHARSET[(polymod >> uint(5 * (5 - i))) & 31])
	}

	return strings.to_string(b)
}
