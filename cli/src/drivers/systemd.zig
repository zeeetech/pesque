//! The systemd backend: drives the `pesque` unit over systemctl. One-off
//! domain verbs run as the `pesque` user via `systemd-run --pipe --wait
//! --collect` when the CLI runs as root (D6), or as a direct exec of the
//! release otherwise. The NixOS driver reuses everything here with its own
//! release path (spec §2: "same via ${PESQUE_RELEASE}").
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const proc = @import("../proc.zig");
const driver = @import("../driver.zig");
const fetch = @import("../fetch.zig");

const Error = proc.Error;

fn isRoot() bool {
    if (proc.Host.root_override) |r| return r;
    return switch (builtin.os.tag) {
        .linux => std.os.linux.geteuid() == 0,
        else => false,
    };
}

// --- unit environment (spec §5: PDS_* comes from the unit's Environment) ----

/// The unit's PDS_* environment: the inline `Environment=` directive plus any
/// `EnvironmentFile`s the unit declares (the directive wins). Only PDS_* keys
/// are kept.
fn unitEnv(self: driver.Systemd, host: *proc.Host, map: *std.StringHashMap([]const u8)) Error!void {
    const env_argv = [_][]const u8{ host.progs.systemctl, "show", self.unit, "-p", "Environment" };
    const env_cap = host.capture(&env_argv) catch |e| return e;
    defer host.freeCapture(env_cap);
    if (env_cap.ok()) parseEnvironmentLine(host, std.mem.trim(u8, env_cap.stdout, " \r\n"), map);

    const files_argv = [_][]const u8{ host.progs.systemctl, "show", self.unit, "-p", "EnvironmentFiles" };
    const files_cap = host.capture(&files_argv) catch |e| return e;
    defer host.freeCapture(files_cap);
    if (!files_cap.ok()) return;
    // `EnvironmentFiles=/etc/pesque/pesque.env (ignore=no)` — possibly several.
    var it = std.mem.splitScalar(u8, files_cap.stdout, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\n");
        if (!std.mem.startsWith(u8, line, "EnvironmentFiles=")) continue;
        var rest = line["EnvironmentFiles=".len..];
        while (std.mem.indexOfScalar(u8, rest, '/')) |path_start| {
            const path_end = std.mem.indexOfScalarPos(u8, rest, path_start, ' ') orelse rest.len;
            const path = rest[path_start..path_end];
            rest = rest[path_end..];
            mergeEnvFile(host, path, map) catch continue;
        }
    }
}

/// Parse `Environment=KEY=VALUE KEY2="quoted value"` into the map (PDS_* only).
fn parseEnvironmentLine(host: *proc.Host, line: []const u8, map: *std.StringHashMap([]const u8)) void {
    const g = host.gpa;
    var rest = line;
    if (std.mem.startsWith(u8, rest, "Environment=")) rest = rest["Environment=".len..];
    var it = std.mem.tokenizeAny(u8, rest, " ");
    while (it.next()) |token_raw| {
        const token = std.mem.trim(u8, token_raw, "\"");
        if (!std.mem.startsWith(u8, token, "PDS_")) continue;
        const eq = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        const key = g.dupe(u8, token[0..eq]) catch continue;
        const value = g.dupe(u8, token[eq + 1 ..]) catch continue;
        if (!map.contains(key)) map.put(key, value) catch {};
    }
}

/// Read KEY=VALUE lines from an env file (PDS_* only, directive wins).
fn mergeEnvFile(host: *proc.Host, path: []const u8, map: *std.StringHashMap([]const u8)) !void {
    const g = host.gpa;
    const content = Io.Dir.cwd().readFileAlloc(host.io, path, g, .limited(1 << 20)) catch return;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "PDS_")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = g.dupe(u8, line[0..eq]) catch continue;
        const value = g.dupe(u8, std.mem.trim(u8, line[eq + 1 ..], "\" ")) catch continue;
        if (!map.contains(key)) map.put(key, value) catch {};
    }
}

fn unitValue(map: *std.StringHashMap([]const u8), key: []const u8, default: []const u8) []const u8 {
    return map.get(key) orelse default;
}

// --- run_once ---------------------------------------------------------------

pub fn runOnce(self: driver.Systemd, host: *proc.Host, ro: driver.RunOnce) Error!u8 {
    try host.resolveEnv(ro.env);
    if (isRoot()) {
        return systemdRun(self, host, ro);
    }
    return directExec(self, host, ro);
}

