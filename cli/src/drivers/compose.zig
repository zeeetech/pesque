//! The compose backend: drives `docker compose` in a project directory.
//! One-offs run via `docker compose run`, which reuses the service's image,
//! volume and environment by construction.
const std = @import("std");
const Io = std.Io;
const proc = @import("../proc.zig");
const driver = @import("../driver.zig");
const docker = @import("docker.zig");

const Error = proc.Error;

const compose_file = "docker-compose.yml";
const build_file = "docker-compose.build.yml";

/// `docker compose -f <file> [-f build] --project-directory <dir>`.
fn base(self: driver.Compose, host: *proc.Host, argv: *std.ArrayList([]const u8)) Error!void {
    const g = host.gpa;
    try argv.appendSlice(g, &.{ host.progs.docker, "compose", "-f" });
    const main_file = std.fs.path.join(g, &.{ self.project_dir, compose_file }) catch return error.OutOfMemory;
    try argv.append(g, main_file);
    if (self.build) {
        try argv.append(g, "-f");
        const build_override = std.fs.path.join(g, &.{ self.project_dir, build_file }) catch return error.OutOfMemory;
        try argv.append(g, build_override);
    }
    try argv.appendSlice(g, &.{ "--project-directory", self.project_dir });
}

fn mountArg(host: *proc.Host, m: proc.Mount) Error![]const u8 {
    return std.fmt.allocPrint(host.gpa, "{s}:{s}", .{ m.source, m.target }) catch error.OutOfMemory;
}

pub fn runOnce(self: driver.Compose, host: *proc.Host, ro: driver.RunOnce) Error!u8 {
    try host.resolveEnv(ro.env);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try base(self, host, &argv);
    try argv.appendSlice(host.gpa, &.{ "run", "--rm", "--no-deps" });
    // `-T` only when stdin is not a tty (compose cannot allocate one then).
    if (!host.stdinIsTty() or !ro.interactive) try argv.appendSlice(host.gpa, &.{"-T"});
    for (ro.mounts) |m| try argv.appendSlice(host.gpa, &.{ "-v", try mountArg(host, m) });
    try argv.appendSlice(host.gpa, &.{ "-e", "PDS_SERVE=false" });
    // Secrets travel bare: `-e KEY` with the value in the environment.
    for (ro.env) |e| try argv.appendSlice(host.gpa, &.{ "-e", e.key });
    try argv.appendSlice(host.gpa, &.{ self.service, "/app/bin/pesque", ro.verb });
    try argv.appendSlice(host.gpa, ro.argv);
    return host.run(argv.items);
}

/// `update [tag]`: pin the tag (if any) and `up -d`, which pulls the new
/// image and recreates the containers (`restart` alone keeps the old one).
pub fn update(self: driver.Compose, host: *proc.Host, tag: ?[]const u8) Error!u8 {
    if (tag) |t| setTag(host, t);
    return up(self, host);
}

pub fn up(self: driver.Compose, host: *proc.Host) Error!u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try base(self, host, &argv);
    if (self.build) {
        host.step("building the image and starting the server", .{});
        try argv.appendSlice(host.gpa, &.{ "up", "-d", "--build" });
        return host.run(argv.items);
    }
    host.step("pulling the image", .{});
    var pull_argv: std.ArrayList([]const u8) = .empty;
    defer pull_argv.deinit(host.gpa);
    try base(self, host, &pull_argv);
    try pull_argv.append(host.gpa, "pull");
    if (try host.run(pull_argv.items) != 0) {
        host.err("could not pull the image. Set PESQUE_BUILD=1 to build from source instead.", .{});
        return error.DriverFailed;
    }
    host.step("starting the server", .{});
    try argv.appendSlice(host.gpa, &.{ "up", "-d" });
    return host.run(argv.items);
}

