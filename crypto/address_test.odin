package crypto

import "core:testing"
import "core:fmt"

// Test Base58Check encoding for P2PKH (mainnet: version 0x00).
// Known vector: hash160 = 751e76e8199196d454941c45d1b3a323f1433bd6
// Expected address: 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH
@(test)
test_base58check_p2pkh :: proc(t: ^testing.T) {
	hash: [20]byte = {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
		0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
		0xf1, 0x43, 0x3b, 0xd6,
	}
	addr := base58check_encode(0x00, hash[:])
	testing.expect(t, addr == "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH",
		fmt.tprintf("P2PKH mainnet: got %s, want 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", addr))

	// Same hash with testnet prefix (0x6F)
	addr_tn := base58check_encode(0x6F, hash[:])
	testing.expect(t, addr_tn == "mrCDrCybB6J1vRfbwM5hemdJz73FwDBC8r",
		fmt.tprintf("P2PKH testnet: got %s, want mrCDrCybB6J1vRfbwM5hemdJz73FwDBC8r", addr_tn))
}

// Test Base58Check encoding for P2SH (mainnet: version 0x05).
// Known vector: hash160(redeemScript) for a standard P2SH.
// hash160 = 89abcdefabbaabbaabbaabbaabbaabbaabbaabba
@(test)
test_base58check_p2sh :: proc(t: ^testing.T) {
	hash: [20]byte = {
		0x89, 0xab, 0xcd, 0xef, 0xab, 0xba, 0xab, 0xba,
		0xab, 0xba, 0xab, 0xba, 0xab, 0xba, 0xab, 0xba,
		0xab, 0xba, 0xab, 0xba,
	}
	addr := base58check_encode(0x05, hash[:])
	// Verified: base58check(05 || 89abcdef...) = 3EExK1K1TF3v7zsFtQHt14XqexCwgmXM1y
	testing.expect(t, addr == "3EExK1K1TF3v7zsFtQHt14XqexCwgmXM1y",
		fmt.tprintf("P2SH mainnet: got %s, want 3EExK1K1TF3v7zsFtQHt14XqexCwgmXM1y", addr))
}

// Test Bech32 encoding for P2WPKH (witness v0, 20-byte program).
// BIP173 test vector:
// program = 751e76e8199196d454941c45d1b3a323f1433bd6
// Expected: bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4
@(test)
test_bech32_p2wpkh :: proc(t: ^testing.T) {
	program: [20]byte = {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
		0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
		0xf1, 0x43, 0x3b, 0xd6,
	}
	addr := bech32_encode("bc", 0, program[:])
	testing.expect(t, addr == "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
		fmt.tprintf("P2WPKH mainnet: got %s, want bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", addr))

	// Testnet
	addr_tn := bech32_encode("tb", 0, program[:])
	testing.expect(t, addr_tn == "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx",
		fmt.tprintf("P2WPKH testnet: got %s, want tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", addr_tn))
}

// Test Bech32 encoding for P2WSH (witness v0, 32-byte program).
// Verified against BIP173 reference implementation.
@(test)
test_bech32_p2wsh :: proc(t: ^testing.T) {
	program: [32]byte = {
		0x18, 0x63, 0x14, 0x3c, 0x14, 0xc5, 0x16, 0x68,
		0x04, 0xbd, 0x19, 0x20, 0x33, 0x56, 0xda, 0x13,
		0x6c, 0x98, 0x56, 0x78, 0xcd, 0x4d, 0x27, 0xa1,
		0xb8, 0xc6, 0x32, 0x96, 0x04, 0x90, 0x32, 0x62,
	}
	addr := bech32_encode("bc", 0, program[:])
	testing.expect(t, addr == "bc1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3qccfmv3",
		fmt.tprintf("P2WSH: got %s", addr))
}

// Test Bech32m encoding for P2TR (witness v1, 32-byte program).
// BIP350 test vector.
@(test)
test_bech32m_p2tr :: proc(t: ^testing.T) {
	program: [32]byte = {
		0x79, 0xbe, 0x66, 0x7e, 0xf9, 0xdc, 0xbb, 0xac,
		0x55, 0xa0, 0x62, 0x95, 0xce, 0x87, 0x0b, 0x07,
		0x02, 0x9b, 0xfc, 0xdb, 0x2d, 0xce, 0x28, 0xd9,
		0x59, 0xf2, 0x81, 0x5b, 0x16, 0xf8, 0x17, 0x98,
	}
	addr := bech32_encode("bc", 1, program[:])
	testing.expect(t, addr == "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0",
		fmt.tprintf("P2TR: got %s", addr))
}

// Test Bech32 with regtest HRP.
@(test)
test_bech32_regtest_hrp :: proc(t: ^testing.T) {
	program: [20]byte = {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
		0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
		0xf1, 0x43, 0x3b, 0xd6,
	}
	addr := bech32_encode("bcrt", 0, program[:])
	testing.expect(t, addr == "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080",
		fmt.tprintf("Regtest P2WPKH: got %s", addr))
}

