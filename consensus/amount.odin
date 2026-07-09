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

// Maximum possible coin supply at `height`: the sum of every block subsidy from
// genesis through `height` inclusive. Coins are ONLY created by coinbases, and
// spending to fees / provably-unspendable outputs only SHRINKS the live set, so
// the total value of the UTXO set must NEVER exceed this. A total above it is
// proof of inflation or a UTXO-accounting bug — the cheapest global correctness
// invariant the node has (see chain.check_supply_invariant). O(halvings) = ~33.
get_cumulative_subsidy :: proc(height: int, params: ^Chain_Params) -> i64 {
	if height < 0 {
		return 0
	}
	total := i64(0)
	subsidy := i64(50 * COIN)
	remaining := i64(height) + 1 // blocks 0..height inclusive
	interval := i64(params.subsidy_halving_interval)
	for remaining > 0 && subsidy > 0 {
		n := min(remaining, interval)
		total += n * subsidy
		remaining -= n
		subsidy >>= 1
	}
	return total
}
