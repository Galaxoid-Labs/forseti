package consensus

import "../wire"

Chain_Params :: struct {
	name:                      string,
	network_magic:             u32,
	genesis_hash:              [32]byte, // natural byte order (internal)
	pow_limit:                 [32]byte, // big-endian 256-bit target
	pow_limit_bits:            u32,
	pow_no_retargeting:        bool,
	allow_min_difficulty:      bool,  // Testnet 20-minute min-difficulty rule
	enforce_bip94:             bool,  // Testnet4: don't allow min-difficulty at retarget boundaries
	target_timespan:           u32, // seconds
	target_spacing:            u32, // seconds
	retarget_interval:         int,
	subsidy_halving_interval:  int,
	// BIP activation heights
	p2sh_height:               int,  // BIP16
	bip34_height:              int,
	bip65_height:              int,
	bip66_height:              int,
	csv_height:                int,
	segwit_height:             int,
	taproot_height:            int,
	// BIP325 signet challenge script
	signet_challenge:          [128]byte,
	signet_challenge_len:      int,
	// Assumevalid: skip script verification below this height
	assumevalid_height:        int,
	// Address encoding prefixes
	p2pkh_prefix:              u8,
	p2sh_prefix:               u8,
	bech32_hrp:                string,
	// Hardcoded genesis block header
	genesis_header:            wire.Block_Header,
}

MAINNET_PARAMS: Chain_Params
TESTNET3_PARAMS: Chain_Params
TESTNET4_PARAMS: Chain_Params
SIGNET_PARAMS: Chain_Params
REGTEST_PARAMS: Chain_Params

