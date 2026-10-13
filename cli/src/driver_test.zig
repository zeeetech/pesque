//! Driver argv-construction tests against the fake binaries on the test
//! path. Pins the load-bearing decisions:
//!   - bare `-e KEY` (secrets never in argv, docker),
//!   - the docker one-off's data mount (no `--volumes-from`),
//!   - the docker `run -d` create flags (data/config/publish),
//!   - the systemd one-off as a direct exec of the release binary,
//!   - exit codes: child code propagates, signal -> 1, spawn failure -> 3.
const std = @import("std");
const testing = std.testing;
const proc = @import("proc.zig");
const driver = @import("driver.zig");
const detect = @import("detect.zig");
const systemd = @import("drivers/systemd.zig");
const testutil = @import("testutil.zig");

const secret = "s3cr3t-pw";

test "execStartExe reads the release path from both ExecStart forms" {
    try testing.expectEqualStrings(
        "/nix/store/abc-pesque-1.4.0/bin/pesque",
        systemd.execStartExe("ExecStart={ path=/nix/store/abc-pesque-1.4.0/bin/pesque ; argv[]=/nix/store/abc-pesque-1.4.0/bin/pesque start ; }").?,
    );
    try testing.expectEqualStrings(
        "/opt/pesque/bin/pesque",
        systemd.execStartExe("ExecStart=/opt/pesque/bin/pesque start").?,
    );
    try testing.expect(systemd.execStartExe("nothing useful") == null);
}

test "docker run_once: -i, data mount, bare -e, no --volumes-from" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = try detect.detect(ctx.host, .docker);

    _ = try d.runOnce(ctx.host, .{
        .verb = "account",
        .argv = &.{"list"},
        .env = &.{.{ .key = "MIGRATE_PLC_TOKEN", .value = secret }},
        .interactive = true,
    });

    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "run");
    try testutil.Ctx.expectArg(inv, "--rm");
    try testutil.Ctx.expectArg(inv, "-i");
    try testutil.Ctx.expectNoArg(inv, "-t"); // not a tty
    // The one-off carries the same data the server uses, not --volumes-from,
    // so it also works before the container exists.
    try testutil.Ctx.expectArg(inv, "pesque-data:/data");
    try testutil.Ctx.expectNoArg(inv, "--volumes-from");
    try testutil.Ctx.expectArg(inv, "-e");
    try testutil.Ctx.expectArg(inv, "PDS_SERVE=false");
    try testutil.Ctx.expectArg(inv, "MIGRATE_PLC_TOKEN");
    for (inv) |a| try testing.expect(!std.mem.startsWith(u8, a, "MIGRATE_PLC_TOKEN="));
    try testutil.Ctx.expectTail(inv, &.{ "ghcr.io/zeeetech/pesque:latest", "/app/bin/pesque", "account", "list" });
}

test "docker run_once: -t on a tty" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    proc.Host.stdin_tty_override = true;
    const d = try detect.detect(ctx.host, .docker);
    _ = try d.runOnce(ctx.host, .{ .verb = "migrate", .interactive = true });
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "-t");
}

test "docker run_once: mounts go through -v" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = try detect.detect(ctx.host, .docker);
    _ = try d.runOnce(ctx.host, .{
        .verb = "backup",
        .argv = &.{ "--out", "/somewhere" },
        .mounts = &.{.{ .source = "/somewhere", .target = "/somewhere" }},
    });
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "-v");
    try testutil.Ctx.expectArg(inv, "/somewhere:/somewhere");
}

test "docker up creates the container when it is absent" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("PESQUE_FAKE_NO_CONTAINER", "1");
    const d = try detect.detect(ctx.host, .docker);
    try testing.expectEqual(@as(u8, 0), try d.up(ctx.host));

    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "run");
    try testutil.Ctx.expectArg(inv, "-d");
    try testutil.Ctx.expectArg(inv, "--name");
    try testutil.Ctx.expectArg(inv, "pesque");
    try testutil.Ctx.expectArg(inv, "--restart");
    try testutil.Ctx.expectArg(inv, "unless-stopped");
    try testutil.Ctx.expectArg(inv, "pesque-data:/data");
    try testutil.Ctx.expectArg(inv, "-p");
    try testutil.Ctx.expectArg(inv, "127.0.0.1:4000:4000");
    try testutil.Ctx.expectTail(inv, &.{"ghcr.io/zeeetech/pesque:latest"});
}

