//! Dispatch, usage and input-resolution tests (the exit-code surface).
const std = @import("std");
const testing = std.testing;
const main = @import("main.zig");
const testutil = @import("testutil.zig");

const image = "ghcr.io/zeeetech/pesque:latest";

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

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"restart"}));
    const restart_inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(restart_inv, "restart");
    try testutil.Ctx.expectArg(restart_inv, "pesque");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "logs", "-f", "--tail", "100" }));
    const logs_inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(logs_inv, "-f");
    try testutil.Ctx.expectArg(logs_inv, "100");
    try testutil.Ctx.expectArg(logs_inv, "pesque");

    // update v1.5.0 pins the image tag: pull then recreate.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "update", "v1.5.0" }));
    const invs = try ctx.invocations();
    var saw_run = false;
    for (invs) |inv| {
        if (inv.len >= 1 and std.mem.eql(u8, inv[0], "run")) {
            saw_run = true;
            try testutil.Ctx.expectArg(inv, "ghcr.io/zeeetech/pesque:v1.5.0");
        }
    }
    try testing.expect(saw_run);
}

test "dispatch: domain verbs forward to bin/pesque with the verb tail" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"doctor"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "doctor" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"status"}));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "status" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "list" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "list" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "config", "validate" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "config", "validate" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "crawl", "request" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "crawl", "request" });
}

test "dispatch: account create forwards the flags and injects no password" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    // The password is the release's to read (prompt or stdin): the CLI
    // forwards only the flags and never a password env var.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{
        "account", "create", "--handle", "alice.example.com", "--email", "a@b.c",
    }));
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectTail(inv, &.{ image, "/app/bin/pesque", "account", "create", "--handle", "alice.example.com", "--email", "a@b.c" });
    try testutil.Ctx.expectNoArg(inv, "ACCOUNT_PASSWORD");

    // The old flag is gone: naming it is usage, not a silent no-op.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{
        "account", "create", "--handle", "alice.example.com", "--email", "a@b.c", "--password-env", "MY_PW",
    }));

    // Missing --handle and no ACCOUNT_HANDLE: usage refusal.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{
        "account", "create", "--email", "a@b.c",
    }));
}

test "dispatch: account selector verbs need exactly one of --did/--handle" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "delete", "--did", "d1", "--handle", "h" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "takedown" }));
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "takedown", "--handle", "alice.example.com" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "takedown", "--handle", "alice.example.com" });
}

test "dispatch: account plc-token forwards the selector and needs no password" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    // No ACCOUNT_PASSWORD anywhere: plc-token must not ask for one.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "plc-token", "--handle", "alice.example.com" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "plc-token", "--handle", "alice.example.com" });
}

test "dispatch: account email-token and reset-token forward the selector and need no password" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    // No ACCOUNT_PASSWORD anywhere: minting a code must not ask for one.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "email-token", "--handle", "alice.example.com" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "email-token", "--handle", "alice.example.com" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "reset-token", "--did", "did:plc:abc" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "reset-token", "--did", "did:plc:abc" });
}

test "dispatch: account app-passwords forwards the selector and needs no password" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "app-passwords", "--did", "did:web:alice.example.com" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "app-passwords", "--did", "did:web:alice.example.com" });

    // Unknown flags are refused, and a bare selector verb takes no arguments.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "app-passwords", "--handle", "h", "--name", "n" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "app-passwords" }));
}

test "dispatch: account revoke-app-password forwards the selector and requires --name" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{
        "account", "revoke-app-password", "--handle", "alice.example.com", "--name", "my-app",
    }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{
        image, "/app/bin/pesque", "account", "revoke-app-password", "--handle", "alice.example.com", "--name", "my-app",
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

    // A typo'd subcommand stays usage, and --name on a verb that does not
    // take one is refused by the selector parser.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "app-password", "--handle", "h" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{
        "account", "app-passwords", "--handle", "h", "--name", "n",
    }));
}

test "dispatch: delete and reset-password forward without resolving a password" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    // The release reads the password (prompt or stdin); the CLI only
    // forwards the selector and injects no password env.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "delete", "--handle", "h" }));
    var inv = try ctx.lastInvocation();
    try testutil.Ctx.expectTail(inv, &.{ image, "/app/bin/pesque", "account", "delete", "--handle", "h" });
    try testutil.Ctx.expectNoArg(inv, "ACCOUNT_PASSWORD");

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "reset-password", "--did", "did:plc:abc" }));
    inv = try ctx.lastInvocation();
    try testutil.Ctx.expectTail(inv, &.{ image, "/app/bin/pesque", "account", "reset-password", "--did", "did:plc:abc" });
    try testutil.Ctx.expectNoArg(inv, "ACCOUNT_PASSWORD");
}

