package script

// Verify_Flag controls which script validation rules are enforced.
Verify_Flag :: enum {
	P2SH,                              // BIP16
	DER_Sig,                           // BIP66: strict DER signature encoding
	Low_S,                             // BIP62: require low-S signatures
	Strict_Enc,                        // Strict signature/pubkey encoding
	Null_Dummy,                        // BIP147: dummy element for CHECKMULTISIG must be empty
	Sig_Push_Only,                     // BIP62: scriptSig must be push-only
	Clean_Stack,                       // BIP62: stack must have exactly one element after eval
	Check_Locktime,                    // BIP65: OP_CHECKLOCKTIMEVERIFY
	Check_Sequence,                    // BIP112: OP_CHECKSEQUENCEVERIFY
	Witness,                           // BIP141: segregated witness
	Minimal_Data,                      // BIP62: push opcodes must use minimal encoding
	Minimal_If,                        // Require minimal encoding for IF/NOTIF arguments
	Null_Fail,                         // BIP146: failed sigs must be empty
	Witness_Pub_Key_Compressed,        // BIP143: witness pubkeys must be compressed
	Discourage_Upgradable_Nops,        // Discourage use of NOPs reserved for upgrades
	Discourage_Upgradable_Witness,     // Discourage unknown witness versions
	Taproot,                           // BIP341/342: validate witness v1 (P2TR) spends
}

Verify_Flags :: bit_set[Verify_Flag]

// Mandatory consensus flags for all blocks.
MANDATORY_FLAGS :: Verify_Flags{.P2SH}

// Standard flags for relay/mempool policy.
STANDARD_FLAGS :: Verify_Flags{
	.P2SH,
	.DER_Sig,
	.Low_S,
	.Strict_Enc,
	.Null_Dummy,
	.Sig_Push_Only,
	.Clean_Stack,
	.Check_Locktime,
	.Check_Sequence,
	.Witness,
	.Minimal_Data,
	.Minimal_If,
	.Null_Fail,
	.Witness_Pub_Key_Compressed,
	.Discourage_Upgradable_Nops,
	.Discourage_Upgradable_Witness,
	.Taproot,
}
