//! Driver argv-construction tests against the fake binaries on the test
//! path. Pins the load-bearing decisions (spec §9):
//!   - bare `-e KEY` (secrets never in argv, compose AND docker),
//!   - `--volumes-from` + the PDS_* env mirror on docker,
//!   - `-p User=pesque` on systemd-run,
//!   - `-T` only when stdin is not a tty,
//!   - exit codes: child code propagates, signal -> 1, spawn failure -> 3.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const proc = @import("proc.zig");
const driver = @import("driver.zig");
const detect = @import("detect.zig");
const fetch = @import("fetch.zig");
const testutil = @import("testutil.zig");

const secret = "s3cr3t-pw";

fn composeDriver(ctx: *testutil.Ctx, project_dir: []const u8) driver.Driver {
    _ = ctx;
    return .{ .compose = .{ .project_dir = project_dir } };
}

test "compose run_once: argv arrays, bare -e, -T when not a tty" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    const d = composeDriver(&ctx, project);

    const code = try d.runOnce(ctx.host, .{
        .verb = "account",
        .argv = &.{ "create", "--handle", "alice.example.com" },
        .env = &.{.{ .key = "ACCOUNT_PASSWORD", .value = secret }},
        .interactive = true,
    });
    try testing.expectEqual(@as(u8, 0), code);

    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "run");
    try testutil.Ctx.expectArg(inv, "--rm");
    try testutil.Ctx.expectArg(inv, "--no-deps");
    try testutil.Ctx.expectArg(inv, "-T"); // stdin is not a tty under the test runner
    try testutil.Ctx.expectArg(inv, "-e");
    try testutil.Ctx.expectArg(inv, "PDS_SERVE=false");
    // Bare: only the key, never KEY=VALUE.
    try testutil.Ctx.expectArg(inv, "ACCOUNT_PASSWORD");
    try testutil.Ctx.expectNoArg(inv, "ACCOUNT_PASSWORD=" ++ secret);
    var found_bare = false;
    for (inv, 0..) |a, i| {
        if (std.mem.eql(u8, a, "ACCOUNT_PASSWORD") and i > 0 and std.mem.eql(u8, inv[i - 1], "-e")) {
            found_bare = true;
        }
    }
    try testing.expect(found_bare);
    try testutil.Ctx.expectTail(inv, &.{ "pesque", "/app/bin/pesque", "account", "create", "--handle", "alice.example.com" });
}

test "compose run_once: no -T on a tty" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    proc.Host.stdin_tty_override = true;
    const project = try testutil.makeProjectDir(&ctx, "install");
    const d = composeDriver(&ctx, project);
    _ = try d.runOnce(ctx.host, .{ .verb = "doctor", .interactive = true });
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectNoArg(inv, "-T");
}

test "compose run_once: mounts go through -v" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    const d = composeDriver(&ctx, project);
    _ = try d.runOnce(ctx.host, .{
        .verb = "backup",
        .argv = &.{ "--out", "/somewhere" },
        .mounts = &.{.{ .source = "/somewhere", .target = "/somewhere" }},
    });
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "-v");
    try testutil.Ctx.expectArg(inv, "/somewhere:/somewhere");
}

test "docker run_once: -i, --volumes-from, env mirror, bare -e" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("PESQUE_BACKEND", "docker");
    const d = try detect.detect(ctx.host, .docker);

    _ = try d.runOnce(ctx.host, .{
        .verb = "account",
        .argv = &.{"list"},
        .env = &.{.{ .key = "ACCOUNT_PASSWORD", .value = secret }},
        .interactive = true,
    });

    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "run");
    try testutil.Ctx.expectArg(inv, "--rm");
    try testutil.Ctx.expectArg(inv, "-i");
    try testutil.Ctx.expectNoArg(inv, "-t"); // not a tty
    try testutil.Ctx.expectArg(inv, "--volumes-from");
    try testutil.Ctx.expectArg(inv, "pesque");
    try testutil.Ctx.expectArg(inv, "--env-file");
    try testutil.Ctx.expectArg(inv, "-e");
    try testutil.Ctx.expectArg(inv, "PDS_SERVE=false");
    try testutil.Ctx.expectArg(inv, "ACCOUNT_PASSWORD");
    // The env mirror crossed the boundary: PDS_* from the running container.
    var saw_mirror = false;
    for (inv) |a| {
        if (std.mem.eql(u8, a, "ENVFILE:PDS_HOSTNAME=pds.example.com")) saw_mirror = true;
        try testing.expect(!std.mem.startsWith(u8, a, "ACCOUNT_PASSWORD="));
    }
    try testing.expect(saw_mirror);
    try testutil.Ctx.expectTail(inv, &.{ "ghcr.io/zeeetech/pesque:latest", "/app/bin/pesque", "account", "list" });
}