pub fn down(self: driver.Compose, host: *proc.Host) Error!u8 {
    host.step("stopping the server (data is kept)", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try base(self, host, &argv);
    // NEVER pass `-v`: down must not delete volumes.
    try argv.appendSlice(host.gpa, &.{"down"});
    return host.run(argv.items);
}

pub fn restart(self: driver.Compose, host: *proc.Host) Error!u8 {
    host.step("restarting the server", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try base(self, host, &argv);
    try argv.appendSlice(host.gpa, &.{ "restart", self.service });
    return host.run(argv.items);
}

pub fn pull(self: driver.Compose, host: *proc.Host, tag: ?[]const u8) Error!u8 {
    host.step("pulling the release", .{});
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try base(self, host, &argv);
    // The compose file interpolates ${PESQUE_TAG:-latest}.
    if (tag) |t| setTag(host, t);
    if (self.build) {
        try argv.append(host.gpa, "build");
    } else {
        try argv.append(host.gpa, "pull");
    }
    return host.run(argv.items);
}

fn setTag(host: *proc.Host, tag: []const u8) void {
    const g = host.gpa;
    const k = g.dupe(u8, "PESQUE_TAG") catch return;
    const v = g.dupe(u8, tag) catch return;
    host.environ.put(k, v) catch {};
}

pub fn logs(self: driver.Compose, host: *proc.Host, opts: driver.LogOpts) Error!u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try base(self, host, &argv);
    try argv.append(host.gpa, "logs");
    if (opts.follow) try argv.append(host.gpa, "-f");
    if (opts.tail) |n| {
        const n_str = std.fmt.allocPrint(host.gpa, "{d}", .{n}) catch return error.OutOfMemory;
        try argv.appendSlice(host.gpa, &.{ "--tail", n_str });
    }
    try argv.append(host.gpa, self.service);
    return host.run(argv.items);
}

pub fn pollStatus(self: driver.Compose, host: *proc.Host) Error!driver.Poll {
    var ps: std.ArrayList([]const u8) = .empty;
    defer ps.deinit(host.gpa);
    try base(self, host, &ps);
    try ps.appendSlice(host.gpa, &.{ "ps", "-q", self.service });
    const cap = host.capture(ps.items) catch |e| return e;
    defer host.freeCapture(cap);
    if (!cap.ok() or cap.line().len == 0) return .down;
    return docker.pollStatus(host, cap.line());
}

pub fn health(self: driver.Compose, host: *proc.Host) Error!driver.Health {
    return healthFromPoll(host, try pollStatus(self, host));
}

pub fn healthFromPoll(host: *proc.Host, poll: driver.Poll) Error!driver.Health {
    return switch (poll) {
        .healthy => .healthy,
        .starting => .degraded,
        .down => {
            host.err("the pesque service is not running. Start it with 'pesque up', or check 'pesque logs'.", .{});
            return error.DriverFailed;
        },
    };
}

pub fn dataDir(self: driver.Compose, host: *proc.Host) Error!driver.DataDir {
    // The compose file declares `volumes: pesque-data:`; compose names the
    // volume `<project>_pesque-data`.
    const project = projectName(host, self.project_dir);
    const name = std.fmt.allocPrint(host.gpa, "{s}_pesque-data", .{project}) catch return error.OutOfMemory;
    return .{ .volume = name };
}

/// The compose project name: COMPOSE_PROJECT_NAME from the project's .env if
/// set, else the sanitized directory basename (what compose itself does).
pub fn projectName(host: *proc.Host, project_dir: []const u8) []const u8 {
    const g = host.gpa;
    if (std.fs.path.join(g, &.{ project_dir, ".env" }) catch null) |env_path| {
        if (Io.Dir.cwd().readFileAlloc(host.io, env_path, g, .limited(1 << 20)) catch null) |content| {
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\t");
                if (std.mem.startsWith(u8, trimmed, "COMPOSE_PROJECT_NAME=")) {
                    const value = std.mem.trim(u8, trimmed["COMPOSE_PROJECT_NAME=".len..], " \t\"'");
                    if (value.len > 0) return value;
                }
            }
        }
    }
    return sanitizeProjectName(host, std.fs.path.basename(project_dir));
}

fn sanitizeProjectName(host: *proc.Host, name: []const u8) []const u8 {
    const g = host.gpa;
    const out = g.dupe(u8, name) catch return "pesque";
    for (out, 0..) |ch, i| {
        out[i] = switch (ch) {
            'A'...'Z' => ch + ('a' - 'A'),
            'a'...'z', '0'...'9', '-', '_' => ch,
            else => '-',
        };
    }
    return out;
}
