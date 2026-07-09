// Package psbt implements BIP174 Partially Signed Bitcoin Transactions (v0)
// and the non-wallet operations exposed by Bitcoin Core's rawtransactions RPC
// category: decode, create, converttopsbt, combine, joinpsbts, finalize,
// analyze, and utxoupdatepsbt. Signing/funding (walletprocesspsbt,
// walletcreatefundedpsbt) is out of scope — this node has no wallet.
//
// The codec keeps every key-value pair of every map as raw bytes so that
// unknown/proprietary fields round-trip losslessly and combine can union
// maps without understanding their contents. Fields we act on (the unsigned
// tx, the UTXO records, final scripts) are parsed on demand via accessors.
package psbt

import "core:encoding/base64"
import "core:slice"

import "../wire"

// PSBT magic: "psbt" followed by 0xFF.
MAGIC := [5]u8{0x70, 0x73, 0x62, 0x74, 0xFF}

// Global-map key types (BIP174).
GLOBAL_UNSIGNED_TX :: 0x00
GLOBAL_XPUB        :: 0x01
GLOBAL_VERSION     :: 0xFB
GLOBAL_PROPRIETARY :: 0xFC

// Per-input key types.
IN_NON_WITNESS_UTXO    :: 0x00
IN_WITNESS_UTXO        :: 0x01
IN_PARTIAL_SIG         :: 0x02
IN_SIGHASH_TYPE        :: 0x03
IN_REDEEM_SCRIPT       :: 0x04
IN_WITNESS_SCRIPT      :: 0x05
IN_BIP32_DERIVATION    :: 0x06
IN_FINAL_SCRIPTSIG     :: 0x07
IN_FINAL_SCRIPTWITNESS :: 0x08
IN_POR_COMMITMENT      :: 0x09
IN_RIPEMD160           :: 0x0a
IN_SHA256              :: 0x0b
IN_HASH160             :: 0x0c
IN_HASH256             :: 0x0d
IN_TAP_KEY_SIG         :: 0x13
IN_TAP_SCRIPT_SIG      :: 0x14
IN_TAP_LEAF_SCRIPT     :: 0x15
IN_TAP_BIP32_DERIV     :: 0x16
IN_TAP_INTERNAL_KEY    :: 0x17
IN_TAP_MERKLE_ROOT     :: 0x18
IN_PROPRIETARY         :: 0xFC

// Per-output key types.
OUT_REDEEM_SCRIPT    :: 0x00
OUT_WITNESS_SCRIPT   :: 0x01
OUT_BIP32_DERIVATION :: 0x02
OUT_TAP_INTERNAL_KEY :: 0x05
OUT_TAP_TREE         :: 0x06
OUT_TAP_BIP32_DERIV  :: 0x07
OUT_PROPRIETARY      :: 0xFC

Error :: enum {
	None,
	Bad_Magic,
	Truncated,
	Duplicate_Key,
	No_Unsigned_Tx,
	Unsigned_Tx_Not_Empty, // unsigned tx has scriptSigs or witnesses (BIP174 forbids)
	Invalid_Tx,
	Bad_Base64,
}

// A single key-value record. `key` holds the full key field: a compactsize
// keytype followed by any keydata. `value` is the raw value field.
Key_Pair :: struct {
	key:   []byte,
	value: []byte,
}

Map :: [dynamic]Key_Pair

PSBT :: struct {
	global:  Map,
	inputs:  []Map,
	outputs: []Map,
	tx:      wire.Tx, // parsed copy of the global unsigned tx
}

// keytype returns the leading compactsize of a pair's key and the keydata
// that follows it (empty for the common single-byte keys).
keytype :: proc(kp: Key_Pair) -> (u64, []byte) {
	r := wire.reader_init(kp.key)
	t, err := wire.read_compact_size(&r)
	if err != nil {
		return 0xFFFF_FFFF_FFFF_FFFF, nil
	}
	return t, kp.key[r.pos:]
}

// map_find returns the first pair whose keytype matches, if any.
map_find :: proc(m: Map, kt: u64) -> (Key_Pair, bool) {
	for kp in m {
		t, _ := keytype(kp)
		if t == kt {
			return kp, true
		}
	}
	return {}, false
}

// --- deserialization ---

deserialize :: proc(data: []byte, allocator := context.allocator) -> (p: PSBT, err: Error) {
	if len(data) < 5 || !slice.equal(data[:5], MAGIC[:]) {
		return {}, .Bad_Magic
	}

	r := wire.reader_init(data)
	r.pos = 5

	p.global = _read_map(&r, allocator) or_return

	tx_pair, ok := map_find(p.global, GLOBAL_UNSIGNED_TX)
	if !ok {
		return {}, .No_Unsigned_Tx
	}
	tr := wire.reader_init(tx_pair.value)
	tx, tx_err := wire.deserialize_tx(&tr, allocator)
	if tx_err != nil {
		return {}, .Invalid_Tx
	}
	// BIP174: the unsigned tx must carry no signature data.
	if len(tx.witness) != 0 {
		return {}, .Unsigned_Tx_Not_Empty
	}
	for &txin in tx.inputs {
		if len(txin.script_sig) != 0 {
			return {}, .Unsigned_Tx_Not_Empty
		}
	}
	p.tx = tx

	p.inputs = make([]Map, len(tx.inputs), allocator)
	for i in 0 ..< len(tx.inputs) {
		p.inputs[i] = _read_map(&r, allocator) or_return
	}

	p.outputs = make([]Map, len(tx.outputs), allocator)
	for i in 0 ..< len(tx.outputs) {
		p.outputs[i] = _read_map(&r, allocator) or_return
	}

	return p, .None
}

