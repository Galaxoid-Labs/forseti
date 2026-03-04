package mempool

// Fee rate: satoshis per virtual byte, stored as ratio to avoid floats.
Fee_Rate :: struct {
	satoshis: i64, // total fee in satoshis
	size:     int,  // virtual size in vbytes
}

// Construct a fee rate from total fee and vsize.
fee_rate :: proc(satoshis: i64, vsize: int) -> Fee_Rate {
	return Fee_Rate{satoshis = satoshis, size = max(vsize, 1)}
}

// Convert fee rate to satoshis per kilovirtual byte (for display).
fee_rate_per_kvb :: proc(fr: Fee_Rate) -> i64 {
	if fr.size == 0 {
		return 0
	}
	return (fr.satoshis * 1000) / i64(fr.size)
}

// Compare fee rates: a < b using cross-multiplication to avoid division.
fee_rate_less :: proc(a, b: Fee_Rate) -> bool {
	return a.satoshis * i64(b.size) < b.satoshis * i64(a.size)
}

// Minimum output value to not be considered dust.
// dust = 3 * (output_size + input_spending_size) * dust_relay_fee_per_byte
// dust_relay_fee = 3000 sat/kvB = 3 sat/byte (Bitcoin Core default)
DUST_RELAY_FEE_PER_KVB :: i64(3000)

get_dust_threshold :: proc(script_pubkey: []byte, dust_relay_fee: i64 = DUST_RELAY_FEE_PER_KVB) -> i64 {
	n := len(script_pubkey)

	// Output serialization: 8 (value) + compact_size(script_len) + script_len
	output_size := 8 + _compact_size_len(n) + n

	// Input spending size depends on script type
	input_size: int
	if n == 25 && script_pubkey[0] == 0x76 && script_pubkey[1] == 0xa9 {
		// P2PKH: 32 (txid) + 4 (vout) + 1 (script_len) + 107 (sig+pubkey) + 4 (sequence)
		input_size = 148
	} else if n == 23 && script_pubkey[0] == 0xa9 {
		// P2SH: estimate as P2SH-P2WPKH = 32+4+1+23+4 = 64 (non-witness) + witness
		input_size = 91
	} else if n == 22 && script_pubkey[0] == 0x00 && script_pubkey[1] == 0x14 {
		// P2WPKH: 32+4+1+0+4 = 41 base + 107 witness / 4 ≈ 68 vbytes
		input_size = 68
	} else if n == 34 && script_pubkey[0] == 0x00 && script_pubkey[1] == 0x20 {
		// P2WSH: conservative estimate
		input_size = 108
	} else if n == 34 && script_pubkey[0] == 0x51 && script_pubkey[1] == 0x20 {
		// P2TR: 32+4+1+0+4 = 41 base + 66 witness / 4 ≈ 58 vbytes
		input_size = 58
	} else {
		// Unknown: use P2PKH estimate
		input_size = 148
	}

	total := output_size + input_size
	// dust = 3 * total * (dust_relay_fee / 1000)
	return (3 * i64(total) * dust_relay_fee) / 1000
}

_compact_size_len :: proc(n: int) -> int {
	if n < 253 {
		return 1
	} else if n <= 0xffff {
		return 3
	} else if n <= 0xffffffff {
		return 5
	}
	return 9
}
