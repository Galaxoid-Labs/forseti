package consensus

import "core:math"
import crypto "../crypto"

Hash256 :: crypto.Hash256

// Decode compact nBits to 256-bit big-endian target.
bits_to_target :: proc(bits: u32) -> [32]byte {
	target: [32]byte
	exponent := int(bits >> 24)
	mantissa := bits & 0x007fffff

	// Negative flag (MSB of mantissa byte) — treat as zero
	if (bits & 0x00800000) != 0 {
		return target
	}
	if mantissa == 0 {
		return target
	}

	// The mantissa is a 3-byte big-endian number placed at byte position (exponent - 3)
	// from the end of the 32-byte big-endian array.
	// In big-endian: byte index = 32 - exponent
	if exponent <= 3 {
		// Mantissa gets right-shifted
		mantissa >>= uint(8 * (3 - exponent))
		target[31] = byte(mantissa & 0xff)
		target[30] = byte((mantissa >> 8) & 0xff)
		target[29] = byte((mantissa >> 16) & 0xff)
	} else {
		start := 32 - exponent
		if start >= 0 && start < 32 {
			target[start] = byte((mantissa >> 16) & 0xff)
		}
		if start + 1 >= 0 && start + 1 < 32 {
			target[start + 1] = byte((mantissa >> 8) & 0xff)
		}
		if start + 2 >= 0 && start + 2 < 32 {
			target[start + 2] = byte(mantissa & 0xff)
		}
	}
	return target
}

// Encode 256-bit big-endian target back to compact nBits form.
target_to_bits :: proc(target: [32]byte) -> u32 {
	// Find the first non-zero byte (MSB)
	first_nonzero := 32
	for i in 0 ..< 32 {
		if target[i] != 0 {
			first_nonzero = i
			break
		}
	}
	if first_nonzero == 32 {
		return 0
	}

	exponent := u32(32 - first_nonzero)
	mantissa: u32

	if exponent <= 2 {
		// Pack remaining bytes
		mantissa = u32(target[first_nonzero]) << (8 * (exponent - 1))
		if first_nonzero + 1 < 32 && exponent >= 2 {
			mantissa |= u32(target[first_nonzero + 1])
		}
	} else {
		mantissa = u32(target[first_nonzero]) << 16
		if first_nonzero + 1 < 32 {
			mantissa |= u32(target[first_nonzero + 1]) << 8
		}
		if first_nonzero + 2 < 32 {
			mantissa |= u32(target[first_nonzero + 2])
		}
	}

	// If the high bit of mantissa is set, shift right and increase exponent
	// to avoid it being interpreted as negative
	if (mantissa & 0x00800000) != 0 {
		mantissa >>= 8
		exponent += 1
	}

	return (exponent << 24) | mantissa
}

// Check that block_hash meets the proof-of-work target encoded in bits.
check_proof_of_work :: proc(block_hash: Hash256, bits: u32, params: ^Chain_Params) -> bool {
	target := bits_to_target(bits)

	// Target must be positive
	if u256_is_zero(target) {
		return false
	}

	// Target must not exceed pow_limit
	if u256_compare(target, params.pow_limit) > 0 {
		return false
	}

	// Convert hash from internal (little-endian) to big-endian for comparison
	hash_be: [32]byte
	for i in 0 ..< 32 {
		hash_be[i] = block_hash[31 - i]
	}

	return u256_compare(hash_be, target) <= 0
}

// Compare hash (natural/internal byte order) against big-endian target.
hash_meets_target :: proc(hash: Hash256, target: [32]byte) -> bool {
	hash_be: [32]byte
	for i in 0 ..< 32 {
		hash_be[i] = hash[31 - i]
	}
	return u256_compare(hash_be, target) <= 0
}

// Calculate next work required (difficulty adjustment).
calculate_next_work_required :: proc(
	last_retarget_time: u32,
	current_time: u32,
	current_bits: u32,
	params: ^Chain_Params,
) -> u32 {
	if params.pow_no_retargeting {
		return current_bits
	}

	// Use signed arithmetic — on testnet3, timestamps can go backwards
	// due to the 20-minute min-difficulty rule (miners set future timestamps).
	actual_timespan := i64(current_time) - i64(last_retarget_time)

	// Clamp to [target_timespan/4, target_timespan*4]
	min_timespan := i64(params.target_timespan) / 4
	max_timespan := i64(params.target_timespan) * 4
	if actual_timespan < min_timespan {
		actual_timespan = min_timespan
	}
	if actual_timespan > max_timespan {
		actual_timespan = max_timespan
	}

	// new_target = old_target * actual_timespan / target_timespan
	old_target := bits_to_target(current_bits)
	new_target := _u256_multiply_ratio(old_target, u64(actual_timespan), u64(params.target_timespan))

	// Clamp to pow_limit
	if u256_compare(new_target, params.pow_limit) > 0 {
		new_target = params.pow_limit
	}

	return target_to_bits(new_target)
}

// Compute floating-point difficulty from compact nBits.
// Matches Bitcoin Core's GetDifficulty() formula.
get_difficulty :: proc(bits: u32) -> f64 {
	exponent := int(bits >> 24)
	mantissa := f64(bits & 0x007fffff)

	// Negative flag set means zero difficulty
	if (bits & 0x00800000) != 0 {
		return 0.0
	}
	if mantissa == 0 {
		return 0.0
	}

	// difficulty = 0x00ffff * 2^(8*(0x1d - 3)) / (mantissa * 2^(8*(exponent - 3)))
	// Simplifies to: 0x00ffff / mantissa * 2^(8*(0x1d - exponent))
	shift := 8 * (0x1d - exponent)
	diff := f64(0x00ffff) / mantissa * math.pow(f64(2.0), f64(shift))
	return diff
}

// Lexicographic comparison of two big-endian 256-bit values.
// Returns -1 if a < b, 0 if a == b, 1 if a > b.
u256_compare :: proc(a, b: [32]byte) -> int {
	for i in 0 ..< 32 {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	return 0
}

u256_is_zero :: proc(a: [32]byte) -> bool {
	for i in 0 ..< 32 {
		if a[i] != 0 {
			return false
		}
	}
	return true
}

// Multiply a 256-bit big-endian value by num/den using long arithmetic.
_u256_multiply_ratio :: proc(value: [32]byte, num, den: u64) -> [32]byte {
	// Multiply: process LSB to MSB, accumulate carry
	product: [64]byte // 512-bit intermediate (big-endian, product[0] is MSB)
	carry: u64 = 0
	for i := 31; i >= 0; i -= 1 {
		val := u64(value[i]) * num + carry
		// Store in the lower half of product (offset by 32)
		product[i + 32] = byte(val & 0xff)
		carry = val >> 8
	}
	// Store remaining carry in upper bytes
	idx := 31
	for carry > 0 && idx >= 0 {
		product[idx] = byte(carry & 0xff)
		carry >>= 8
		idx -= 1
	}

	// Divide: process MSB to LSB
	result: [32]byte
	remainder: u64 = 0
	// Process all 64 bytes of product, but we only keep the last 32 bytes of quotient
	quotient: [64]byte
	for i in 0 ..< 64 {
		remainder = (remainder << 8) | u64(product[i])
		quotient[i] = byte(remainder / den)
		remainder = remainder % den
	}

	// Copy lower 32 bytes of quotient to result
	for i in 0 ..< 32 {
		result[i] = quotient[i + 32]
	}

	return result
}
