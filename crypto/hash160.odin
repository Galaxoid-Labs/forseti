package crypto

// Computes HASH160 = RIPEMD160(SHA256(data)).
// This is the standard Bitcoin address hash used in P2PKH and P2SH.
hash160 :: proc(data: []byte) -> Hash160 {
	sha := sha256_hash(data)
	return ripemd160(sha[:])
}
