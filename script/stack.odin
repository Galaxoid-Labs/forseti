package script

import "core:mem"

// Limits
MAX_STACK_SIZE    :: 1000
MAX_ELEMENT_SIZE  :: 520
MAX_SCRIPT_NUM_SIZE :: 4

Script_Stack :: struct {
	items: [dynamic][]byte,
}

stack_init :: proc(allocator := context.allocator) -> Script_Stack {
	return Script_Stack{items = make([dynamic][]byte, 0, 16, allocator)}
}

stack_destroy :: proc(s: ^Script_Stack) {
	delete(s.items)
}

stack_size :: proc(s: ^Script_Stack) -> int {
	return len(s.items)
}

stack_push :: proc(s: ^Script_Stack, data: []byte) {
	// Clone the data so the stack owns it, using the stack's allocator
	alloc := s.items.allocator
	clone := make([]byte, len(data), alloc)
	copy(clone, data)
	append(&s.items, clone)
}

stack_push_no_copy :: proc(s: ^Script_Stack, data: []byte) {
	append(&s.items, data)
}

stack_pop :: proc(s: ^Script_Stack) -> (data: []byte, err: Script_Error) {
	if len(s.items) == 0 { return nil, .Invalid_Stack_Operation }
	data = pop(&s.items)
	return data, nil
}

stack_top :: proc(s: ^Script_Stack, offset: int = -1) -> (data: []byte, err: Script_Error) {
	idx := len(s.items) + offset
	if idx < 0 || idx >= len(s.items) { return nil, .Invalid_Stack_Operation }
	return s.items[idx], nil
}

stack_swap :: proc(s: ^Script_Stack, i, j: int) -> Script_Error {
	si := len(s.items) + i
	sj := len(s.items) + j
	if si < 0 || si >= len(s.items) || sj < 0 || sj >= len(s.items) {
		return .Invalid_Stack_Operation
	}
	s.items[si], s.items[sj] = s.items[sj], s.items[si]
	return nil
}

stack_dup_n :: proc(s: ^Script_Stack, n: int) -> Script_Error {
	if len(s.items) < n { return .Invalid_Stack_Operation }
	start := len(s.items) - n
	for i in start ..< start + n {
		stack_push(s, s.items[i])
	}
	return nil
}

stack_remove :: proc(s: ^Script_Stack, idx: int) -> Script_Error {
	actual := len(s.items) + idx
	if actual < 0 || actual >= len(s.items) { return .Invalid_Stack_Operation }
	// Free removed element — no-op on arena, safe
	ordered_remove(&s.items, actual)
	return nil
}

stack_insert :: proc(s: ^Script_Stack, idx: int, data: []byte) -> Script_Error {
	actual := len(s.items) + idx
	if actual < 0 || actual > len(s.items) { return .Invalid_Stack_Operation }
	alloc := s.items.allocator
	clone := make([]byte, len(data), alloc)
	copy(clone, data)
	inject_at(&s.items, actual, clone)
	return nil
}

// --- Bitcoin Script Number encoding/decoding ---
// Bitcoin numbers are little-endian with a sign bit in the MSB of the last byte.
// Zero is encoded as an empty byte array.

script_num_encode :: proc(val: i64, allocator := context.allocator) -> []byte {
	if val == 0 {
		return make([]byte, 0, allocator)
	}

	neg := val < 0
	abs_val := val if !neg else -val

	// Encode as little-endian
	result := make([dynamic]byte, 0, 8, allocator)
	v := u64(abs_val)
	for v > 0 {
		append(&result, u8(v & 0xff))
		v >>= 8
	}

	// If the top byte has the sign bit set, add an extra byte for the sign.
	if result[len(result) - 1] & 0x80 != 0 {
		if neg {
			append(&result, 0x80)
		} else {
			append(&result, 0x00)
		}
	} else if neg {
		result[len(result) - 1] |= 0x80
	}

	return result[:]
}

script_num_decode :: proc(data: []byte, max_len: int = MAX_SCRIPT_NUM_SIZE, require_minimal: bool = false) -> (val: i64, err: Script_Error) {
	if len(data) == 0 {
		return 0, nil
	}
	if len(data) > max_len {
		return 0, .Script_Num_Overflow
	}

	// Check for non-minimal encoding
	if require_minimal {
		// If the last byte is 0x00 and the previous byte doesn't have bit 0x80 set,
		// the encoding is non-minimal, unless the value is a single 0x00.
		if data[len(data) - 1] & 0x7f == 0 {
			if len(data) <= 1 || data[len(data) - 2] & 0x80 == 0 {
				return 0, .Minimal_Data
			}
		}
	}

	// Decode little-endian
	result: i64
	for i in 0 ..< len(data) {
		result |= i64(data[i]) << u64(8 * i)
	}

	// Check sign bit in last byte
	if data[len(data) - 1] & 0x80 != 0 {
		// Remove sign bit from value and negate
		result &= ~(i64(0x80) << u64(8 * (len(data) - 1)))
		result = -result
	}

	return result, nil
}

// Bitcoin truthiness: false is empty array or negative zero (0x80).
// Everything else is true.
stack_to_bool :: proc(data: []byte) -> bool {
	for i in 0 ..< len(data) {
		if data[i] != 0 {
			// Negative zero: last byte is 0x80 and all others are 0
			if i == len(data) - 1 && data[i] == 0x80 {
				return false
			}
			return true
		}
	}
	return false
}

bool_to_stack :: proc(val: bool, allocator := context.allocator) -> []byte {
	if val {
		result := make([]byte, 1, allocator)
		result[0] = 1
		return result
	}
	return make([]byte, 0, allocator)
}
