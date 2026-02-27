package wire

// Bitcoin CompactSize encoding — NOT the same as LEB128.
//
// Value range         | Encoding
// --------------------|-----------------------------
// 0x00..0xFC          | 1 byte (value itself)
// 0xFD..0xFFFF        | 0xFD + 2 bytes little-endian
// 0x10000..0xFFFFFFFF | 0xFE + 4 bytes little-endian
// 0x100000000+        | 0xFF + 8 bytes little-endian

// Returns the encoded bytes and how many bytes were written (1, 3, 5, or 9).
compact_size_encode :: proc(val: u64) -> (buf: [9]u8, size: int) {
	if val < 0xFD {
		buf[0] = u8(val)
		return buf, 1
	} else if val <= 0xFFFF {
		buf[0] = 0xFD
		buf[1] = u8(val)
		buf[2] = u8(val >> 8)
		return buf, 3
	} else if val <= 0xFFFF_FFFF {
		buf[0] = 0xFE
		buf[1] = u8(val)
		buf[2] = u8(val >> 8)
		buf[3] = u8(val >> 16)
		buf[4] = u8(val >> 24)
		return buf, 5
	} else {
		buf[0] = 0xFF
		buf[1] = u8(val)
		buf[2] = u8(val >> 8)
		buf[3] = u8(val >> 16)
		buf[4] = u8(val >> 24)
		buf[5] = u8(val >> 32)
		buf[6] = u8(val >> 40)
		buf[7] = u8(val >> 48)
		buf[8] = u8(val >> 56)
		return buf, 9
	}
}

// Decodes a CompactSize from the front of data. Returns the value,
// number of bytes consumed, and an error if the encoding is invalid.
// Rejects non-canonical encodings (using more bytes than necessary).
compact_size_decode :: proc(data: []byte) -> (val: u64, size: int, err: Wire_Error) {
	if len(data) < 1 {
		return 0, 0, .Unexpected_EOF
	}

	first := data[0]

	if first < 0xFD {
		return u64(first), 1, nil
	}

	switch first {
	case 0xFD:
		if len(data) < 3 {
			return 0, 0, .Unexpected_EOF
		}
		val = u64(data[1]) | u64(data[2]) << 8
		if val < 0xFD {
			return 0, 0, .Non_Canonical_Compact_Size
		}
		return val, 3, nil

	case 0xFE:
		if len(data) < 5 {
			return 0, 0, .Unexpected_EOF
		}
		val = u64(data[1]) | u64(data[2]) << 8 | u64(data[3]) << 16 | u64(data[4]) << 24
		if val <= 0xFFFF {
			return 0, 0, .Non_Canonical_Compact_Size
		}
		return val, 5, nil

	case 0xFF:
		if len(data) < 9 {
			return 0, 0, .Unexpected_EOF
		}
		val =
			u64(data[1]) |
			u64(data[2]) << 8 |
			u64(data[3]) << 16 |
			u64(data[4]) << 24 |
			u64(data[5]) << 32 |
			u64(data[6]) << 40 |
			u64(data[7]) << 48 |
			u64(data[8]) << 56
		if val <= 0xFFFF_FFFF {
			return 0, 0, .Non_Canonical_Compact_Size
		}
		return val, 9, nil
	}

	return 0, 0, .Invalid_Compact_Size
}

// Returns how many bytes a CompactSize-encoded value would occupy.
compact_size_length :: proc(val: u64) -> int {
	if val < 0xFD {
		return 1
	} else if val <= 0xFFFF {
		return 3
	} else if val <= 0xFFFF_FFFF {
		return 5
	}
	return 9
}