test "docker run_once: -t on a tty" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("PESQUE_BACKEND", "docker");
    proc.Host.stdin_tty_override = true;
    const d = try detect.detect(ctx.host, .docker);
    _ = try d.runOnce(ctx.host, .{ .verb = "migrate", .interactive = true });
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "-t");
}

test "systemd run_once as root: -p User=pesque, bare -E, env mirror" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    proc.Host.root_override = true;
    const d = driver.Driver{ .systemd = .{ .unit = "pesque" } };

    _ = try d.runOnce(ctx.host, .{
        .verb = "account",
        .argv = &.{"list"},
        .env = &.{.{ .key = "ACCOUNT_PASSWORD", .value = secret }},
        .interactive = true,
    });

    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "--pipe");
    try testutil.Ctx.expectArg(inv, "--wait");
    try testutil.Ctx.expectArg(inv, "--collect");
    try testutil.Ctx.expectArg(inv, "-p");
    try testutil.Ctx.expectArg(inv, "User=pesque");
    try testutil.Ctx.expectArg(inv, "-p");
    try testutil.Ctx.expectArg(inv, "Group=pesque");
    try testutil.Ctx.expectArg(inv, "-E");
    try testutil.Ctx.expectArg(inv, "ACCOUNT_PASSWORD");
    var saw_mirror = false;
    for (inv) |a| {
        if (std.mem.eql(u8, a, "ENVFILE:PDS_DATA_DIR=/var/lib/pesque")) saw_mirror = true;
        if (std.mem.eql(u8, a, "ENVFILE:PDS_SERVE=false")) saw_mirror = saw_mirror;
        try testing.expect(!std.mem.startsWith(u8, a, "ACCOUNT_PASSWORD="));
    }
    try testing.expect(saw_mirror);
    try testutil.Ctx.expectTail(inv, &.{ "/opt/pesque/bin/pesque", "account", "list" });
}

test "systemd run_once as non-root: direct exec of the release" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    proc.Host.root_override = false;
    const release = try ctx.makeRelease();
    const d = driver.Driver{ .systemd = .{ .unit = "pesque", .release = release } };

    _ = try d.runOnce(ctx.host, .{ .verb = "doctor", .interactive = true });

    const inv = try ctx.lastInvocation();
    // Direct exec: argv[0] is the release binary, no systemd-run wrapper.
    try testutil.Ctx.expectArg(inv, "doctor");
    var saw_bin = false;
    for (inv) |a| {
        if (std.mem.endsWith(u8, a, "/bin/pesque")) saw_bin = true;
    }
    try testing.expect(saw_bin);
    // The unit's PDS_* world reached the child, plus PDS_SERVE=false.
    try testutil.Ctx.expectArg(inv, "PDS_SERVE=false");
    try testutil.Ctx.expectArg(inv, "PDS_HOSTNAME=pds.example.com");
}

test "nixos run_once reuses the systemd machinery with PESQUE_RELEASE" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    proc.Host.root_override = true;
    const release = try ctx.makeRelease();
    const d = driver.Driver{ .nixos = .{ .unit = "pesque", .release = release } };

    _ = try d.runOnce(ctx.host, .{ .verb = "doctor", .interactive = true });
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "-p");
    try testutil.Ctx.expectArg(inv, "User=pesque");
    try testutil.Ctx.expectTail(inv, &.{ try std.fs.path.join(ctx.arena_state.allocator(), &.{ release, "bin/pesque" }), "doctor" });
}

