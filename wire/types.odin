package wire

import "../crypto"

// Hash type alias for convenience within wire package.
Hash256 :: crypto.Hash256
HASH_ZERO :: crypto.HASH_ZERO

// --- Protocol constants ---

MAINNET_MAGIC  :: u32(0xD9B4BEF9)
TESTNET3_MAGIC :: u32(0x0709110B)
TESTNET4_MAGIC :: u32(0x1C163F28)
SIGNET_MAGIC   :: u32(0x0A03CF40)
REGTEST_MAGIC  :: u32(0xDAB5BFFA)

PROTOCOL_VERSION :: u32(70016)

MAX_BLOCK_WEIGHT    :: 4_000_000
MAX_BLOCK_SIZE      :: 1_000_000 // legacy pre-SegWit limit
BLOCK_HEADER_SIZE   :: 80
COMMAND_SIZE        :: 12
MESSAGE_HEADER_SIZE :: 24
MAX_MESSAGE_PAYLOAD :: 32 * 1024 * 1024 // 32 MB

// Maximum number of items in inv/getdata messages.
MAX_INV_SIZE :: 50_000

// --- Wire errors ---

Wire_Error :: enum {
	None,
	Unexpected_EOF,
	Invalid_Compact_Size,
	Non_Canonical_Compact_Size,
	Payload_Too_Large,
	Bad_Checksum,
	Unknown_Command,
	Invalid_Witness_Flag,
	Invalid_Data,
}

// --- Core transaction/block types ---

// Outpoint references a specific output from a previous transaction.
Outpoint :: struct {
	hash:  Hash256,
	index: u32,
}

// Tx_In represents a transaction input.
Tx_In :: struct {
	previous_output: Outpoint,
	script_sig:      []byte,
	sequence:        u32,
}

// Tx_Out represents a transaction output.
Tx_Out :: struct {
	value:         i64,
	script_pubkey: []byte,
}

// Tx represents a full Bitcoin transaction.
// witness[i] holds the witness stack for input i (nil if non-SegWit).
Tx :: struct {
	version:  i32,
	inputs:   []Tx_In,
	outputs:  []Tx_Out,
	witness:  [][][]byte, // [input_idx][stack_item_idx]data
	locktime: u32,
}

// Block_Header represents the 80-byte block header.
Block_Header :: struct {
	version:     i32,
	prev_hash:   Hash256,
	merkle_root: Hash256,
	timestamp:   u32,
	bits:        u32,
	nonce:       u32,
}

// Block represents a full block with header and transactions.
Block :: struct {
	header: Block_Header,
	txs:    []Tx,
}

// --- Inventory types ---

Inv_Type :: enum u32 {
	Error          = 0,
	Tx             = 1,
	Block          = 2,
	Filtered_Block = 3,
	Compact_Block  = 4,
	Witness_Tx     = 0x40000001,
	Witness_Block  = 0x40000002,
}

Inv_Vector :: struct {
	type:  Inv_Type,
	hash:  Hash256,
}

// --- Network address types ---

Net_Address :: struct {
	services: u64,
	ip:       [16]byte, // IPv6-mapped IPv4 (::ffff:a.b.c.d)
	port:     u16,      // big-endian on wire
}

Net_Address_Timestamp :: struct {
	timestamp: u32,
	address:   Net_Address,
}

// --- Helpers ---

tx_has_witness :: proc(tx: ^Tx) -> bool {
	if tx.witness == nil {
		return false
	}
	for stack in tx.witness {
		if len(stack) > 0 {
			return true
		}
	}
	return false
}
