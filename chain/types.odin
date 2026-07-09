package chain

import crypto "../crypto"
import "../storage"
import "../wire"

Hash256 :: crypto.Hash256
HASH_ZERO :: crypto.HASH_ZERO

Chain_Error :: enum {
	None,
	Block_Not_Found,
	Block_Already_Known,
	Invalid_Prev_Block,
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
	Non_Final_Tx,
	Consensus_Error,
	Drivechain_Violation,
	Supply_Invariant_Violation,
}

Undo_Coin :: struct {
	outpoint: wire.Outpoint,
	coin:     storage.UTXO_Coin,
}

Block_Undo :: struct {
	spent_coins: []Undo_Coin,
}