test "docker up: PESQUE_DATA / PESQUE_CONFIG / PESQUE_PUBLISH shape the run" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("PESQUE_FAKE_NO_CONTAINER", "1");
    try ctx.env.put("PESQUE_DATA", "/srv/pesque");
    const conf = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "pesque.conf" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = conf, .data = "hostname = pds.example.com\n" });
    try ctx.env.put("PESQUE_CONFIG", conf);
    try ctx.env.put("PESQUE_PUBLISH", "100.64.0.1:4000:4000");
    const d = try detect.detect(ctx.host, .docker);
    _ = try d.up(ctx.host);

    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "/srv/pesque:/data");
    try testutil.Ctx.expectArg(inv, try std.fmt.allocPrint(ctx.arena_state.allocator(), "{s}:/data/pesque.conf:ro", .{conf}));
    try testutil.Ctx.expectArg(inv, "100.64.0.1:4000:4000");
}

test "docker up starts an existing container" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = try detect.detect(ctx.host, .docker);
    try testing.expectEqual(@as(u8, 0), try d.up(ctx.host));
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "start");
    try testutil.Ctx.expectArg(inv, "pesque");
    try testutil.Ctx.expectNoArg(inv, "run");
}

test "docker down stops without removing (data is kept)" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = try detect.detect(ctx.host, .docker);
    _ = try d.down(ctx.host);
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "stop");
    try testutil.Ctx.expectArg(inv, "pesque");
    try testutil.Ctx.expectNoArg(inv, "rm");
    try testutil.Ctx.expectNoArg(inv, "-v");
}

test "docker restart restarts the container" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = try detect.detect(ctx.host, .docker);
    _ = try d.restart(ctx.host);
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "restart");
    try testutil.Ctx.expectArg(inv, "pesque");
}

test "docker update: pull the tag, then rm -f + recreate" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = try detect.detect(ctx.host, .docker);
    try testing.expectEqual(@as(u8, 0), try d.update(ctx.host, "v1.5.0"));

    const invs = try ctx.invocations();
    var saw_pull = false;
    var saw_rm = false;
    var saw_run = false;
    for (invs) |inv| {
        if (inv.len >= 1 and std.mem.eql(u8, inv[0], "pull")) saw_pull = true;
        if (inv.len >= 2 and std.mem.eql(u8, inv[0], "rm") and std.mem.eql(u8, inv[1], "-f")) saw_rm = true;
        if (inv.len >= 1 and std.mem.eql(u8, inv[0], "run")) {
            saw_run = true;
            try testutil.Ctx.expectArg(inv, "ghcr.io/zeeetech/pesque:v1.5.0");
        }
    }
    try testing.expect(saw_pull);
    try testing.expect(saw_rm);
    try testing.expect(saw_run);
}

test "systemd run_once: direct exec of the release with the unit's PDS_* world" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const release = try ctx.makeRelease();
    const d = driver.Driver{ .systemd = .{ .unit = "pesque", .release = release } };

    _ = try d.runOnce(ctx.host, .{
        .verb = "account",
        .argv = &.{"list"},
        .interactive = true,
    });

    const inv = try ctx.lastInvocation();
    // Direct exec: argv[0] is the release binary, no systemd-run wrapper.
    try testutil.Ctx.expectArg(inv, "account");
    try testutil.Ctx.expectArg(inv, "list");
    var saw_bin = false;
    for (inv) |a| {
        if (std.mem.endsWith(u8, a, "/bin/pesque")) saw_bin = true;
    }
    try testing.expect(saw_bin);
    // The unit's PDS_* world reached the child, plus PDS_SERVE=false.
    try testutil.Ctx.expectArg(inv, "PDS_SERVE=false");
    try testutil.Ctx.expectArg(inv, "PDS_HOSTNAME=pds.example.com");
}

