package storage

import crypto "../crypto"

Hash256 :: crypto.Hash256

Storage_Error :: enum {
	None,
	IO_Error,
	Corrupt_Data,
}
