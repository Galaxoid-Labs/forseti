package btccrypto

import "core:c"

foreign import ripemd160_lib "../deps/lib/libripemd160.a"

RIPEMD160_DIGEST_SIZE :: 20

Hash160 :: [RIPEMD160_DIGEST_SIZE]byte

@(default_calling_convention = "c")
foreign ripemd160_lib {
	@(link_name = "ripemd160")
	_ripemd160 :: proc(msg: [^]u8, msg_len: c.size_t, digest: [^]u8) ---
}

// Computes RIPEMD-160 of the input data.
ripemd160 :: proc(data: []byte) -> Hash160 {
	result: Hash160
	_ripemd160(raw_data(data), c.size_t(len(data)), &result[0])
	return result
}