/// euid 0: a transient unit as the `pesque` user. The unit's PDS_* world is
/// mirrored into a root-only EnvironmentFile (nothing secret on the command
/// line); verb inputs go in as bare `-E KEY`, values inherited from this
/// process's environment (kept out of `ps`).
fn systemdRun(self: driver.Systemd, host: *proc.Host, ro: driver.RunOnce) Error!u8 {
    const g = host.gpa;
    const tmp_dir = host.makeTempDir() catch |e| return e;
    defer host.removeTempDir(tmp_dir);

    var pairs: std.StringHashMap([]const u8) = .init(g);
    defer pairs.deinit();
    try unitEnv(self, host, &pairs);
    pairs.put("PDS_SERVE", "false") catch {};

    // The manager (root) reads this file for the transient unit.
    const env_file = std.fs.path.join(g, &.{ tmp_dir, "unit.env" }) catch return error.OutOfMemory;
    {
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(g);
        var it = pairs.iterator();
        while (it.next()) |entry| {
            content.appendSlice(g, entry.key_ptr.*) catch return error.OutOfMemory;
            content.append(g, '=') catch return error.OutOfMemory;
            content.appendSlice(g, entry.value_ptr.*) catch return error.OutOfMemory;
            content.append(g, '\n') catch return error.OutOfMemory;
        }
        Io.Dir.cwd().writeFile(host.io, .{ .sub_path = env_file, .data = content.items }) catch return error.DriverFailed;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(g);
    const env_file_flag = std.fmt.allocPrint(g, "EnvironmentFile={s}", .{env_file}) catch return error.OutOfMemory;
    try argv.appendSlice(g, &.{
        host.progs.systemd_run, "--pipe",      "--wait", "--collect",
        "-p",                   "User=pesque", "-p",     "Group=pesque",
        "-p",                   env_file_flag,
    });
    for (ro.env) |e| {
        // Bare: systemd-run takes the value from its own environment (added
        // in systemd v211), so it never appears in `ps`.
        try argv.appendSlice(g, &.{ "-E", e.key });
    }
    const release_bin = std.fs.path.join(g, &.{ self.release, "bin", "pesque" }) catch return error.OutOfMemory;
    try argv.append(g, release_bin);
    try argv.append(g, ro.verb);
    try argv.appendSlice(g, ro.argv);
    return host.run(argv.items);
}

/// Not root: exec the release binary directly with the unit's PDS_* world
/// merged into the child environment.
fn directExec(self: driver.Systemd, host: *proc.Host, ro: driver.RunOnce) Error!u8 {
    const g = host.gpa;
    var pairs: std.StringHashMap([]const u8) = .init(g);
    defer pairs.deinit();
    try unitEnv(self, host, &pairs);

    // Child env = this process's env + unit PDS_* + PDS_SERVE=false.
    const held = g.create(std.process.Environ.Map) catch return error.OutOfMemory;
    held.* = std.process.Environ.Map.init(g);
    held.putAll(host.environ) catch return error.OutOfMemory;
    var it = pairs.iterator();
    while (it.next()) |entry| held.put(entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
    held.put("PDS_SERVE", "false") catch return error.OutOfMemory;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(g);
    const release_bin = std.fs.path.join(g, &.{ self.release, "bin", "pesque" }) catch return error.OutOfMemory;
    try argv.append(g, release_bin);
    try argv.append(g, ro.verb);
    try argv.appendSlice(g, ro.argv);

    const saved_map = host.environ;
    host.environ = held;
    defer host.environ = saved_map;
    return host.run(argv.items);
}

// --- lifecycle --------------------------------------------------------------

pub fn start(self: driver.Systemd, host: *proc.Host) Error!u8 {
    host.step("starting the service", .{});
    const argv = [_][]const u8{ host.progs.systemctl, "start", self.unit };
    return host.run(&argv);
}

pub fn stop(self: driver.Systemd, host: *proc.Host) Error!u8 {
    host.step("stopping the service (data is kept)", .{});
    const argv = [_][]const u8{ host.progs.systemctl, "stop", self.unit };
    return host.run(&argv);
}

pub fn restart(self: driver.Systemd, host: *proc.Host) Error!u8 {
    host.step("restarting the service", .{});
    const argv = [_][]const u8{ host.progs.systemctl, "restart", self.unit };
    return host.run(&argv);
}

pub fn logs(self: driver.Systemd, host: *proc.Host, opts: driver.LogOpts) Error!u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{ host.progs.journalctl, "-u", self.unit });
    if (opts.follow) try argv.append(host.gpa, "-f");
    if (opts.tail) |n| {
        const n_str = std.fmt.allocPrint(host.gpa, "{d}", .{n}) catch return error.OutOfMemory;
        try argv.appendSlice(host.gpa, &.{ "-n", n_str });
    }
    return host.run(argv.items);
}

pub fn pollStatus(self: driver.Systemd, host: *proc.Host) Error!driver.Poll {
    const argv = [_][]const u8{ host.progs.systemctl, "is-active", self.unit };
    const cap = host.capture(&argv) catch |e| return e;
    defer host.freeCapture(cap);
    if (!cap.ok() or !std.mem.eql(u8, cap.line(), "active")) return .down;
    // The `_health` endpoint from the host; degraded when it does not answer
    // (the unit does not have to publish the port for the service to work).
    var pairs: std.StringHashMap([]const u8) = .init(host.gpa);
    defer pairs.deinit();
    try unitEnv(self, host, &pairs);
    const port = unitValue(&pairs, "PDS_PORT", "4000");
    const url = std.fmt.allocPrint(host.gpa, "http://localhost:{s}/xrpc/_health", .{port}) catch return error.OutOfMemory;
    const curl_argv = [_][]const u8{ host.progs.curl, "-fsS", "--max-time", "5", url };
    const http = host.capture(&curl_argv) catch |e| return e;
    defer host.freeCapture(http);
    return if (http.ok()) .healthy else .starting; // starting maps to degraded
}