deserialize_base64 :: proc(s: string, allocator := context.allocator) -> (p: PSBT, err: Error) {
	raw, b64_err := base64.decode(s, allocator = allocator)
	if b64_err != nil {
		return {}, .Bad_Base64
	}
	return deserialize(raw, allocator)
}

// _read_map reads key-value pairs until the 0x00 separator (keylen == 0).
_read_map :: proc(r: ^wire.Wire_Reader, allocator := context.allocator) -> (m: Map, err: Error) {
	m = make(Map, 0, allocator)
	for {
		if wire.reader_remaining(r) < 1 {
			return m, .Truncated
		}
		keylen, e1 := wire.read_compact_size(r)
		if e1 != nil {
			return m, .Truncated
		}
		if keylen == 0 {
			break // end-of-map separator
		}
		key, e2 := wire.read_bytes(r, int(keylen), allocator)
		if e2 != nil {
			return m, .Truncated
		}
		vallen, e3 := wire.read_compact_size(r)
		if e3 != nil {
			return m, .Truncated
		}
		val, e4 := wire.read_bytes(r, int(vallen), allocator)
		if e4 != nil {
			return m, .Truncated
		}
		for kp in m {
			if slice.equal(kp.key, key) {
				return m, .Duplicate_Key
			}
		}
		append(&m, Key_Pair{key = key, value = val})
	}
	return m, .None
}

// --- serialization ---

serialize :: proc(p: ^PSBT, allocator := context.allocator) -> []byte {
	w := wire.writer_init(allocator)
	wire.write_bytes(&w, MAGIC[:])
	_write_map(&w, p.global)
	for m in p.inputs {
		_write_map(&w, m)
	}
	for m in p.outputs {
		_write_map(&w, m)
	}
	return wire.writer_bytes(&w)
}

serialize_base64 :: proc(p: ^PSBT, allocator := context.allocator) -> string {
	raw := serialize(p, allocator)
	s, _ := base64.encode(raw, allocator = allocator)
	return s
}

_write_map :: proc(w: ^wire.Wire_Writer, m: Map) {
	for kp in m {
		wire.write_compact_size(w, u64(len(kp.key)))
		wire.write_bytes(w, kp.key)
		wire.write_compact_size(w, u64(len(kp.value)))
		wire.write_bytes(w, kp.value)
	}
	wire.write_byte(w, 0x00) // separator
}

// --- construction ---

// new_from_tx builds a fresh PSBT wrapping tx as its unsigned transaction,
// with empty per-input and per-output maps. Any scriptSigs / witnesses on the
// input tx are stripped (BIP174 requires the global unsigned tx be signatureless).
new_from_tx :: proc(tx: ^wire.Tx, allocator := context.allocator) -> PSBT {
	p: PSBT

	tx_bytes := _serialize_unsigned(tx, allocator)
	key := make([]byte, 1, allocator)
	key[0] = GLOBAL_UNSIGNED_TX
	p.global = make(Map, 0, allocator)
	append(&p.global, Key_Pair{key = key, value = tx_bytes})

	// Keep a parsed, cleaned copy of the tx for accessors.
	clean := tx^
	clean.witness = nil
	clean.inputs = make([]wire.Tx_In, len(tx.inputs), allocator)
	for i in 0 ..< len(tx.inputs) {
		clean.inputs[i] = tx.inputs[i]
		clean.inputs[i].script_sig = nil
	}
	p.tx = clean

	p.inputs = make([]Map, len(tx.inputs), allocator)
	for i in 0 ..< len(tx.inputs) {
		p.inputs[i] = make(Map, 0, allocator)
	}
	p.outputs = make([]Map, len(tx.outputs), allocator)
	for i in 0 ..< len(tx.outputs) {
		p.outputs[i] = make(Map, 0, allocator)
	}
	return p
}

// _serialize_unsigned serializes tx with empty scriptSigs and no witness data.
_serialize_unsigned :: proc(tx: ^wire.Tx, allocator := context.allocator) -> []byte {
	w := wire.writer_init(allocator)
	wire.write_i32le(&w, tx.version)
	wire.write_compact_size(&w, u64(len(tx.inputs)))
	for &txin in tx.inputs {
		wire.serialize_outpoint(&w, &txin.previous_output)
		wire.write_compact_size(&w, 0) // empty scriptSig
		wire.write_u32le(&w, txin.sequence)
	}
	wire.write_compact_size(&w, u64(len(tx.outputs)))
	for &txout in tx.outputs {
		wire.serialize_tx_out(&w, &txout)
	}
	wire.write_u32le(&w, tx.locktime)
	return wire.writer_bytes(&w)
}
