//! The docker backend: one container the CLI creates and owns. `up` creates
//! the container if it is absent (`docker run -d`), or starts it if it exists.
//! `update` pulls and recreates it with the same settings. One-offs run a
//! throwaway container from the same image, given the same data and config,
//! so no compose file and no clone are needed on the server.
const std = @import("std");
const Io = std.Io;
const proc = @import("../proc.zig");
const driver = @import("../driver.zig");

const Error = proc.Error;

/// The image used when neither PESQUE_IMAGE nor a running container names one.
pub const default_image = "ghcr.io/zeeetech/pesque:latest";

fn mountArg(host: *proc.Host, m: proc.Mount) Error![]const u8 {
    return std.fmt.allocPrint(host.gpa, "{s}:{s}", .{ m.source, m.target }) catch error.OutOfMemory;
}

/// The image the CLI should run. PESQUE_IMAGE wins; otherwise the running
/// container's image (so a one-off matches the code the live server runs);
/// otherwise the published image, for a container that does not exist yet.
pub fn image(self: driver.Docker, host: *proc.Host) Error![]const u8 {
    if (self.image.len > 0) return self.image;
    const argv = [_][]const u8{
        host.progs.docker,   "inspect", self.container, "--format",
        "{{.Config.Image}}",
    };
    const cap = host.capture(&argv) catch |e| switch (e) {
        error.DriverFailed => return default_image,
        else => return e,
    };
    defer host.freeCapture(cap);
    const found = cap.line();
    if (!cap.ok() or found.len == 0) return default_image;
    return host.gpa.dupe(u8, found) catch error.OutOfMemory;
}

/// Does a container named `self.container` exist?
pub fn exists(self: driver.Docker, host: *proc.Host) Error!bool {
    const argv = [_][]const u8{
        host.progs.docker, "inspect", self.container, "--format", "{{.Id}}",
    };
    const cap = host.capture(&argv) catch |e| switch (e) {
        error.DriverFailed => return false,
        else => return e,
    };
    defer host.freeCapture(cap);
    return cap.ok() and cap.line().len > 0;
}

fn appendVolume(g: std.mem.Allocator, argv: *std.ArrayList([]const u8), source: []const u8, target: []const u8, ro: bool) Error!void {
    const spec = std.fmt.allocPrint(g, "{s}:{s}{s}", .{ source, target, if (ro) ":ro" else "" }) catch return error.OutOfMemory;
    try argv.appendSlice(g, &.{ "-v", spec });
}

/// Create and start the container: `docker run -d` with the CLI's known
/// settings (data mount, optional config mount, published port, restart
/// policy). `img_override` lets `update` run a specific tag.
/// Resolve the config path to mount (absolute; docker bind mounts need it and
/// a missing path would become an empty directory at the mount point).
fn configPath(self: driver.Docker, host: *proc.Host) Error!?[]const u8 {
    if (self.config.len == 0) return null;
    return Io.Dir.cwd().realPathFileAlloc(host.io, self.config, host.gpa) catch {
        host.err("PESQUE_CONFIG '{s}' does not exist.", .{self.config});
        return error.DriverFailed;
    };
}

pub fn create(self: driver.Docker, host: *proc.Host, img_override: ?[]const u8) Error!u8 {
    const img = img_override orelse try image(self, host);
    const g = host.gpa;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(g);
    try argv.appendSlice(g, &.{
        host.progs.docker, "run",          "-d",
        "--name",          self.container, "--restart",
        "unless-stopped",
    });
    try appendVolume(g, &argv, self.data, "/data", false);
    if (try configPath(self, host)) |abs| try appendVolume(g, &argv, abs, "/data/pesque.conf", true);
    if (self.publish.len > 0) try argv.appendSlice(g, &.{ "-p", self.publish });
    try argv.append(g, img);
    return host.run(argv.items);
}

/// `up`: create the container if it does not exist, else start it.
pub fn up(self: driver.Docker, host: *proc.Host) Error!u8 {
    if (try exists(self, host)) {
        host.step("starting the container", .{});
        const argv = [_][]const u8{ host.progs.docker, "start", self.container };
        return host.run(&argv);
    }
    host.step("creating and starting the container", .{});
    return create(self, host, null);
}

/// `down`: stop the container. Never removes it and never touches its data.
pub fn down(self: driver.Docker, host: *proc.Host) Error!u8 {
    host.step("stopping the container (data is kept)", .{});
    const argv = [_][]const u8{ host.progs.docker, "stop", self.container };
    return host.run(&argv);
}