pub fn health(self: driver.Systemd, host: *proc.Host) Error!driver.Health {
    const poll = try pollStatus(self, host);
    return switch (poll) {
        .healthy => .healthy,
        .starting => {
            var pairs: std.StringHashMap([]const u8) = .init(host.gpa);
            defer pairs.deinit();
            try unitEnv(self, host, &pairs);
            host.note("the service is active but the _health endpoint did not answer on port {s}.", .{unitValue(&pairs, "PDS_PORT", "4000")});
            return .degraded;
        },
        .down => {
            host.err("the '{s}' service is not active. Check 'pesque logs' or 'systemctl status {s}'.", .{ self.unit, self.unit });
            return error.DriverFailed;
        },
    };
}

pub fn dataDir(self: driver.Systemd, host: *proc.Host) Error!driver.DataDir {
    var pairs: std.StringHashMap([]const u8) = .init(host.gpa);
    defer pairs.deinit();
    try unitEnv(self, host, &pairs);
    return .{ .path = host.gpa.dupe(u8, unitValue(&pairs, "PDS_DATA_DIR", "/var/lib/pesque")) catch return error.OutOfMemory };
}

// --- pull: download the release tarball and swap the /opt/pesque symlink ----

pub fn pull(self: driver.Systemd, host: *proc.Host, tag: ?[]const u8) Error!u8 {
    switch (builtin.target.cpu.arch) {
        .x86_64 => {},
        else => {
            host.err("the release tarball is published for x86_64 only; on this architecture use the flake (NixOS) or the docker backend.", .{});
            return error.DriverFailed;
        },
    }
    const version = tag orelse try fetch.latestTag(host);
    const asset = "pesque-server-x86_64-linux.tar.gz";

    host.step("downloading the release ({s})", .{version});
    const tmp_dir = host.makeTempDir() catch |e| return e;
    defer host.removeTempDir(tmp_dir);

    const g = host.gpa;
    const tarball = std.fs.path.join(g, &.{ tmp_dir, asset }) catch return error.OutOfMemory;
    const sums = std.fs.path.join(g, &.{ tmp_dir, "SHA256SUMS" }) catch return error.OutOfMemory;
    const base_url = std.fmt.allocPrint(g, "https://github.com/{s}/releases/download/{s}", .{ fetch.releaseRepo(host), version }) catch return error.OutOfMemory;
    try fetch.downloadTo(host, std.fmt.allocPrint(g, "{s}/{s}", .{ base_url, asset }) catch return error.OutOfMemory, tarball);
    try fetch.downloadTo(host, std.fmt.allocPrint(g, "{s}/SHA256SUMS", .{base_url}) catch return error.OutOfMemory, sums);
    try fetch.verifySums(host, sums, asset, tarball);

    host.step("unpacking to {s}-{s}", .{ self.release, version });
    const unpack_dir = std.fmt.allocPrint(g, "{s}-{s}", .{ self.release, version }) catch return error.OutOfMemory;
    Io.Dir.cwd().createDirPath(host.io, unpack_dir) catch |e| switch (e) {
        error.AccessDenied => {
            host.err("cannot write to /opt (permission denied). Re-run with sudo.", .{});
            return error.DriverFailed;
        },
        else => {
            host.err("cannot create {s}: {s}.", .{ unpack_dir, @errorName(e) });
            return error.DriverFailed;
        },
    };
    var out_dir = Io.Dir.cwd().openDir(host.io, unpack_dir, .{}) catch return error.DriverFailed;
    defer out_dir.close(host.io);
    try fetch.unpackTarGz(host, tarball, out_dir);

    // Atomically swap the symlink. A crash mid-swap leaves /opt/pesque.old
    // (same rollback story the restore verb has).
    const target = std.fs.path.basename(unpack_dir);
    if (currentSymlink(host, "/opt/pesque")) |current| {
        if (std.mem.eql(u8, current, target)) {
            host.note("/opt/pesque already points at {s}; nothing to swap.", .{target});
            return 0;
        }
    }
    host.step("swapping /opt/pesque -> {s}", .{target});
    Io.Dir.cwd().symLinkAtomic(host.io, target, "/opt/pesque", .{ .is_directory = true }) catch {
        host.err("could not swap the /opt/pesque symlink. Do it by hand:\n  ln -sfn {s} /opt/pesque", .{target});
        return error.DriverFailed;
    };
    host.note("the previous release stays in /opt; remove old ones once the new version is healthy.", .{});
    return 0;
}

fn currentSymlink(host: *proc.Host, path: []const u8) ?[]const u8 {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = Io.Dir.cwd().readLink(host.io, path, &buf) catch return null;
    return host.gpa.dupe(u8, buf[0..n]) catch null;
}

/// `update [tag]`: download + swap the release, then restart the unit so the
/// new release is live.
pub fn update(self: driver.Systemd, host: *proc.Host, tag: ?[]const u8) Error!u8 {
    _ = try pull(self, host, tag);
    return restart(self, host);
}
