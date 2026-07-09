package psbt

import "core:encoding/base64"
import "core:slice"
import "core:testing"

import "../wire"

// BIP174 valid test vector: one P2PKH input (signed+finalized) and one
// P2SH-P2WPKH input, two outputs.
VALID_PSBT_B64 :: "cHNidP8BAKACAAAAAqsJSaCMWvfEm4IS9Bfi8Vqz9cM9zxU4IagTn4d6W3vkAAAAAAD+////qwlJoIxa98SbghL0F+LxWrP1wz3PFTghqBOfh3pbe+QBAAAAAP7///8CYDvqCwAAAAAZdqkUdopAu9dAy+gdmI5x3ipNXHE5ax2IrI4kAAAAAAAAGXapFG9GILVT+glechue4O/p+gOcykWXiKwAAAAAAAEHakcwRAIgR1lmF5fAGwNrJZKJSGhiGDR9iYZLcZ4ff89X0eURZYcCIFMJ6r9Wqk2Ikf/REf3xM286KdqGbX+EhtdVRs7tr5MZASEDXNxh/HupccC1AaZGoqg7ECy0OIEhfKaC3Ibi1z+ogpIAAQEgAOH1BQAAAAAXqRQ1RebjO4MsRwUPJNPuuTycA5SLx4cBBBYAFIXRNTfy4mVAWjTbr6nj3aAfuCMIAAAA"

@(test)
test_deserialize_valid_roundtrip :: proc(t: ^testing.T) {
	p, err := deserialize_base64(VALID_PSBT_B64, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(p.tx.inputs), 2)
	testing.expect_value(t, len(p.tx.outputs), 2)
	testing.expect_value(t, len(p.inputs), 2)
	testing.expect_value(t, len(p.outputs), 2)

	// Input 0 is finalized: it must carry a FINAL_SCRIPTSIG record.
	_, has_final := map_find(p.inputs[0], IN_FINAL_SCRIPTSIG)
	testing.expect(t, has_final, "input 0 should have a final scriptSig")

	// Input 1 carries a WITNESS_UTXO record.
	_, has_wu := map_find(p.inputs[1], IN_WITNESS_UTXO)
	testing.expect(t, has_wu, "input 1 should have a witness utxo")

	// Re-encoding must reproduce the exact original bytes.
	orig, _ := base64.decode(VALID_PSBT_B64, allocator = context.temp_allocator)
	got := serialize(&p, context.temp_allocator)
	testing.expect(t, slice.equal(orig, got), "round-trip must be byte-identical")
}

@(test)
test_invalid_bad_magic :: proc(t: ^testing.T) {
	// A raw network transaction — no PSBT magic.
	netxn := "AgAAAAEmgXE3Ht/yhek3re6ks3t4AAwFZsuzrWRkFxPKQhcb9gAAAABqRzBEAiBwsiRRI+a/R01gxbUMBD1MaRpdJDXwmjSnZiqdwlF5CgIgATKcqdrPKAvfMHQOwDkEIkIsgctFg5RXrrdvwS7dlbMBIQJlfRGNM1e44PTCzUbbezn22cONmnCry5st5dyNv+TOMf7///8C09/1BQAAAAAZdqkU0MWZA8W6woaHYOkP1SGkZlqnZSCIrADh9QUAAAAAF6kUNUXm4zuDLEcFDyTT7rk8nAOUi8eHsy4TAA=="
	_, err := deserialize_base64(netxn, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Magic)
}

@(test)
test_invalid_missing_outputs :: proc(t: ^testing.T) {
	// Global unsigned tx declares 2 outputs but the output maps are absent.
	missing := "cHNidP8BAHUCAAAAASaBcTce3/KF6Tet7qSze3gADAVmy7OtZGQXE8pCFxv2AAAAAAD+////AtPf9QUAAAAAGXapFNDFmQPFusKGh2DpD9UhpGZap2UgiKwA4fUFAAAAABepFDVF5uM7gyxHBQ8k0+65PJwDlIvHh7MuEwAAAQD9pQEBAAAAAAECiaPHHqtNIOA3G7ukzGmPopXJRjr6Ljl/hTPMti+VZ+UBAAAAFxYAFL4Y0VKpsBIDna89p95PUzSe7LmF/////4b4qkOnHf8USIk6UwpyN+9rRgi7st0tAXHmOuxqSJC0AQAAABcWABT+Pp7xp0XpdNkCxDVZQ6vLNL1TU/////8CAMLrCwAAAAAZdqkUhc/xCX/Z4Ai7NK9wnGIZeziXikiIrHL++E4sAAAAF6kUM5cluiHv1irHU6m80GfWx6ajnQWHAkcwRAIgJxK+IuAnDzlPVoMR3HyppolwuAJf3TskAinwf4pfOiQCIAGLONfc0xTnNMkna9b7QPZzMlvEuqFEyADS8vAtsnZcASED0uFWdJQbrUqZY3LLh+GFbTZSYG2YVi/jnF6efkE/IQUCSDBFAiEA0SuFLYXc2WHS9fSrZgZU327tzHlMDDPOXMMJ/7X85Y0CIGczio4OFyXBl/saiK9Z9R5E5CVbIBZ8hoQDHAXR8lkqASECI7cr7vCWXRC+B3jv7NYfysb3mk6haTkzgHNEZPhPKrMAAAAAAA=="
	_, err := deserialize_base64(missing, context.temp_allocator)
	testing.expect_value(t, err, Error.Truncated)
}