pub fn restart(self: driver.Docker, host: *proc.Host) Error!u8 {
    host.step("restarting the container", .{});
    const argv = [_][]const u8{ host.progs.docker, "restart", self.container };
    return host.run(&argv);
}

pub fn pull(self: driver.Docker, host: *proc.Host, tag: ?[]const u8) Error!u8 {
    host.step("pulling the image", .{});
    const base_img = try image(self, host);
    const img = if (tag) |t| try tagImage(host, base_img, t) else base_img;
    const argv = [_][]const u8{ host.progs.docker, "pull", img };
    return host.run(&argv);
}

/// `update [tag]`: pull, then recreate the container. A running container keeps
/// its old image, so it has to be replaced; the named volume / bind mount
/// survives the removal (only `rm` runs, never `rm -v`).
pub fn update(self: driver.Docker, host: *proc.Host, tag: ?[]const u8) Error!u8 {
    _ = try pull(self, host, tag);
    // Resolve the image before removing the container (inspect needs it live).
    const img = if (tag) |t| try tagImage(host, try image(self, host), t) else try image(self, host);
    host.step("recreating the container", .{});
    const rm = [_][]const u8{ host.progs.docker, "rm", "-f", self.container };
    // Absent container: rm fails, which is fine, create runs next.
    _ = host.run(&rm) catch {};
    return create(self, host, img);
}

/// Swap the tag portion of an image reference (`repo:old` -> `repo:tag`).
fn tagImage(host: *proc.Host, img: []const u8, tag: []const u8) Error![]const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, img, ':')) |i| img[0..i] else img;
    return std.fmt.allocPrint(host.gpa, "{s}:{s}", .{ base, tag }) catch error.OutOfMemory;
}

/// Run a one-off domain verb in a throwaway container from the same image the
/// server runs. It is given the same data and config the server was created
/// with (not `--volumes-from`), so it works whether or not the container is up
/// yet: `pesque config template` can produce a conf before the first `up`.
pub fn runOnce(self: driver.Docker, host: *proc.Host, ro: driver.RunOnce) Error!u8 {
    try host.resolveEnv(ro.env);
    const img = try image(self, host);
    const g = host.gpa;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(g);
    try argv.appendSlice(g, &.{ host.progs.docker, "run", "--rm", "-i" });
    // `-t` only when the caller is on a terminal.
    if (ro.interactive and host.stdinIsTty()) try argv.append(g, "-t");
    try appendVolume(g, &argv, self.data, "/data", false);
    if (try configPath(self, host)) |abs| try appendVolume(g, &argv, abs, "/data/pesque.conf", true);
    try argv.appendSlice(g, &.{ "-e", "PDS_SERVE=false" });
    // Secrets travel bare: `-e KEY` with the value in the environment.
    for (ro.env) |e| try argv.appendSlice(g, &.{ "-e", e.key });
    for (ro.mounts) |m| try argv.appendSlice(g, &.{ "-v", try mountArg(host, m) });
    try argv.appendSlice(g, &.{ img, "/app/bin/pesque", ro.verb });
    try argv.appendSlice(g, ro.argv);
    return host.run(argv.items);
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

/// `docker inspect` health status for a container (or id). The image's
/// HEALTHCHECK already probes /xrpc/_health, so container health IS the
/// `_health` check.
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

/// Read the container process state, not its health status. An unhealthy
/// container can still be writing to its data directory and is not safe to
/// restore over.
pub fn running(self: driver.Docker, host: *proc.Host) Error!bool {
    const inspect = [_][]const u8{
        host.progs.docker, "inspect", self.container, "--format", "{{.State.Running}}",
    };
    const cap = host.capture(&inspect) catch |e| return e;
    defer host.freeCapture(cap);

    if (!cap.ok()) {
        host.err("could not verify whether container '{s}' is stopped; restore was not run.", .{self.container});
        return error.DriverFailed;
    }

    return if (std.mem.eql(u8, cap.line(), "true"))
        true
    else if (std.mem.eql(u8, cap.line(), "false"))
        false
    else {
        host.err("container '{s}' returned an unknown running state; restore was not run.", .{self.container});
        return error.DriverFailed;
    };
}

pub fn healthFromPoll(host: *proc.Host, poll: driver.Poll) Error!driver.Health {
    return switch (poll) {
        .healthy => .healthy,
        .starting => .degraded,
        .down => {
            host.err("the pesque container is not running. Start it with 'pesque up', or check 'pesque logs'.", .{});
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
