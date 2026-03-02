package mempool

import "../consensus"
import "../script"
import "../wire"

// Relay policy constants.
MAX_STANDARD_TX_WEIGHT :: 400_000          // 100 kvB
MIN_RELAY_TX_FEE :: i64(1000)              // 1 sat/kvB minimum relay fee
MAX_MEMPOOL_SIZE :: 300                    // MB
MAX_MEMPOOL_ENTRIES :: 50_000
MIN_STANDARD_TX_VERSION :: i32(1)
MAX_STANDARD_TX_VERSION :: i32(2)
MAX_STANDARD_SIGOPS :: 4000
MAX_SCRIPT_SIZE :: 10_000
MAX_STANDARD_SCRIPTPUBKEY_SIZE :: 10_000
MAX_OP_RETURN_SIZE :: 83                   // Bitcoin Core -datacarriersize default (OP_RETURN + push + 80 bytes data)

// Check transaction against standard relay policy.
check_tx_policy :: proc(tx: ^wire.Tx) -> Mempool_Error {
	// 1. Version must be in [1, 2]
	if tx.version < MIN_STANDARD_TX_VERSION || tx.version > MAX_STANDARD_TX_VERSION {
		return .Non_Standard
	}

	// 2. Weight must not exceed limit
	weight := consensus.get_tx_weight(tx)
	if weight > MAX_STANDARD_TX_WEIGHT {
		return .Non_Standard
	}

	// 3. All outputs must have standard script types and not be dust
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

		// OP_RETURN: enforce datacarrier size limit (Bitcoin Core -datacarriersize=83)
		if stype == .Null_Data && len(spk) > MAX_OP_RETURN_SIZE {
			return .Non_Standard
		}

		// OP_RETURN outputs are exempt from dust check
		if stype != .Null_Data {
			if _is_dust(&tx.outputs[i]) {
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

// Check if an output is below the dust threshold.
_is_dust :: proc(output: ^wire.Tx_Out) -> bool {
	return output.value < get_dust_threshold(output.script_pubkey)
}