test "exit codes: child code propagates, signal maps to 1, spawn failure maps to 3" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    const d = composeDriver(&ctx, project);

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

test "docker backend refuses up and down with instructions" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = driver.Driver{ .docker = .{ .container = "pesque" } };
    try testing.expectError(error.DriverFailed, d.up(ctx.host));
    try testing.expectError(error.DriverFailed, d.down(ctx.host));
    try testing.expect(!d.ownsLifecycle());
    try testing.expect(d.interactive());
}

test "nixos up/down/update are no-ops with a message" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const d = driver.Driver{ .nixos = .{ .unit = "pesque", .release = "/opt/pesque" } };
    try testing.expectEqual(@as(u8, 0), try d.up(ctx.host));
    try testing.expectEqual(@as(u8, 0), try d.down(ctx.host));
    try testing.expectEqual(@as(u8, 0), try d.pull(ctx.host, null));
    try testing.expect(!d.ownsLifecycle());
}

test "down never passes -v (data is kept)" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const project = try testutil.makeProjectDir(&ctx, "install");
    const d = composeDriver(&ctx, project);
    _ = try d.down(ctx.host);
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "down");
    try testutil.Ctx.expectNoArg(inv, "-v");
    // The compose file list is pinned too.
    var saw_main = false;
    for (inv) |a| {
        if (std.mem.endsWith(u8, a, "/docker-compose.yml")) saw_main = true;
        try testing.expect(!std.mem.endsWith(u8, a, "-v"));
    }
    try testing.expect(saw_main);
}

test "detection: compose file wins, then docker, then systemd" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    // compose: a docker-compose.yml above/beside the cwd.
    const project = try testutil.makeProjectDir(&ctx, "install");
    const sub = try std.fs.path.join(ctx.arena_state.allocator(), &.{ project, "sub" });
    try Io.Dir.cwd().createDirPath(testing.io, sub);
    var orig: [Io.Dir.max_path_bytes]u8 = undefined;
    const orig_len = try Io.Dir.cwd().realPath(ctx.host.io, &orig);
    defer std.process.setCurrentPath(ctx.host.io, orig[0..orig_len]) catch {};
    try std.process.setCurrentPath(ctx.host.io, sub);
    try ctx.env.put("PESQUE_BACKEND", ""); // clear the override: exercise the search
    const found = try detect.detect(ctx.host, null);
    try testing.expectEqual(driver.Kind.compose, found.kind());
    try std.process.setCurrentPath(ctx.host.io, orig[0..orig_len]);

    // docker: explicit backend resolves to the docker driver.
    try ctx.env.put("PESQUE_BACKEND", "docker");
    const as_docker = try detect.detect(ctx.host, null);
    try testing.expectEqual(driver.Kind.docker, as_docker.kind());

    // systemd: PESQUE_SERVICE points the unit check at the shim.
    try ctx.env.put("PESQUE_BACKEND", "systemd");
    const as_systemd = try detect.detect(ctx.host, null);
    try testing.expectEqual(driver.Kind.systemd, as_systemd.kind());
}

test "detection failure: error 3 with a trace" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    // Nothing on this host answers: point every probe at a missing binary.
    ctx.host.progs.docker = "/nonexistent/docker";
    ctx.host.progs.systemctl = "/nonexistent/systemctl";
    try ctx.env.put("PESQUE_ROOT", try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "nope" }));
    try testing.expectError(error.DriverFailed, detect.detect(ctx.host, null));
}