test "dispatch: migrate takes no --plc-token flag; MIGRATE_PLC_TOKEN goes bare" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
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
    try testutil.Ctx.expectTail(inv, &.{ image, "/app/bin/pesque", "migrate", "--old-pds", "https://old.example.com", "--handle", "alice.example.com", "--email", "a@b.c" });
    try testutil.Ctx.expectArg(inv, "MIGRATE_PLC_TOKEN");
    try testutil.Ctx.expectNoArg(inv, "MIGRATE_PLC_TOKEN=tok");
}

test "dispatch: backup mounts the out dir at the same path" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

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

test "dispatch: lexicon add clones, forwards the checkout and restarts" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{
        "lexicon", "add", "--from", "https://example.com/lexicons.git", "--ref", "main",
    }));

    const invs = try ctx.invocations();
    try testing.expect(invs.len >= 3);

    // 1) the host-side clone: `git clone --depth 1 --branch main -- URL DIR`.
    const clone = invs[0];
    try testutil.Ctx.expectArg(clone, "clone");
    try testutil.Ctx.expectArg(clone, "--branch");
    try testutil.Ctx.expectArg(clone, "main");
    try testutil.Ctx.expectArg(clone, "https://example.com/lexicons.git");

    // 2) the forwarded release verb, carrying the checkout path.
    var forwarded: ?[]const []const u8 = null;
    for (invs) |inv| {
        for (inv) |a| {
            if (std.mem.eql(u8, a, "lexicon")) forwarded = inv;
        }
    }
    try testing.expect(forwarded != null);
    const fwd = forwarded.?;
    try testutil.Ctx.expectArg(fwd, "add");
    try testutil.Ctx.expectArg(fwd, "--from");

    var checkout: []const u8 = "";
    for (fwd, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--from") and i + 1 < fwd.len) checkout = fwd[i + 1];
    }
    try testing.expect(checkout.len > 0);
    try testing.expect(std.fs.path.isAbsolute(checkout));
    try testutil.Ctx.expectArg(fwd, checkout);

    // The checkout is bind-mounted at the same path the verb reads.
    var saw_mount = false;
    for (fwd) |a| {
        if (std.mem.startsWith(u8, a, checkout) and std.mem.indexOfScalar(u8, a, ':') != null) {
            saw_mount = true;
        }
    }
    try testing.expect(saw_mount);

    // 3) the restart, last, so the running server loads what was written.
    try testutil.Ctx.expectArg(try ctx.lastInvocation(), "restart");

    // The host-side checkout the fake `git clone` created is removed when the
    // verb returns, so a temp clone never outlives the command.
    if (std.Io.Dir.cwd().access(testing.io, checkout, .{})) |_| {
        std.debug.print("the temp checkout {s} was not removed\n", .{checkout});
        return error.TestUnexpectedResult;
    } else |_| {}

    // A missing --from is usage, not a crash.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "lexicon", "add" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "lexicon", "remove" }));
}

test "dispatch: --help and --json ride to the release verbatim" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    // The strict per-verb parsers know neither flag: the passthrough lets
    // the release's own parsing answer (per-subcommand usage, read-verb
    // --json) with the frozen exit codes.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "--help" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "--help" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "list", "--json" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "list", "--json" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "status", "--json" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "status", "--json" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "doctor", "-h" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "doctor", "-h" });

    // A verb this CLI has no special parsing for forwards the same way.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "migrate", "--help" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "migrate", "--help" });
}

test "dispatch: account list forwards its flags to the release" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "list", "--status", "active", "--grep", "alice" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "list", "--status", "active", "--grep", "alice" });
}

test "dispatch: account show forwards the selector, and needs exactly one" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "show", "--did", "did:plc:abc" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "show", "--did", "did:plc:abc" });

    // The selector rules hold: none, or both, is usage.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "show" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "show", "--did", "d1", "--handle", "h" }));
}

test "dispatch: account delete forwards --dry-run; the other selector verbs do not take it" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "delete", "--did", "did:plc:abc", "--dry-run" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "delete", "--did", "did:plc:abc", "--dry-run" });

    // Flag order does not matter: the dry run rides with whatever selector
    // the parser picked.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "account", "delete", "--dry-run", "--handle", "h" }));
    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "account", "delete", "--handle", "h", "--dry-run" });

    // Only delete rehearses: reset-password takes no --dry-run.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "account", "reset-password", "--did", "d1", "--dry-run" }));
}