@(test)
test_invalid_duplicate_key :: proc(t: ^testing.T) {
	dup := "cHNidP8BAHUCAAAAASaBcTce3/KF6Tet7qSze3gADAVmy7OtZGQXE8pCFxv2AAAAAAD+////AtPf9QUAAAAAGXapFNDFmQPFusKGh2DpD9UhpGZap2UgiKwA4fUFAAAAABepFDVF5uM7gyxHBQ8k0+65PJwDlIvHh7MuEwAAAQD9pQEBAAAAAAECiaPHHqtNIOA3G7ukzGmPopXJRjr6Ljl/hTPMti+VZ+UBAAAAFxYAFL4Y0VKpsBIDna89p95PUzSe7LmF/////4b4qkOnHf8USIk6UwpyN+9rRgi7st0tAXHmOuxqSJC0AQAAABcWABT+Pp7xp0XpdNkCxDVZQ6vLNL1TU/////8CAMLrCwAAAAAZdqkUhc/xCX/Z4Ai7NK9wnGIZeziXikiIrHL++E4sAAAAF6kUM5cluiHv1irHU6m80GfWx6ajnQWHAkcwRAIgJxK+IuAnDzlPVoMR3HyppolwuAJf3TskAinwf4pfOiQCIAGLONfc0xTnNMkna9b7QPZzMlvEuqFEyADS8vAtsnZcASED0uFWdJQbrUqZY3LLh+GFbTZSYG2YVi/jnF6efkE/IQUCSDBFAiEA0SuFLYXc2WHS9fSrZgZU327tzHlMDDPOXMMJ/7X85Y0CIGczio4OFyXBl/saiK9Z9R5E5CVbIBZ8hoQDHAXR8lkqASECI7cr7vCWXRC+B3jv7NYfysb3mk6haTkzgHNEZPhPKrMAAAAAAQA/AgAAAAH//////////////////////////////////////////wAAAAAA/////wEAAAAAAAAAAANqAQAAAAAAAAAA"
	_, err := deserialize_base64(dup, context.temp_allocator)
	testing.expect_value(t, err, Error.Duplicate_Key)
}

@(test)
test_new_from_tx_strips_sigs :: proc(t: ^testing.T) {
	// Build a signed-looking tx, wrap it, and confirm the unsigned tx inside
	// the PSBT has empty scriptSigs and re-parses cleanly.
	prev: wire.Hash256
	prev[0], prev[1], prev[2] = 1, 2, 3
	tx := wire.Tx {
		version = 2,
		inputs = []wire.Tx_In{
			{
				previous_output = wire.Outpoint{hash = prev, index = 0},
				script_sig = []byte{0xAA, 0xBB, 0xCC}, // pretend signature
				sequence = 0xFFFFFFFF,
			},
		},
		outputs = []wire.Tx_Out{{value = 50000, script_pubkey = []byte{0x6a, 0x00}}},
		locktime = 0,
	}
	p := new_from_tx(&tx, context.temp_allocator)
	testing.expect_value(t, len(p.inputs), 1)
	testing.expect_value(t, len(p.outputs), 1)

	// The stored unsigned tx must have no scriptSig.
	tx_pair, ok := map_find(p.global, GLOBAL_UNSIGNED_TX)
	testing.expect(t, ok, "must have unsigned tx")
	r := wire.reader_init(tx_pair.value)
	parsed, err := wire.deserialize_tx(&r, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(parsed.inputs[0].script_sig), 0)

	// And the whole thing must survive a serialize/deserialize round-trip.
	b64 := serialize_base64(&p, context.temp_allocator)
	p2, err2 := deserialize_base64(b64, context.temp_allocator)
	testing.expect_value(t, err2, Error.None)
	testing.expect_value(t, len(p2.tx.inputs), 1)
}