test "docker dataDir reads the container's volume; systemd reads the unit env" {
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

// --- fetch -------------------------------------------------------------------

test "fetch: sha256 verify passes on a matching download and fails on a mismatch" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    // The tarball's body is one curl call; the sums file's body is another.
    const tarball_body = "hello pesque\n";
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(tarball_body);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    var hex_buf: [64]u8 = undefined;
    const hex = try std.fmt.bufPrint(&hex_buf, "{x}", .{digest});

    const tmp_file = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "tarball" });
    try ctx.env.put("PESQUE_FAKE_CURL_BODY", tarball_body);
    try fetch.downloadTo(ctx.host, "https://example.invalid/pesque-server-x86_64-linux.tar.gz", tmp_file);

    const sums_body = try std.fmt.allocPrint(ctx.arena_state.allocator(), "{s}  pesque-server-x86_64-linux.tar.gz\nbeef  other-asset\n", .{hex});
    const sums_file = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "sums" });
    try ctx.env.put("PESQUE_FAKE_CURL_BODY", sums_body);
    try fetch.downloadTo(ctx.host, "https://example.invalid/SHA256SUMS", sums_file);

    try fetch.verifySums(ctx.host, sums_file, "pesque-server-x86_64-linux.tar.gz", tmp_file);

    try ctx.env.put("PESQUE_FAKE_CURL_BODY", "0deadbeef  pesque-server-x86_64-linux.tar.gz");
    try fetch.downloadTo(ctx.host, "https://example.invalid/SHA256SUMS", sums_file);
    try testing.expectError(error.DriverFailed, fetch.verifySums(ctx.host, sums_file, "pesque-server-x86_64-linux.tar.gz", tmp_file));
}

test "fetch: latest tag parses from the GitHub API body" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("PESQUE_FAKE_CURL_BODY", "{\"tag_name\":\"v1.4.0\",\"other\":1}");
    try testing.expectEqualStrings("v1.4.0", try fetch.latestTag(ctx.host));
}

test "fetch: download argv pins curl -fsSL --max-time 30" {
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();
    const dest = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "x" });
    try fetch.downloadTo(ctx.host, "https://example.invalid/x", dest);
    const inv = try ctx.lastInvocation();
    try testutil.Ctx.expectArg(inv, "-fsSL");
    try testutil.Ctx.expectArg(inv, "--max-time");
    try testutil.Ctx.expectArg(inv, "30");
    try testutil.Ctx.expectArg(inv, "-o");
    try testutil.Ctx.expectArg(inv, dest);
}

test "fetch: unpackTarGz extracts a gzipped tar with exec bits" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var ctx = try testutil.Ctx.init();
    defer ctx.deinit();

    // A tiny tar.gz fixture built by the real tar(1). The extract target is a
    // fresh dir: the extractor refuses to overwrite existing files.
    const fixture_dir = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "pull-fixture/pesque/bin" });
    try Io.Dir.cwd().createDirPath(testing.io, fixture_dir);
    const payload = try std.fs.path.join(ctx.arena_state.allocator(), &.{ fixture_dir, "pesque" });
    try Io.Dir.cwd().writeFile(ctx.host.io, .{ .sub_path = payload, .data = "#!/bin/sh\necho hi\n" });
    // Give the fixture an exec bit so the tarball carries one.
    try Io.Dir.cwd().setFilePermissions(ctx.host.io, payload, .fromMode(0o755), .{});
    const tarball = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "fixture.tar.gz" });
    {
        const res = try std.process.run(testing.allocator, testing.io, .{
            .argv = &.{
                "/bin/sh", "-c",    "tar -czf \"$1\" -C \"$2\" pull-fixture",
                "tar",     tarball, ctx.tmp_path,
            },
        });
        defer testing.allocator.free(res.stdout);
        defer testing.allocator.free(res.stderr);
        try testing.expect(res.term == .exited and res.term.exited == 0);
    }
    const extract_target = try std.fs.path.join(ctx.arena_state.allocator(), &.{ ctx.tmp_path, "extracted" });
    try Io.Dir.cwd().createDirPath(testing.io, extract_target);
    // The real release tarball has one top-level directory; strip it, like the
    // systemd driver does, so `bin/` lands directly in the target.
    _ = try fetch.unpackTarGz(ctx.host, tarball, try Io.Dir.cwd().openDir(ctx.host.io, extract_target, .{}), 1);
    const extracted = try std.fs.path.join(ctx.arena_state.allocator(), &.{ extract_target, "pesque/bin/pesque" });
    const st = try Io.Dir.cwd().statFile(ctx.host.io, extracted, .{});
    try testing.expect(st.size > 0);
    try testing.expect(st.permissions.toMode() & 0o111 != 0);
}
