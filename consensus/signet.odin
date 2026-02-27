package consensus

import "../wire"

// Stub — full signet block validation deferred.
check_signet_block :: proc(block: ^wire.Block, params: ^Chain_Params) -> Consensus_Error {
	return .None
}
