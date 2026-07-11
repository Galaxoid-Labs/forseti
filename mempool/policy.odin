package mempool

import "../consensus"
import "../script"
import "../wire"

// Relay policy constants.
MAX_STANDARD_TX_WEIGHT :: 400_000          // 100 kvB
MIN_STANDARD_TX_VERSION :: i32(1)
MAX_STANDARD_TX_VERSION :: i32(2)
MAX_STANDARD_SIGOPS :: 4000
MAX_STANDARD_SCRIPTPUBKEY_SIZE :: 10_000
MAX_OP_RETURN_SIZE :: 83                   // Bitcoin Core -datacarriersize default (OP_RETURN + push + 80 bytes data)
MAX_OP_RETURN_COUNT :: 1                    // -datacarriercount default: max OP_RETURN outputs/tx (1 = pre-Core-v30; v30 relaxed to many)

// Check transaction against standard relay policy.
check_tx_policy :: proc(tx: ^wire.Tx, config: ^Mempool_Config = nil) -> Mempool_Error {
	// 1. Version must be in [1, 2]
	if tx.version < MIN_STANDARD_TX_VERSION || tx.version > MAX_STANDARD_TX_VERSION {
		return .Non_Standard
	}

	// 2. Weight must not exceed limit
	weight := consensus.get_tx_weight(tx)
	if weight > MAX_STANDARD_TX_WEIGHT {
		return .Non_Standard
	}

	// Resolve config values (use defaults if no config provided)
	datacarrier := config != nil ? config.datacarrier : true
	datacarrier_size := config != nil ? config.datacarrier_size : MAX_OP_RETURN_SIZE
	datacarrier_count := config != nil ? config.datacarrier_count : MAX_OP_RETURN_COUNT
	permit_bare_multisig := config != nil ? config.permit_bare_multisig : true
	dust_relay_fee := config != nil ? config.dust_relay_fee : DUST_RELAY_FEE_PER_KVB

	// 3. All outputs must have standard script types and not be dust
	null_data_count := 0 // number of OP_RETURN (data-carrier) outputs seen
	for i in 0 ..< len(tx.outputs) {
		spk := tx.outputs[i].script_pubkey

		// Script pubkey must not be too large
		if len(spk) > MAX_STANDARD_SCRIPTPUBKEY_SIZE {
			return .Non_Standard
		}

		// Must be a standard output type
		stype := script.classify_script(spk)
		if stype == .Non_Standard {
			return .Non_Standard
		}

		// OP_RETURN: reject if datacarrier disabled, over the size limit, or if the
		// tx has more data-carrier outputs than allowed. datacarrier_count defaults
		// to 1 (pre-Core-v30 single-OP_RETURN policy); Core v30 relaxed relay to
		// permit multiple. Raise --datacarriercount to allow more (e.g. to match the
		// permissive ecash/v30 relay policy).
		if stype == .Null_Data {
			if !datacarrier {
				return .Non_Standard
			}
			if len(spk) > datacarrier_size {
				return .Non_Standard
			}
			null_data_count += 1
			if null_data_count > datacarrier_count {
				return .Non_Standard
			}
		}

		// Bare multisig: reject if not permitted
		// Note: our classify_script already classifies bare multisig as Non_Standard,
		// so this check only matters if classify_script is extended to recognize it.
		if !permit_bare_multisig && _is_bare_multisig(spk) {
			return .Non_Standard
		}

		// OP_RETURN outputs are exempt from dust check
		if stype != .Null_Data {
			if _is_dust_with_fee(&tx.outputs[i], dust_relay_fee) {
				return .Non_Standard
			}
		}

		// No null (zero) values on non-data outputs
		if stype != .Null_Data && tx.outputs[i].value == 0 {
			return .Non_Standard
		}
	}

	// 4. All scriptSig must be push-only
	for i in 0 ..< len(tx.inputs) {
		if len(tx.inputs[i].script_sig) > 0 && !script.is_push_only(tx.inputs[i].script_sig) {
			return .Non_Standard
		}
	}

	// 5. Sigops check
	sigops := 0
	for i in 0 ..< len(tx.inputs) {
		sigops += consensus.count_legacy_sigops(tx.inputs[i].script_sig)
	}
	for i in 0 ..< len(tx.outputs) {
		sigops += consensus.count_legacy_sigops(tx.outputs[i].script_pubkey)
	}
	if sigops > MAX_STANDARD_SIGOPS {
		return .Too_Many_Sigops
	}

	return .None
}


// Check if an output is below the dust threshold with a custom dust relay fee.
_is_dust_with_fee :: proc(output: ^wire.Tx_Out, dust_relay_fee: i64) -> bool {
	return output.value < get_dust_threshold(output.script_pubkey, dust_relay_fee)
}

// Check if a script is bare multisig: OP_m <pubkeys...> OP_n OP_CHECKMULTISIG
_is_bare_multisig :: proc(spk: []byte) -> bool {
	if len(spk) < 3 {
		return false
	}
	// Last byte must be OP_CHECKMULTISIG (0xae)
	if spk[len(spk) - 1] != 0xae {
		return false
	}
	// First byte: OP_1..OP_16 (0x51..0x60)
	if spk[0] < 0x51 || spk[0] > 0x60 {
		return false
	}
	// Second-to-last byte: OP_1..OP_16 (n)
	if spk[len(spk) - 2] < 0x51 || spk[len(spk) - 2] > 0x60 {
		return false
	}
	return true
}
