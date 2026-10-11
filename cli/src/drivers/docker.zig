//! The docker backend: drives a container you already run. One-offs go
//! through `docker run --volumes-from`, so no compose file and no clone are
//! needed on the server. The lifecycle is foreign: up/down refuse with
//! instructions.
const std = @import("std");
const Io = std.Io;
const proc = @import("../proc.zig");
const driver = @import("../driver.zig");

const Error = proc.Error;

fn mountArg(host: *proc.Host, m: proc.Mount) Error![]const u8 {
    return std.fmt.allocPrint(host.gpa, "{s}:{s}", .{ m.source, m.target }) catch error.OutOfMemory;
}

/// The image the running container was started from, so a one-off matches the
/// code the live server runs.
pub fn image(self: driver.Docker, host: *proc.Host) Error![]const u8 {
    if (self.image.len > 0) return self.image;
    const argv = [_][]const u8{
        host.progs.docker,   "inspect", self.container, "--format",
        "{{.Config.Image}}",
    };
    const cap = host.capture(&argv) catch |e| return e;
    defer host.freeCapture(cap);
    const found = cap.line();
    if (!cap.ok() or found.len == 0) {
        host.err("could not read the image of container '{s}'. Set PESQUE_IMAGE to the image the container runs.", .{self.container});
        return error.DriverFailed;
    }
    return host.gpa.dupe(u8, found) catch error.OutOfMemory;
}

/// Mirror the running container's PDS_* environment into an owner-only temp
/// file for `docker run --env-file`, so the one-off sees the same PDS_* world
/// as the live server. Caller removes the temp dir.
fn writeEnvMirror(self: driver.Docker, host: *proc.Host, tmp_dir: []const u8) Error![]const u8 {
    const g = host.gpa;
    const argv = [_][]const u8{
        host.progs.docker,                           "inspect", self.container, "--format",
        "{{range .Config.Env}}{{println .}}{{end}}",
    };
    const cap = host.capture(&argv) catch |e| return e;
    defer host.freeCapture(cap);
    if (!cap.ok()) {
        host.err("no container named '{s}' is running. Set PESQUE_CONTAINER to the Pesque container's name, or PESQUE_BACKEND=compose if you meant the compose stack.", .{self.container});
        return error.DriverFailed;
    }

    const file_path = std.fs.path.join(g, &.{ tmp_dir, "pds.env" }) catch return error.OutOfMemory;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(g);
    var lines = std.mem.splitScalar(u8, cap.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PDS_")) {
            content.appendSlice(g, line) catch return error.OutOfMemory;
            content.append(g, '\n') catch return error.OutOfMemory;
        }
    }
    Io.Dir.cwd().writeFile(host.io, .{ .sub_path = file_path, .data = content.items }) catch return error.DriverFailed;
    if (@import("builtin").os.tag != .windows) {
        // Best effort: keep the mirrored PDS_* values out of other users' reach.
        Io.Dir.cwd().setFilePermissions(host.io, file_path, .fromMode(0o600), .{}) catch {};
    }
    return file_path;
}

pub fn runOnce(self: driver.Docker, host: *proc.Host, ro: driver.RunOnce) Error!u8 {
    try host.resolveEnv(ro.env);
    const tmp_dir = host.makeTempDir() catch |e| return e;
    defer host.removeTempDir(tmp_dir);
    const env_file = try writeEnvMirror(self, host, tmp_dir);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    const g = host.gpa;
    try argv.appendSlice(g, &.{ host.progs.docker, "run", "--rm", "-i" });
    // `-t` only when the caller is on a terminal.
    if (ro.interactive and host.stdinIsTty()) try argv.append(g, "-t");
    try argv.appendSlice(g, &.{ "--volumes-from", self.container });
    try argv.appendSlice(g, &.{ "--env-file", env_file });
    try argv.appendSlice(g, &.{ "-e", "PDS_SERVE=false" });
    // Secrets travel bare: `-e KEY` with the value in the environment.
    for (ro.env) |e| try argv.appendSlice(g, &.{ "-e", e.key });
    for (ro.mounts) |m| try argv.appendSlice(g, &.{ "-v", try mountArg(host, m) });
    try argv.appendSlice(g, &.{ try image(self, host), "/app/bin/pesque", ro.verb });
    try argv.appendSlice(g, ro.argv);
    return host.run(argv.items);
}

/// Foreign lifecycle: the container is declared in your service manager, not
/// by the CLI. Refuse with the exact instruction.
pub fn refuseLifecycle(host: *proc.Host, action: []const u8, comptime fix_fmt: []const u8, fix_args: anytype) Error!u8 {
    host.err("the docker backend does not own the container lifecycle, so it cannot '{s}' the server.", .{action});
    host.printTo(.stderr, "  " ++ fix_fmt ++ "\n", fix_args);
    host.printTo(.stderr, "  The container is declared in your service manager (or run by hand);\n" ++
        "  start and stop it there, or switch to the compose backend.\n", .{});
    return error.DriverFailed;
}

pub fn restart(self: driver.Docker, host: *proc.Host) Error!u8 {
    host.step("restarting the container", .{});
    const argv = [_][]const u8{ host.progs.docker, "restart", self.container };
    return host.run(&argv);
}