@(init)
_init_params :: proc "contextless" () {
	MAINNET_PARAMS = Chain_Params {
		name                     = "mainnet",
		network_magic            = wire.MAINNET_MAGIC,
		pow_limit_bits           = 0x1d00ffff,
		pow_no_retargeting       = false,
		target_timespan          = 14 * 24 * 60 * 60, // 2 weeks
		target_spacing           = 10 * 60,            // 10 minutes
		retarget_interval        = 2016,
		subsidy_halving_interval = 210_000,
		p2sh_height              = 173_805,
		bip34_height             = 227_931,
		bip65_height             = 388_381,
		bip66_height             = 363_725,
		csv_height               = 419_328,
		segwit_height            = 481_824,
		taproot_height           = 709_632,
		p2pkh_prefix             = 0x00,
		p2sh_prefix              = 0x05,
		bech32_hrp               = "bc",
	}
	// Assumevalid: skip script verification below this height.
	// Height 880,000 is well-established mainnet (mined early 2024).
	MAINNET_PARAMS.assumevalid_height = 880_000

	// mainnet pow_limit: 00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff
	for i in 4 ..< 32 {
		MAINNET_PARAMS.pow_limit[i] = 0xff
	}
	// mainnet genesis hash (internal byte order, reversed from display)
	// Display: 000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f
	MAINNET_PARAMS.genesis_hash = {
		0x6f, 0xe2, 0x8c, 0x0a, 0xb6, 0xf1, 0xb3, 0x72,
		0xc1, 0xa6, 0xa2, 0x46, 0xae, 0x63, 0xf7, 0x4f,
		0x93, 0x1e, 0x83, 0x65, 0xe1, 0x5a, 0x08, 0x9c,
		0x68, 0xd6, 0x19, 0x00, 0x00, 0x00, 0x00, 0x00,
	}

	TESTNET3_PARAMS = Chain_Params {
		name                     = "testnet3",
		network_magic            = wire.TESTNET3_MAGIC,
		pow_limit_bits           = 0x1d00ffff,
		pow_no_retargeting       = false,
		allow_min_difficulty     = true,
		target_timespan          = 14 * 24 * 60 * 60,
		target_spacing           = 10 * 60,
		retarget_interval        = 2016,
		subsidy_halving_interval = 210_000,
		p2sh_height              = 514,
		bip34_height             = 21_111,
		bip65_height             = 581_885,
		bip66_height             = 330_776,
		csv_height               = 770_112,
		segwit_height            = 834_624,
		taproot_height           = 2_032_291,
		p2pkh_prefix             = 0x6F,
		p2sh_prefix              = 0xC4,
		bech32_hrp               = "tb",
	}
	TESTNET3_PARAMS.pow_limit = MAINNET_PARAMS.pow_limit
	TESTNET3_PARAMS.assumevalid_height = 2_100_000

	TESTNET4_PARAMS = Chain_Params {
		name                     = "testnet4",
		network_magic            = wire.TESTNET4_MAGIC,
		pow_limit_bits           = 0x1d00ffff,
		pow_no_retargeting       = false,
		allow_min_difficulty     = true,
		enforce_bip94            = true,
		target_timespan          = 14 * 24 * 60 * 60,
		target_spacing           = 10 * 60,
		retarget_interval        = 2016,
		subsidy_halving_interval = 210_000,
		p2sh_height              = 1,
		bip34_height             = 1,
		bip65_height             = 1,
		bip66_height             = 1,
		csv_height               = 1,
		segwit_height            = 1,
		taproot_height           = 1,
		p2pkh_prefix             = 0x6F,
		p2sh_prefix              = 0xC4,
		bech32_hrp               = "tb",
	}
	TESTNET4_PARAMS.pow_limit = MAINNET_PARAMS.pow_limit
	TESTNET4_PARAMS.assumevalid_height = 200_000

	SIGNET_PARAMS = Chain_Params {
		name                     = "signet",
		network_magic            = wire.SIGNET_MAGIC,
		pow_limit_bits           = 0x1e0377ae,
		pow_no_retargeting       = false,
		target_timespan          = 14 * 24 * 60 * 60,
		target_spacing           = 10 * 60,
		retarget_interval        = 2016,
		subsidy_halving_interval = 210_000,
		p2sh_height              = 1,
		bip34_height             = 1,
		bip65_height             = 1,
		bip66_height             = 1,
		csv_height               = 1,
		segwit_height            = 1,
		taproot_height           = 1,
		p2pkh_prefix             = 0x6F,
		p2sh_prefix              = 0xC4,
		bech32_hrp               = "tb",
	}
	// signet pow_limit: 00000377ae000000000000000000000000000000000000000000000000000000
	SIGNET_PARAMS.pow_limit[2] = 0x03
	SIGNET_PARAMS.pow_limit[3] = 0x77
	SIGNET_PARAMS.pow_limit[4] = 0xae

	// signet genesis hash (internal byte order, reversed from display)
	// Display: 00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6
	SIGNET_PARAMS.genesis_hash = {
		0xf6, 0x1e, 0xee, 0x3b, 0x63, 0xa3, 0x80, 0xa4,
		0x77, 0xa0, 0x63, 0xaf, 0x32, 0xb2, 0xbb, 0xc9,
		0x7c, 0x9f, 0xf9, 0xf0, 0x1f, 0x2c, 0x42, 0x25,
		0xe9, 0x73, 0x98, 0x81, 0x08, 0x00, 0x00, 0x00,
	}

	// Default signet challenge: OP_1 PUSH33 <key1> PUSH33 <key2> OP_2 OP_CHECKMULTISIG (71 bytes)
	// key1: 03ad5e0edad18cb1f0fc0d28a3d4f1f3e445640337489abb10404f2d1e086be430
	// key2: 0359ef5021964fe22d6f8e05b2463c9540ce96883fe3b278760f048f5189f2e6c4
	SIGNET_PARAMS.signet_challenge_len = 71
	SIGNET_PARAMS.signet_challenge[0] = 0x51 // OP_1
	SIGNET_PARAMS.signet_challenge[1] = 0x21 // PUSH33
	// key1: 03ad5e0edad18cb1f0fc0d28a3d4f1f3e445640337489abb10404f2d1e086be430
	SIGNET_PARAMS.signet_challenge[2]  = 0x03
	SIGNET_PARAMS.signet_challenge[3]  = 0xad
	SIGNET_PARAMS.signet_challenge[4]  = 0x5e
	SIGNET_PARAMS.signet_challenge[5]  = 0x0e
	SIGNET_PARAMS.signet_challenge[6]  = 0xda
	SIGNET_PARAMS.signet_challenge[7]  = 0xd1
	SIGNET_PARAMS.signet_challenge[8]  = 0x8c
	SIGNET_PARAMS.signet_challenge[9]  = 0xb1
	SIGNET_PARAMS.signet_challenge[10] = 0xf0
	SIGNET_PARAMS.signet_challenge[11] = 0xfc
	SIGNET_PARAMS.signet_challenge[12] = 0x0d
	SIGNET_PARAMS.signet_challenge[13] = 0x28
	SIGNET_PARAMS.signet_challenge[14] = 0xa3
	SIGNET_PARAMS.signet_challenge[15] = 0xd4
	SIGNET_PARAMS.signet_challenge[16] = 0xf1
	SIGNET_PARAMS.signet_challenge[17] = 0xf3
	SIGNET_PARAMS.signet_challenge[18] = 0xe4
	SIGNET_PARAMS.signet_challenge[19] = 0x45
	SIGNET_PARAMS.signet_challenge[20] = 0x64
	SIGNET_PARAMS.signet_challenge[21] = 0x03
	SIGNET_PARAMS.signet_challenge[22] = 0x37
	SIGNET_PARAMS.signet_challenge[23] = 0x48
	SIGNET_PARAMS.signet_challenge[24] = 0x9a
	SIGNET_PARAMS.signet_challenge[25] = 0xbb
	SIGNET_PARAMS.signet_challenge[26] = 0x10
	SIGNET_PARAMS.signet_challenge[27] = 0x40
	SIGNET_PARAMS.signet_challenge[28] = 0x4f
	SIGNET_PARAMS.signet_challenge[29] = 0x2d
	SIGNET_PARAMS.signet_challenge[30] = 0x1e
	SIGNET_PARAMS.signet_challenge[31] = 0x08
	SIGNET_PARAMS.signet_challenge[32] = 0x6b
	SIGNET_PARAMS.signet_challenge[33] = 0xe4
	SIGNET_PARAMS.signet_challenge[34] = 0x30
	SIGNET_PARAMS.signet_challenge[35] = 0x21 // PUSH33
	// key2
	SIGNET_PARAMS.signet_challenge[36] = 0x03
	SIGNET_PARAMS.signet_challenge[37] = 0x59
	SIGNET_PARAMS.signet_challenge[38] = 0xef
	SIGNET_PARAMS.signet_challenge[39] = 0x50
	SIGNET_PARAMS.signet_challenge[40] = 0x21
	SIGNET_PARAMS.signet_challenge[41] = 0x96
	SIGNET_PARAMS.signet_challenge[42] = 0x4f
	SIGNET_PARAMS.signet_challenge[43] = 0xe2
	SIGNET_PARAMS.signet_challenge[44] = 0x2d
	SIGNET_PARAMS.signet_challenge[45] = 0x6f
	SIGNET_PARAMS.signet_challenge[46] = 0x8e
	SIGNET_PARAMS.signet_challenge[47] = 0x05
	SIGNET_PARAMS.signet_challenge[48] = 0xb2
	SIGNET_PARAMS.signet_challenge[49] = 0x46
	SIGNET_PARAMS.signet_challenge[50] = 0x3c
	SIGNET_PARAMS.signet_challenge[51] = 0x95
	SIGNET_PARAMS.signet_challenge[52] = 0x40
	SIGNET_PARAMS.signet_challenge[53] = 0xce
	SIGNET_PARAMS.signet_challenge[54] = 0x96
	SIGNET_PARAMS.signet_challenge[55] = 0x88
	SIGNET_PARAMS.signet_challenge[56] = 0x3f
	SIGNET_PARAMS.signet_challenge[57] = 0xe3
	SIGNET_PARAMS.signet_challenge[58] = 0xb2
	SIGNET_PARAMS.signet_challenge[59] = 0x78
	SIGNET_PARAMS.signet_challenge[60] = 0x76
	SIGNET_PARAMS.signet_challenge[61] = 0x0f
	SIGNET_PARAMS.signet_challenge[62] = 0x04
	SIGNET_PARAMS.signet_challenge[63] = 0x8f
	SIGNET_PARAMS.signet_challenge[64] = 0x51
	SIGNET_PARAMS.signet_challenge[65] = 0x89
	SIGNET_PARAMS.signet_challenge[66] = 0xf2
	SIGNET_PARAMS.signet_challenge[67] = 0xe6
	SIGNET_PARAMS.signet_challenge[68] = 0xc4
	SIGNET_PARAMS.signet_challenge[69] = 0x52 // OP_2
	SIGNET_PARAMS.signet_challenge[70] = 0xae // OP_CHECKMULTISIG

	// Assumevalid: skip script verification below this height
	SIGNET_PARAMS.assumevalid_height = 267_665

	REGTEST_PARAMS = Chain_Params {
		name                     = "regtest",
		network_magic            = wire.REGTEST_MAGIC,
		pow_limit_bits           = 0x207fffff,
		pow_no_retargeting       = true,
		target_timespan          = 14 * 24 * 60 * 60,
		target_spacing           = 10 * 60,
		retarget_interval        = 2016,
		subsidy_halving_interval = 150,
		p2sh_height              = 0,
		bip34_height             = 0,
		bip65_height             = 0,
		bip66_height             = 0,
		csv_height               = 0,
		segwit_height            = 0,
		taproot_height           = 0,
		p2pkh_prefix             = 0x6F,
		p2sh_prefix              = 0xC4,
		bech32_hrp               = "bcrt",
	}
	// regtest pow_limit: 7fffff0000000000000000000000000000000000000000000000000000000000
	REGTEST_PARAMS.pow_limit[0] = 0x7f
	REGTEST_PARAMS.pow_limit[1] = 0xff
	REGTEST_PARAMS.pow_limit[2] = 0xff

	// Genesis block headers (version=1, prev_hash=zeros for all networks)
	// Merkle root is Satoshi's coinbase tx for all except testnet4 (BIP94)
	// Display: 4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b
	genesis_merkle := [32]byte{
		0x3b, 0xa3, 0xed, 0xfd, 0x7a, 0x7b, 0x12, 0xb2,
		0x7a, 0xc7, 0x2c, 0x3e, 0x67, 0x76, 0x8f, 0x61,
		0x7f, 0xc8, 0x1b, 0xc3, 0x88, 0x8a, 0x51, 0x32,
		0x3a, 0x9f, 0xb8, 0xaa, 0x4b, 0x1e, 0x5e, 0x4a,
	}

	MAINNET_PARAMS.genesis_header.version = 1
	MAINNET_PARAMS.genesis_header.merkle_root = genesis_merkle
	MAINNET_PARAMS.genesis_header.timestamp = 1231006505
	MAINNET_PARAMS.genesis_header.bits = 0x1d00ffff
	MAINNET_PARAMS.genesis_header.nonce = 2083236893

	TESTNET3_PARAMS.genesis_header.version = 1
	TESTNET3_PARAMS.genesis_header.merkle_root = genesis_merkle
	TESTNET3_PARAMS.genesis_header.timestamp = 1296688602
	TESTNET3_PARAMS.genesis_header.bits = 0x1d00ffff
	TESTNET3_PARAMS.genesis_header.nonce = 414098458

	// Testnet4 has a different genesis coinbase (BIP94).
	// Display: 7aa0a7ae1e223414cb807e40cd57e667b718e42aaf9306db9102fe28912b7b4e
	testnet4_genesis_merkle := [32]byte{
		0x4e, 0x7b, 0x2b, 0x91, 0x28, 0xfe, 0x02, 0x91,
		0xdb, 0x06, 0x93, 0xaf, 0x2a, 0xe4, 0x18, 0xb7,
		0x67, 0xe6, 0x57, 0xcd, 0x40, 0x7e, 0x80, 0xcb,
		0x14, 0x34, 0x22, 0x1e, 0xae, 0xa7, 0xa0, 0x7a,
	}

	TESTNET4_PARAMS.genesis_header.version = 1
	TESTNET4_PARAMS.genesis_header.merkle_root = testnet4_genesis_merkle
	TESTNET4_PARAMS.genesis_header.timestamp = 1714777860
	TESTNET4_PARAMS.genesis_header.bits = 0x1d00ffff
	TESTNET4_PARAMS.genesis_header.nonce = 393743547

	SIGNET_PARAMS.genesis_header.version = 1
	SIGNET_PARAMS.genesis_header.merkle_root = genesis_merkle
	SIGNET_PARAMS.genesis_header.timestamp = 1598918400
	SIGNET_PARAMS.genesis_header.bits = 0x1e0377ae
	SIGNET_PARAMS.genesis_header.nonce = 52613770

	REGTEST_PARAMS.genesis_header.version = 1
	REGTEST_PARAMS.genesis_header.merkle_root = genesis_merkle
	REGTEST_PARAMS.genesis_header.timestamp = 1296688602
	REGTEST_PARAMS.genesis_header.bits = 0x207fffff
	REGTEST_PARAMS.genesis_header.nonce = 2
}