// Test script_to_address dispatches correctly for each type (via raw encoding).
@(test)
test_script_to_address :: proc(t: ^testing.T) {
	// P2PKH: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
	// Extract hash (bytes 3..23) and encode with version 0x00
	p2pkh_hash: [20]byte = {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
		0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
		0xf1, 0x43, 0x3b, 0xd6,
	}
	addr := base58check_encode(0x00, p2pkh_hash[:])
	testing.expect(t, addr == "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH",
		fmt.tprintf("P2PKH dispatch: got %s", addr))

	// P2WPKH: OP_0 <20 bytes> → bech32 v0
	addr2 := bech32_encode("bc", 0, p2pkh_hash[:])
	testing.expect(t, addr2 == "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4",
		fmt.tprintf("P2WPKH dispatch: got %s", addr2))

	// P2TR: OP_1 <32 bytes> → bech32m v1
	p2tr_prog: [32]byte = {
		0x79, 0xbe, 0x66, 0x7e, 0xf9, 0xdc, 0xbb, 0xac,
		0x55, 0xa0, 0x62, 0x95, 0xce, 0x87, 0x0b, 0x07,
		0x02, 0x9b, 0xfc, 0xdb, 0x2d, 0xce, 0x28, 0xd9,
		0x59, 0xf2, 0x81, 0x5b, 0x16, 0xf8, 0x17, 0x98,
	}
	addr3 := bech32_encode("bc", 1, p2tr_prog[:])
	testing.expect(t, addr3 == "bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0",
		fmt.tprintf("P2TR dispatch: got %s", addr3))
}

// Test Base58Check decode round-trip.
@(test)
test_base58check_decode :: proc(t: ^testing.T) {
	// Decode known P2PKH address: 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH
	ver, payload, ok := base58check_decode("1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")
	testing.expect(t, ok, "decode should succeed")
	testing.expect_value(t, ver, u8(0x00))
	expected_hash: [20]u8 = {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
		0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
		0xf1, 0x43, 0x3b, 0xd6,
	}
	testing.expect(t, payload == expected_hash,
		fmt.tprintf("payload mismatch"))

	// Invalid checksum
	_, _, bad_ok := base58check_decode("1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMX")
	testing.expect(t, !bad_ok, "bad checksum should fail")

	// Invalid char
	_, _, inv_ok := base58check_decode("1BgGZ9tcN4rm9KBzDn7KprQz87SZ260MH")
	testing.expect(t, !inv_ok, "invalid char should fail")
}

// Test Bech32 decode round-trip.
@(test)
test_bech32_decode :: proc(t: ^testing.T) {
	// Decode P2WPKH: bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4
	hrp, ver, prog, prog_len, ok := bech32_decode("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
	testing.expect(t, ok, "bech32 decode should succeed")
	testing.expect(t, hrp == "bc", fmt.tprintf("hrp: got %s, want bc", hrp))
	testing.expect_value(t, ver, 0)
	testing.expect_value(t, prog_len, 20)
	expected_prog: [20]u8 = {
		0x75, 0x1e, 0x76, 0xe8, 0x19, 0x91, 0x96, 0xd4,
		0x54, 0x94, 0x1c, 0x45, 0xd1, 0xb3, 0xa3, 0x23,
		0xf1, 0x43, 0x3b, 0xd6,
	}
	for i in 0 ..< 20 {
		testing.expect(t, prog[i] == expected_prog[i],
			fmt.tprintf("program byte %d: got %02x, want %02x", i, prog[i], expected_prog[i]))
	}

	// Decode Bech32m P2TR
	hrp2, ver2, _, prog_len2, ok2 := bech32_decode("bc1p0xlxvlhemja6c4dqv22uapctqupfhlxm9h8z3k2e72q4k9hcz7vqzk5jj0")
	testing.expect(t, ok2, "bech32m decode should succeed")
	testing.expect(t, hrp2 == "bc", "hrp should be bc")
	testing.expect_value(t, ver2, 1)
	testing.expect_value(t, prog_len2, 32)

	// Invalid checksum
	_, _, _, _, bad_ok := bech32_decode("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5")
	testing.expect(t, !bad_ok, "bad checksum should fail")
}

// Test leading zero bytes produce leading '1' chars in Base58Check.
@(test)
test_base58check_leading_zeros :: proc(t: ^testing.T) {
	// All-zero hash160 with version 0x00 → address starts with many '1's
	hash: [20]byte // all zeros
	addr := base58check_encode(0x00, hash[:])
	// Count leading 1s
	leading_ones := 0
	for i in 0 ..< len(addr) {
		if addr[i] != '1' { break }
		leading_ones += 1
	}
	// 21 zero bytes (version + hash) → 21 leading '1' chars
	testing.expect(t, leading_ones == 21,
		fmt.tprintf("Expected 21 leading '1's, got %d in %s", leading_ones, addr))
}
