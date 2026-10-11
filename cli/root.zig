//! Binary root. Keeping the module root at `cli/` (rather than `src/`) lets
//! the tests embed the fake-binaries scripts from `test/shims/` directly.
pub const main = @import("src/main.zig").main;

// Test collection starts here: reference every test file (and the root
// source, for its own test blocks) so `zig build test` actually runs them.
test {
    _ = @import("src/main.zig");
    _ = @import("src/proc_test.zig");
    _ = @import("src/driver_test.zig");
    _ = @import("src/main_test.zig");
}
