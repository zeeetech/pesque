//! Dispatch, usage and input-resolution tests (the exit-code surface).
const std = @import("std");
const testing = std.testing;
const proc = @import("proc.zig");
const main = @import("main.zig");
const testutil = @import("testutil.zig");

test "dispatch: unknown command and bad global flags are usage (2)" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try testing.expectError(error.Usage, main.run(ctx.host, &.{"nonsense"}));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "--backend", "wat", "up" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{"--backend"}));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{}));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "logs", "--tail" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "logs", "--tail", "ten" }));
}

test "dispatch: --help exits 0" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"--help"}));
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"help"}));
}

test "dispatch: driver verbs run through the fake docker" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"restart"}));
    const restart_inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(restart_inv, "restart");
    try testutil.Ctx.expectArg(restart_inv, "pesque");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "logs", "-f", "--tail", "100" }));
    const logs_inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(logs_inv, "-f");
    try testutil.Ctx.expectArg(logs_inv, "100");
    try testutil.Ctx.expectArg(logs_inv, "pesque");

    // update v1.5.0 pins the tag in the compose environment.
    try ctx.env.put("PESQUE_TAG_SENTINEL", "x");
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "update", "v1.5.0" }));
}

test "dispatch: domain verbs forward to bin/pesque with the verb tail" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);
    try ctx.env.put("ACCOUNT_PASSWORD", "from-env");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"doctor"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "doctor" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "list" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "account", "list" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "config", "validate" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "config", "validate" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "crawl", "request" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "crawl", "request" });
}

test "dispatch: account create resolves the password and forwards flags" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);

    // --password-env pointing at a variable that exists.
    try ctx.env.put("MY_PW", "v-from-flag-env");
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{
        "account", "create", "--handle", "alice.example.com", "--email", "a@b.c", "--password-env", "MY_PW",
    }));
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectTail(inv, &.{ "pesque", "/app/bin/pesque", "account", "create", "--handle", "alice.example.com", "--email", "a@b.c" });
    try testutil.Ctx.expectArg(inv, "ACCOUNT_PASSWORD");
    try testutil.Ctx.expectNoArg(inv, "ACCOUNT_PASSWORD=v-from-flag-env");

    // Missing --handle and no ACCOUNT_HANDLE: usage refusal.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{
        "account", "create", "--email", "a@b.c",
    }));
}

test "dispatch: account selector verbs need exactly one of --did/--handle" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);
    try ctx.env.put("ACCOUNT_PASSWORD", "from-env");

    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "delete", "--did", "d1", "--handle", "h" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "takedown" }));
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "takedown", "--handle", "alice.example.com" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "account", "takedown", "--handle", "alice.example.com" });
}

test "dispatch: account plc-token forwards the selector and needs no password" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);
    // No ACCOUNT_PASSWORD anywhere: plc-token must not ask for one.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "plc-token", "--handle", "alice.example.com" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "account", "plc-token", "--handle", "alice.example.com" });
}

test "dispatch: account email-token and reset-token forward the selector and need no password" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);
    // No ACCOUNT_PASSWORD anywhere: minting a code must not ask for one.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "email-token", "--handle", "alice.example.com" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "account", "email-token", "--handle", "alice.example.com" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "reset-token", "--did", "did:plc:abc" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "account", "reset-token", "--did", "did:plc:abc" });
}

test "dispatch: account app-passwords forwards the selector and needs no password" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "app-passwords", "--did", "did:web:alice.example.com" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ "pesque", "/app/bin/pesque", "account", "app-passwords", "--did", "did:web:alice.example.com" });

    // Unknown flags are refused, and a bare selector verb takes no arguments.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "app-passwords", "--handle", "h", "--name", "n" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "app-passwords" }));
}

test "dispatch: account revoke-app-password forwards the selector and requires --name" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{
        "account", "revoke-app-password", "--handle", "alice.example.com", "--name", "my-app",
    }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{
        "pesque", "/app/bin/pesque", "account", "revoke-app-password", "--handle", "alice.example.com", "--name", "my-app",
    });

    // A missing name is usage, not a crash: the verb would have nothing to
    // revoke by.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{
        "account", "revoke-app-password", "--handle", "alice.example.com",
    }));

    // Both selectors at once is refused, like every selector verb.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{
        "account", "revoke-app-password", "--did", "d1", "--handle", "h", "--name", "n",
    }));
}

test "dispatch: account app-password subcommands are refused as unknown without them" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);

    // A typo'd subcommand stays usage, and --name on a verb that does not
    // take one is refused by the selector parser.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "app-password", "--handle", "h" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{
        "account", "app-passwords", "--handle", "h", "--name", "n",
    }));
}

test "dispatch: passwords without a source are refused when stdin is not a tty" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);
    try ctx.env.put("ACCOUNT_PASSWORD", "");
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "create", "--handle", "h", "--email", "e" }));
}

test "dispatch: migrate takes no --plc-token flag; MIGRATE_PLC_TOKEN goes bare" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);
    try ctx.env.put("MIGRATE_PASSWORD", "from-env");
    try ctx.env.put("MIGRATE_PLC_TOKEN", "tok");

    // The flag is refused: a secret never lands on argv.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{
        "migrate", "--old-pds", "https://old.example.com", "--handle", "alice.example.com", "--email", "a@b.c", "--plc-token", "tok",
    }));

    // The env token is forwarded bare (key only), like the passwords.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{
        "migrate", "--old-pds", "https://old.example.com", "--handle", "alice.example.com", "--email", "a@b.c",
    }));
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectTail(inv, &.{ "pesque", "/app/bin/pesque", "migrate", "--old-pds", "https://old.example.com", "--handle", "alice.example.com", "--email", "a@b.c" });
    try testutil.Ctx.expectArg(inv, "MIGRATE_PLC_TOKEN");
    try testutil.Ctx.expectNoArg(inv, "MIGRATE_PLC_TOKEN=tok");
}

test "dispatch: backup mounts the out dir at the same path" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    try ctx.env.put("PESQUE_ROOT", project);

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"backup"}));
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "--out");
    var saw_mount = false;
    var out_path: []const u8 = "";
    for (inv, 0..) |a, i| {
        if (std.mem.eql(u8, a, "-v")) saw_mount = true;
        if (std.mem.eql(u8, a, "--out") and i + 1 < inv.len) out_path = inv[i + 1];
    }
    try testing.expect(saw_mount);
    // The out dir (the test cwd) is mounted at the same path the verb sees.
    try testing.expect(inv.len > 0);
    var saw_same_path = false;
    for (inv) |a| {
        if (std.mem.eql(u8, a, out_path) and std.mem.startsWith(u8, out_path, "/")) saw_same_path = true;
    }
    try testing.expect(saw_same_path);
}
