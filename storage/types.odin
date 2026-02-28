package storage

import "../crypto"

Hash256 :: crypto.Hash256
HASH_ZERO :: crypto.HASH_ZERO

Storage_Error :: enum {
	None,
	IO_Error,
	Corrupt_Data,
	Not_Found,
	Full,
	Value_Too_Large,
	Bad_Magic,
	Bad_Version,
	LMDB_Error,
}
