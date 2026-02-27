package consensus

MAX_MONEY :: i64(21_000_000 * 100_000_000)
COIN :: i64(100_000_000)
COINBASE_MATURITY :: 100

is_valid_amount :: proc(amount: i64) -> bool {
	return amount >= 0 && amount <= MAX_MONEY
}

get_block_subsidy :: proc(height: int, params: ^Chain_Params) -> i64 {
	halvings := height / params.subsidy_halving_interval
	if halvings >= 64 {
		return 0
	}
	subsidy := i64(50 * COIN)
	subsidy >>= uint(halvings)
	return subsidy
}