test "systemd lifecycle is a no-op; the unit owns the service" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = driver.Driver{ .systemd = .{ .unit = "pesque", .release = "/opt/pesque" } };
    try testing.expectEqual(@as(u8, 0), try d.up(ctx.host));
    try testing.expectEqual(@as(u8, 0), try d.down(ctx.host));
    try testing.expectEqual(@as(u8, 0), try d.restart(ctx.host));
    try testing.expectEqual(@as(u8, 0), try d.update(ctx.host, null));
    try testing.expect(!d.ownsLifecycle());
    try testing.expect(d.interactive());
}

test "docker owns the lifecycle; systemd does not" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const dd = driver.Driver{ .docker = .{ .container = "pesque" } };
    try testing.expect(dd.ownsLifecycle());
    const sd = driver.Driver{ .systemd = .{ .unit = "pesque" } };
    try testing.expect(!sd.ownsLifecycle());
}

test "exit codes: child code propagates, signal maps to 1, spawn failure maps to 3" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = try detect.detect(ctx.host, .docker);

    try ctx.env.put("PESQUE_FAKE_EXIT", "1");
    try testing.expectEqual(@as(u8, 1), try d.runOnce(ctx.host, .{ .verb = "doctor" }));

    try ctx.env.put("PESQUE_FAKE_EXIT", "7");
    try testing.expectEqual(@as(u8, 7), try d.runOnce(ctx.host, .{ .verb = "doctor" }));

    try ctx.env.put("PESQUE_FAKE_SIGNAL", "1");
    try ctx.env.put("PESQUE_FAKE_EXIT", "0");
    try testing.expectEqual(@as(u8, 1), try d.runOnce(ctx.host, .{ .verb = "doctor" }));
    try ctx.env.put("PESQUE_FAKE_SIGNAL", "");

    // Spawn failure maps to the driver/environment failure.
    var broken: proc.Host = ctx.host.*;
    broken.progs.docker = "/nonexistent/docker";
    try testing.expectError(error.DriverFailed, d.runOnce(&broken, .{ .verb = "doctor" }));
}

test "detection: docker when a container exists, systemd otherwise" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    // Explicit flags resolve to the right driver.
    try testing.expectEqual(driver.Kind.docker, (try detect.detect(ctx.host, .docker)).kind());
    try testing.expectEqual(driver.Kind.systemd, (try detect.detect(ctx.host, .systemd)).kind());

    // Auto: PESQUE_BACKEND cleared, a container is found by inspect.
    try ctx.env.put("PESQUE_BACKEND", "");
    const found = try detect.detect(ctx.host, null);
    try testing.expectEqual(driver.Kind.docker, found.kind());
}

test "detection failure: error 3 with a trace" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    // Nothing on this host answers: point every probe at a missing binary.
    try ctx.env.put("PESQUE_BACKEND", "");
    ctx.host.progs.docker = "/nonexistent/docker";
    ctx.host.progs.systemctl = "/nonexistent/systemctl";
    try testing.expectError(error.DriverFailed, detect.detect(ctx.host, null));
}

test "dataDir: docker reads the container's volume; systemd reads the unit env" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const dd = driver.Driver{ .docker = .{ .container = "pesque" } };
    try testing.expectEqualStrings("pesque-data", (try dd.dataDir(ctx.host)).volume);

    try ctx.env.put("PESQUE_FAKE_DATA_DIR", "/srv/pesque");
    const sd = driver.Driver{ .systemd = .{ .unit = "pesque" } };
    const data = try sd.dataDir(ctx.host);
    try testing.expectEqualStrings("/srv/pesque", data.path);
    try testing.expectEqual(driver.Kind.systemd, sd.kind());
}
