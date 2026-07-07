package descriptor

import "core:testing"
import btccrypto "../crypto"

MAINNET :: Net_Params{p2pkh_version = 0x00, p2sh_version = 0x05, hrp = "bc"}

// Core's deriveaddresses help example — exercises origin prefix, xpub,
// path, wildcard, wpkh, bech32, AND the checksum in one shot.
CORE_WPKH_DESC :: "wpkh([d34db33f/84h/0h/0h]xpub6DJ2dNUysrn5Vt36jH2KLBT2i1auw1tTSSomg8PhqNiUtx8QX2SvC9nrHu81fT41fvDUnhMjEzQgXnQjKEu3oaqMSzhSrHMxyyoEAmUHQbY/0/*)#cjjspncu"

@(test)
test_descriptor_checksum :: proc(t: ^testing.T) {
	body := CORE_WPKH_DESC[:len(CORE_WPKH_DESC) - 9]
	sum, ok := checksum_create(body)
	testing.expect(t, ok, "checksum computes")
	testing.expect_value(t, sum, "cjjspncu")

	// Bad checksum must be rejected at parse.
	bad := "wpkh(0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798)#00000000"
	_, err := parse(bad, MAINNET, context.temp_allocator)
	testing.expect(t, err != "", "wrong checksum rejected")
}

// BIP32 test vector 1: CKDpub from m/0' to m/0'/1.
@(test)
test_bip32_ckd_pub :: proc(t: ^testing.T) {
	btccrypto.init_secp256k1()
	xpub_m0h := "xpub68Gmy5EdvgibQVfPdqkBBCHxA5htiqg55crXYuXoQRKfDBFA1WEjWgP6LHhwBZeNK1VTsfTFUHCdrfp1bgwQ9xv5ski8PX9rL2dZXvgGDnw"
	x, ok := parse_xpub(xpub_m0h)
	testing.expect(t, ok, "xpub parses")
	testing.expect_value(t, x.depth, u8(1))

	child, c_ok := ckd_pub(&x, 1)
	testing.expect(t, c_ok, "ckd_pub works")

	// Expected pubkey at m/0'/1 from the vector's xpub:
	// xpub6ASuArnXKPbfEwhqN6e3mwBcDTgzisQN1wXN9BJcM47sSikHjJf3UFHKkNAWbWMiGj7Wf5uMash7SyYq527Hqck2AxYysAA7xmALppuCkwQ
	want, w_ok := parse_xpub("xpub6ASuArnXKPbfEwhqN6e3mwBcDTgzisQN1wXN9BJcM47sSikHjJf3UFHKkNAWbWMiGj7Wf5uMash7SyYq527Hqck2AxYysAA7xmALppuCkwQ")
	testing.expect(t, w_ok, "expected xpub parses")
	testing.expect_value(t, child.pubkey, want.pubkey)
	testing.expect_value(t, child.chaincode, want.chaincode)

	// Hardened from xpub must fail.
	_, h_ok := ckd_pub(&x, 0x80000000)
	testing.expect(t, !h_ok, "hardened ckd_pub rejected")
}

// Core deriveaddresses doc example descriptor; expected addresses cross-
// verified with an independent from-scratch python EC/BIP32/bech32 impl.
@(test)
test_deriveaddresses_wpkh_vector :: proc(t: ^testing.T) {
	btccrypto.init_secp256k1()
	d, err := parse(CORE_WPKH_DESC, MAINNET, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, d.is_range, "wildcard descriptor is ranged")

	a0, ok0 := address(&d, 0, MAINNET)
	testing.expect(t, ok0, "derives index 0")
	testing.expect_value(t, a0, "bc1qg6ucjz7kgdedam7v5yarecy54uqw82yym06z3q")

	a1, ok1 := address(&d, 1, MAINNET)
	testing.expect(t, ok1, "derives index 1")
	testing.expect_value(t, a1, "bc1qgxexg7pg982urq8ekk3l8lq65zh7vwsrc9kgp9")
}

