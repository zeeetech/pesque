//! Unit tests for proc: exit-code mapping semantics and the env-file mirror
//! mechanics. Argv construction is covered in driver_test.zig.
const std = @import("std");
const testing = std.testing;
const proc = @import("proc.zig");
const testutil = @import("testutil.zig");

test "capture trims and reports ok" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const cap = try ctx.host.capture(&.{ ctx.host.progs.docker, "inspect", "pesque", "--format", "{{.Config.Image}}" });
    defer ctx.host.freeCapture(cap);
    try testing.expect(cap.ok());
    try testing.expectEqualStrings("ghcr.io/zeeetech/pesque:latest", cap.line());
}

test "missing bare env entry is refused" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const envs = [_]proc.Env{.{ .key = "ACCOUNT_PASSWORD" }};
    try testing.expectError(error.MissingEnv, ctx.host.resolveEnv(&envs));
}

test "valued env entries are injected into the environment" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const envs = [_]proc.Env{.{ .key = "ACCOUNT_PASSWORD", .value = "s3cr3t" }};
    try ctx.host.resolveEnv(&envs);
    try testing.expectEqualStrings("s3cr3t", ctx.host.get("ACCOUNT_PASSWORD").?);
}
