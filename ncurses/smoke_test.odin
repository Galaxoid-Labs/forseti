package ncurses

import "core:testing"

// Bindings link-and-constants smoke test. Terminal init is NOT exercised —
// test runners have no TTY; the dashboard is verified manually and via the
// tui package's pure formatter tests.
@(test)
test_bindings_link :: proc(t: ^testing.T) {
	testing.expect_value(t, int(color_pair(3)), 3 << 8)
	testing.expect(t, A_BOLD != A_DIM, "attribute constants distinct")
}
