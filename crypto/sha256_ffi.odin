package btccrypto

// FFI bindings to Bitcoin Core's multi-backend SHA-256.
// Runtime-selects the best implementation: SHA-NI > AVX2 > SSE4.1 > ARM SHA > generic.

foreign import sha256_lib "../deps/lib/libsha256.a"

Sha256_Ctx :: struct {
	s:     [8]u32,
	buf:   [64]u8,
	bytes: u64,
}

@(default_calling_convention = "c")
foreign sha256_lib {
	@(link_name = "sha256_autodetect")
	sha256_ffi_autodetect :: proc() -> cstring ---

	@(link_name = "sha256_init")
	sha256_ffi_init :: proc(ctx: ^Sha256_Ctx) ---

	@(link_name = "sha256_update")
	sha256_ffi_update :: proc(ctx: ^Sha256_Ctx, data: [^]u8, len: uint) ---

	@(link_name = "sha256_finalize")
	sha256_ffi_finalize :: proc(ctx: ^Sha256_Ctx, hash: [^]u8) ---

	@(link_name = "sha256_reset")
	sha256_ffi_reset :: proc(ctx: ^Sha256_Ctx) ---

	@(link_name = "sha256_hash")
	sha256_ffi_hash :: proc(data: [^]u8, len: uint, hash: [^]u8) ---

	@(link_name = "sha256d")
	sha256_ffi_d :: proc(data: [^]u8, len: uint, hash: [^]u8) ---

	@(link_name = "sha256d_multi")
	sha256_ffi_d_multi :: proc(parts: [^][^]u8, lengths: [^]uint, count: uint, hash: [^]u8) ---

	@(link_name = "sha256d64")
	sha256_ffi_d64 :: proc(output: [^]u8, input: [^]u8, blocks: uint) ---
}
