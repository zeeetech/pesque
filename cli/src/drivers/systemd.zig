//! The systemd backend: the unit owns the service (a NixOS module or a tarball
//! install), so up/down/restart/update are no-ops that point at the service
//! manager. One-off domain verbs run the release binary directly as the
//! invoking user (the service user), with the unit's PDS_* world merged into
//! the child.
const std = @import("std");
const Io = std.Io;
const proc = @import("../proc.zig");
const driver = @import("../driver.zig");

const Error = proc.Error;

// --- unit environment: PDS_* comes from the unit's Environment --------------

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
    // `EnvironmentFiles=/etc/pesque/pesque.env (ignore=no)`, possibly several.
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

/// The release directory the unit runs, from its ExecStart: a store path on
/// NixOS, /opt/pesque on a tarball install. Null when it cannot be read.
pub fn releaseFromUnit(host: *proc.Host, unit: []const u8) ?[]const u8 {
    const argv = [_][]const u8{ host.progs.systemctl, "show", unit, "-p", "ExecStart" };
    const cap = host.capture(&argv) catch return null;
    defer host.freeCapture(cap);
    if (!cap.ok()) return null;
    const exe = execStartExe(cap.stdout) orelse return null;
    const bin_dir = std.fs.path.dirname(exe) orelse return null;
    const release = std.fs.path.dirname(bin_dir) orelse return null;
    return host.gpa.dupe(u8, release) catch null;
}

/// The executable out of `ExecStart={ path=<exe> ; argv[]=<exe> ... }`, or the
/// first token of a plain `ExecStart=<exe> <args>`.
pub fn execStartExe(output: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, output, "path=")) |i| {
        const rest = output[i + "path=".len ..];
        const end = std.mem.indexOfAny(u8, rest, " ;") orelse rest.len;
        if (end > 0) return rest[0..end];
    }
    if (std.mem.indexOf(u8, output, "ExecStart=")) |i| {
        const rest = output[i + "ExecStart=".len ..];
        const end = std.mem.indexOfAny(u8, rest, " \r\n") orelse rest.len;
        if (end > 0) return rest[0..end];
    }
    return null;
}

/// `data_dir` from the conf the unit points PDS_CONFIG at. The NixOS module
/// writes it there rather than into the unit environment.
fn confDataDir(host: *proc.Host, path: []const u8) ?[]const u8 {
    const content = Io.Dir.cwd().readFileAlloc(host.io, path, host.gpa, .limited(1 << 20)) catch return null;
    defer host.gpa.free(content);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "data_dir")) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (value.len == 0) return null;
        return host.gpa.dupe(u8, value) catch null;
    }
    return null;
}

// --- run_once ---------------------------------------------------------------

/// Run a one-off by exec'ing the release binary directly. The unit's PDS_* world
/// is merged into the child environment, so the verb reads the same config and
/// data the service does. Run the CLI as the service user (`sudo -u pesque`)
/// so the verb can write the data directory.
pub fn runOnce(self: driver.Systemd, host: *proc.Host, ro: driver.RunOnce) Error!u8 {
    try host.resolveEnv(ro.env);

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

// --- lifecycle (the unit owns it) -------------------------------------------

/// The unit owns start/stop/restart, so the CLI only points at systemctl.
pub fn noopLifecycle(self: driver.Systemd, host: *proc.Host, action: []const u8) Error!u8 {
    const verb = if (std.mem.eql(u8, action, "up"))
        "start"
    else if (std.mem.eql(u8, action, "down"))
        "stop"
    else
        "restart";
    host.note("the systemd unit '{s}' owns the service, so '{s}' is a no-op here.", .{ self.unit, action });
    host.out("  run 'systemctl {s} {s}' (on NixOS, manage it through your configuration).", .{ verb, self.unit });
    return 0;
}

/// The release is managed outside the CLI: replace it and restart, or rebuild.
pub fn noopUpdate(self: driver.Systemd, host: *proc.Host) Error!u8 {
    _ = self;
    host.note("nothing to update: the release is managed outside this CLI.", .{});
    host.out("  replace the release and restart the unit, or on NixOS run 'nixos-rebuild switch'.", .{});
    return 0;
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
    if (pairs.get("PDS_DATA_DIR")) |dir| {
        return .{ .path = host.gpa.dupe(u8, dir) catch return error.OutOfMemory };
    }
    if (pairs.get("PDS_CONFIG")) |conf| {
        if (confDataDir(host, conf)) |dir| return .{ .path = dir };
    }
    return .{ .path = "/var/lib/pesque" };
}