// BIP86 test vector: tr(xpub/0/*) at index 0 → first receiving address.
@(test)
test_tr_bip86_vector :: proc(t: ^testing.T) {
	btccrypto.init_secp256k1()
	desc := "tr(xpub6BgBgsespWvERF3LHQu6CnqdvfEvtMcQjYrcRzx53QJjSxarj2afYWcLteoGVky7D3UKDP9QyrLprQ3VCECoY49yfdDEHGCtMMj92pReUsQ/0/*)"
	d, err := parse(desc, MAINNET, context.temp_allocator)
	testing.expect_value(t, err, "")

	a0, ok := address(&d, 0, MAINNET)
	testing.expect(t, ok, "tr derives")
	testing.expect_value(t, a0, "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr")

	a1, ok1 := address(&d, 1, MAINNET)
	testing.expect(t, ok1, "tr derives index 1")
	testing.expect_value(t, a1, "bc1p4qhjn9zdvkux4e44uhx8tc55attvtyu358kutcqkudyccelu0was9fqzwh")
}

@(test)
test_descriptor_forms :: proc(t: ^testing.T) {
	btccrypto.init_secp256k1()
	key :: "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798" // generator point G

	// pkh of G — the canonical "satoshi" address form for G.
	d1, e1 := parse("pkh(" + key + ")", MAINNET, context.temp_allocator)
	testing.expect_value(t, e1, "")
	testing.expect(t, !d1.is_range, "fixed key is not ranged")
	a1, _ := address(&d1, 0, MAINNET)
	testing.expect_value(t, a1, "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")

	// sh(wpkh()) and wsh(multi()) parse + produce sane scripts.
	d2, e2 := parse("sh(wpkh(" + key + "))", MAINNET, context.temp_allocator)
	testing.expect_value(t, e2, "")
	spk2, _ := script_pubkey(&d2, 0)
	testing.expect_value(t, len(spk2), 23)
	testing.expect_value(t, spk2[0], byte(0xa9))

	d3, e3 := parse("wsh(sortedmulti(1," + key + ",03ac0e3df41cd992fedbdbf8b1a4b71465e1ea1a6d5d66007e29d2b8fed1adb821))", MAINNET, context.temp_allocator)
	testing.expect_value(t, e3, "")
	spk3, _ := script_pubkey(&d3, 0)
	testing.expect_value(t, len(spk3), 34)
	testing.expect_value(t, spk3[0], byte(0x00))
	testing.expect_value(t, spk3[1], byte(0x20))

	// addr() roundtrip.
	d4, e4 := parse("addr(1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH)", MAINNET, context.temp_allocator)
	testing.expect_value(t, e4, "")
	spk4, _ := script_pubkey(&d4, 0)
	spk1, _ := script_pubkey(&d1, 0)
	testing.expect_value(t, string(spk4), string(spk1))

	// raw() passthrough.
	d5, e5 := parse("raw(51)", MAINNET, context.temp_allocator)
	testing.expect_value(t, e5, "")
	spk5, _ := script_pubkey(&d5, 0)
	testing.expect_value(t, len(spk5), 1)
	testing.expect_value(t, spk5[0], byte(0x51))

	// Rejections.
	_, e6 := parse("combo(" + key + ")", MAINNET, context.temp_allocator)
	testing.expect(t, e6 != "", "combo rejected")
	_, e7 := parse("wpkh(xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi)", MAINNET, context.temp_allocator)
	testing.expect(t, e7 != "", "xprv rejected")
	_, e8 := parse("wpkh(xpub6DJ2dNUysrn5Vt36jH2KLBT2i1auw1tTSSomg8PhqNiUtx8QX2SvC9nrHu81fT41fvDUnhMjEzQgXnQjKEu3oaqMSzhSrHMxyyoEAmUHQbY/0h/*)", MAINNET, context.temp_allocator)
	testing.expect(t, e8 != "", "hardened path from xpub rejected")
}