test "dispatch: restore forwards --dry-run with the archive mounted" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    const archive = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "archive.tar.gz" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = archive, .data = "bytes" });

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "restore", "--dry-run", archive }));
    // The cold restore brings the service back up after the run, so the
    // forwarded exec is not the last invocation; find it.
    try testutil.Ctx.expectTail(try forwardedRun(try ctx.invocations()), &.{ image, "/app/bin/pesque", "restore", "--dry-run", archive });

    // Without --dry-run the argv is the archive alone, as before.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "restore", archive }));
    try testutil.Ctx.expectTail(try forwardedRun(try ctx.invocations()), &.{ image, "/app/bin/pesque", "restore", archive });

    // A dry run with no archive, or a second positional, is usage.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "restore", "--dry-run" }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "restore", archive, archive }));
}

test "dispatch: restore --help bypasses the cold-restore lifecycle" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    // Asking for help must not stop the service: the passthrough forwards
    // before the restore handler would bring it down.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "restore", "--help" }));

    for (try ctx.invocations()) |inv| {
        try testutil.Ctx.expectNoArg(inv, "stop");
        try testutil.Ctx.expectNoArg(inv, "start");
    }

    try testutil.Ctx.expectTail(try ctx.lastInvocation(), &.{ image, "/app/bin/pesque", "restore", "--help" });
}

test "dispatch: restore --dry-run never stops or starts the service" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    const archive = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "archive.tar.gz" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = archive, .data = "bytes" });

    // A dry run only reads the archive: no stop, no bring-up, just the
    // forwarded verb.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "restore", archive, "--dry-run" }));
    var invs = try ctx.invocations();
    for (invs) |inv| {
        try testutil.Ctx.expectNoArg(inv, "stop");
        try testutil.Ctx.expectNoArg(inv, "start");
    }
    try testutil.Ctx.expectTail(try forwardedRun(invs), &.{ image, "/app/bin/pesque", "restore", "--dry-run", archive });

    // The same by --archive PATH: the flag only names the archive.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "restore", "--archive", archive, "--dry-run" }));
    invs = try ctx.invocations();
    for (invs) |inv| {
        try testutil.Ctx.expectNoArg(inv, "stop");
        try testutil.Ctx.expectNoArg(inv, "start");
    }
    try testutil.Ctx.expectTail(try forwardedRun(invs), &.{ image, "/app/bin/pesque", "restore", "--dry-run", archive });

    // A plain restore is still cold: it stops the service first and brings
    // it back up after.
    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{ "restore", archive }));
    invs = try ctx.invocations();
    var saw_stop = false;
    var saw_start = false;
    for (invs) |inv| {
        if (anyArg(inv, "stop")) saw_stop = true;
        if (anyArg(inv, "start")) saw_start = true;
    }
    try testing.expect(saw_stop);
    try testing.expect(saw_start);

    // One archive source: --archive with a positional, or --archive twice,
    // is usage, the way the release refuses both of its own forms.
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "restore", "--archive", archive, archive }));
    try testing.expectError(error.Usage, main.run(ctx.host, &.{ "restore", "--archive", archive, "--archive", archive }));
}

/// The invocation that ran the release, whatever driver chatter (an image
/// inspect, a lifecycle stop/start) surrounds it. The last match: a test
/// that runs the verb twice accumulates both runs in one log.
fn forwardedRun(invs: []const []const []const u8) ![]const []const u8 {
    var found: ?[]const []const u8 = null;
    for (invs) |inv| {
        for (inv) |a| {
            if (std.mem.eql(u8, a, "/app/bin/pesque")) {
                found = inv;
                break;
            }
        }
    }
    if (found) |inv| return inv;
    std.debug.print("no forwarded /app/bin/pesque run among the invocations\n", .{});
    return error.TestUnexpectedResult;
}

fn anyArg(inv: []const []const u8, arg: []const u8) bool {
    for (inv) |a| {
        if (std.mem.eql(u8, a, arg)) return true;
    }
    return false;
}

test "backup: without --out the archive lands in the service's data dir" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const release = try ctx.makeRelease();
    try ctx.env.put("PESQUE_BACKEND", "systemd");
    try ctx.env.put("PESQUE_RELEASE", release);
    // A data dir that exists on this host; the shim's default is a real
    // server's path.
    try ctx.env.put("PESQUE_FAKE_DATA_DIR", ctx.tmp_path);

    try testing.expectEqual(@as(u8, 0), try main.run(ctx.host, &.{"backup"}));

    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "backup");
    try testutil.Ctx.expectArg(inv, "--out");
    // Not "." (the operator's cwd): the data directory the service user owns.
    try testutil.Ctx.expectArg(inv, ctx.tmp_path);
}
