package chain

import "../crypto"
import "../storage"
import "../wire"

Hash256 :: crypto.Hash256
HASH_ZERO :: crypto.HASH_ZERO

Chain_Error :: enum {
	None,
	Block_Not_Found,
	Block_Already_Known,
	Invalid_Prev_Block,
	Utxo_Not_Found,
	Utxo_Already_Exists,
	Duplicate_Tx,
	Bad_Coinbase_Value,
	Bad_Script,
	Inputs_Unavailable,
	Coinbase_Not_Mature,
	Bip30_Violation,
	Undo_Data_Missing,
	Undo_Data_Corrupt,
	Storage_Error,
	Bad_Difficulty,
	Consensus_Error,
	Invalid_State,
}

Undo_Coin :: struct {
	outpoint: wire.Outpoint,
	coin:     storage.UTXO_Coin,
}

Block_Undo :: struct {
	spent_coins: []Undo_Coin,
}
