package consensus

import "../wire"

Chain_Params :: struct {
	name:                      string,
	network_magic:             u32,
	genesis_hash:              [32]byte, // natural byte order (internal)
	pow_limit:                 [32]byte, // big-endian 256-bit target
	pow_limit_bits:            u32,
	pow_no_retargeting:        bool,
	target_timespan:           u32, // seconds
	target_spacing:            u32, // seconds
	retarget_interval:         int,
	subsidy_halving_interval:  int,
	// BIP activation heights
	bip34_height:              int,
	bip65_height:              int,
	bip66_height:              int,
	csv_height:                int,
	segwit_height:             int,
	taproot_height:            int,
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
		bip34_height             = 227_931,
		bip65_height             = 388_381,
		bip66_height             = 363_725,
		csv_height               = 419_328,
		segwit_height            = 481_824,
		taproot_height           = 709_632,
	}
	// mainnet pow_limit: 00000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffff
	MAINNET_PARAMS.pow_limit[3] = 0xff
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
		target_timespan          = 14 * 24 * 60 * 60,
		target_spacing           = 10 * 60,
		retarget_interval        = 2016,
		subsidy_halving_interval = 210_000,
		bip34_height             = 1,
		bip65_height             = 1,
		bip66_height             = 1,
		csv_height               = 1,
		segwit_height            = 1,
		taproot_height           = 1,
	}
	TESTNET3_PARAMS.pow_limit = MAINNET_PARAMS.pow_limit

	TESTNET4_PARAMS = Chain_Params {
		name                     = "testnet4",
		network_magic            = wire.TESTNET4_MAGIC,
		pow_limit_bits           = 0x1d00ffff,
		pow_no_retargeting       = false,
		target_timespan          = 14 * 24 * 60 * 60,
		target_spacing           = 10 * 60,
		retarget_interval        = 2016,
		subsidy_halving_interval = 210_000,
		bip34_height             = 1,
		bip65_height             = 1,
		bip66_height             = 1,
		csv_height               = 1,
		segwit_height            = 1,
		taproot_height           = 1,
	}
	TESTNET4_PARAMS.pow_limit = MAINNET_PARAMS.pow_limit

	SIGNET_PARAMS = Chain_Params {
		name                     = "signet",
		network_magic            = wire.SIGNET_MAGIC,
		pow_limit_bits           = 0x1e0377ae,
		pow_no_retargeting       = false,
		target_timespan          = 14 * 24 * 60 * 60,
		target_spacing           = 10 * 60,
		retarget_interval        = 2016,
		subsidy_halving_interval = 210_000,
		bip34_height             = 1,
		bip65_height             = 1,
		bip66_height             = 1,
		csv_height               = 1,
		segwit_height            = 1,
		taproot_height           = 1,
	}
	// signet pow_limit: 00000377ae000000000000000000000000000000000000000000000000000000
	SIGNET_PARAMS.pow_limit[2] = 0x03
	SIGNET_PARAMS.pow_limit[3] = 0x77
	SIGNET_PARAMS.pow_limit[4] = 0xae

	REGTEST_PARAMS = Chain_Params {
		name                     = "regtest",
		network_magic            = wire.REGTEST_MAGIC,
		pow_limit_bits           = 0x207fffff,
		pow_no_retargeting       = true,
		target_timespan          = 14 * 24 * 60 * 60,
		target_spacing           = 10 * 60,
		retarget_interval        = 2016,
		subsidy_halving_interval = 150,
		bip34_height             = 0,
		bip65_height             = 0,
		bip66_height             = 0,
		csv_height               = 0,
		segwit_height            = 0,
		taproot_height           = 0,
	}
	// regtest pow_limit: 7fffff0000000000000000000000000000000000000000000000000000000000
	REGTEST_PARAMS.pow_limit[0] = 0x7f
	REGTEST_PARAMS.pow_limit[1] = 0xff
	REGTEST_PARAMS.pow_limit[2] = 0xff
}