/// `update` for the docker backend: the pull already happened; restarting an
/// existing container keeps the old image, so the operator's recreate command
/// is required.
pub fn restartWithCmd(self: driver.Docker, host: *proc.Host) Error!u8 {
    _ = self;
    const cmd = host.get("PESQUE_RESTART_CMD") orelse "";
    if (cmd.len == 0) {
        host.err("pulled the image, but did not replace the running container.", .{});
        host.printTo(.stderr, "  Restarting an existing container keeps the old image; it has to be recreated.\n" ++
            "  Set PESQUE_RESTART_CMD to the command that does that (split on spaces, no shell), for example:\n\n" ++
            "    PESQUE_RESTART_CMD='systemctl restart pesque' pesque update\n\n" ++
            "  Under NixOS with services.pesque, that is 'systemctl restart pesque'.\n", .{});
        return error.DriverFailed;
    }
    host.step("recreating the container", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |word| try argv.append(host.gpa, host.gpa.dupe(u8, word) catch return error.OutOfMemory);
    return host.run(argv.items);
}

pub fn pull(self: driver.Docker, host: *proc.Host, tag: ?[]const u8) Error!u8 {
    host.step("pulling the image", .{});
    const base_img = try image(self, host);
    const img = if (tag) |t| try tagImage(host, base_img, t) else base_img;
    const argv = [_][]const u8{ host.progs.docker, "pull", img };
    return host.run(&argv);
}

/// `update [tag]`: pull, then hand over to PESQUE_RESTART_CMD (recreating an
/// existing container keeps the old image otherwise).
pub fn update(self: driver.Docker, host: *proc.Host, tag: ?[]const u8) Error!u8 {
    _ = try pull(self, host, tag);
    return restartWithCmd(self, host);
}

/// Swap the tag portion of an image reference (`repo:old` -> `repo:tag`).
fn tagImage(host: *proc.Host, img: []const u8, tag: []const u8) Error![]const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, img, ':')) |i| img[0..i] else img;
    return std.fmt.allocPrint(host.gpa, "{s}:{s}", .{ base, tag }) catch error.OutOfMemory;
}

pub fn logs(self: driver.Docker, host: *proc.Host, opts: driver.LogOpts) Error!u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{ host.progs.docker, "logs" });
    if (opts.follow) try argv.append(host.gpa, "-f");
    if (opts.tail) |n| {
        const n_str = std.fmt.allocPrint(host.gpa, "{d}", .{n}) catch return error.OutOfMemory;
        try argv.appendSlice(host.gpa, &.{ "--tail", n_str });
    }
    try argv.append(host.gpa, self.container);
    return host.run(argv.items);
}

/// `docker inspect` health status for a container (or id). Shared with the
/// compose backend. The image's HEALTHCHECK already probes /xrpc/_health, so
/// container health IS the `_health` check.
pub fn pollStatus(host: *proc.Host, container: []const u8) Error!driver.Poll {
    const argv = [_][]const u8{
        host.progs.docker,                                                              "inspect", container, "--format",
        "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}",
    };
    const cap = host.capture(&argv) catch |e| return e;
    defer host.freeCapture(cap);
    const status = cap.line();
    if (!cap.ok() or status.len == 0) return .down;
    if (std.mem.eql(u8, status, "healthy") or std.mem.eql(u8, status, "running")) return .healthy;
    if (std.mem.eql(u8, status, "starting")) return .starting;
    return .down;
}

pub fn health(self: driver.Docker, host: *proc.Host) Error!driver.Health {
    return healthFromPoll(host, try pollStatus(host, self.container));
}

pub fn healthFromPoll(host: *proc.Host, poll: driver.Poll) Error!driver.Health {
    return switch (poll) {
        .healthy => .healthy,
        .starting => .degraded,
        .down => {
            host.err("the pesque container is not running. Start it with your service manager (the docker backend does not own the lifecycle), or check 'pesque logs'.", .{});
            return error.DriverFailed;
        },
    };
}

pub fn dataDir(self: driver.Docker, host: *proc.Host) Error!driver.DataDir {
    const g = host.gpa;
    const env_argv = [_][]const u8{
        host.progs.docker,                           "inspect", self.container, "--format",
        "{{range .Config.Env}}{{println .}}{{end}}",
    };
    const env_cap = host.capture(&env_argv) catch |e| return e;
    defer host.freeCapture(env_cap);
    if (!env_cap.ok()) {
        host.err("no container named '{s}' is running. Set PESQUE_CONTAINER to the Pesque container's name.", .{self.container});
        return error.DriverFailed;
    }
    var data_dir: []const u8 = "/data";
    var lines = std.mem.splitScalar(u8, env_cap.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "PDS_DATA_DIR=")) {
            data_dir = std.mem.trim(u8, line["PDS_DATA_DIR=".len..], " \r");
        }
    }

    const mounts_argv = [_][]const u8{
        host.progs.docker,                                                      "inspect", self.container, "--format",
        "{{range .Mounts}}{{println .Type .Name .Source .Destination}}{{end}}",
    };
    const cap = host.capture(&mounts_argv) catch |e| return e;
    defer host.freeCapture(cap);
    if (!cap.ok()) {
        host.err("could not read the mounts of container '{s}'.", .{self.container});
        return error.DriverFailed;
    }
    var mlines = std.mem.splitScalar(u8, cap.stdout, '\n');
    while (mlines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \r");
        const kind = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const source = fields.next() orelse continue;
        const destination = fields.next() orelse continue;
        if (!std.mem.eql(u8, destination, data_dir)) continue;
        if (std.mem.eql(u8, kind, "volume")) {
            return .{ .volume = g.dupe(u8, name) catch return error.OutOfMemory };
        }
        return .{ .path = g.dupe(u8, source) catch return error.OutOfMemory };
    }
    host.err("the data directory ({s}) of container '{s}' is not a mount; a one-off would not see the live data.", .{ data_dir, self.container });
    return error.DriverFailed;
}
