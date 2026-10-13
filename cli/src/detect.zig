//! Backend discovery and the `backend` command.
//!
//! Two shapes: docker (a container the CLI owns) and systemd (a unit that owns
//! the service). Order: `--backend`/`PESQUE_BACKEND` -> `docker inspect
//! <PESQUE_CONTAINER|pesque>` -> `systemctl` unit `<PESQUE_SERVICE|pesque>` ->
//! error 3 with the trace of what was tried. NixOS is a systemd host.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const proc = @import("proc.zig");
const driver = @import("driver.zig");
const systemd = @import("drivers/systemd.zig");

const Error = proc.Error;

pub fn parseKind(value: []const u8) ?driver.Kind {
    if (std.mem.eql(u8, value, "docker")) return .docker;
    if (std.mem.eql(u8, value, "systemd")) return .systemd;
    return null;
}

/// Detect the backend. On failure prints the trace and returns DriverFailed (3).
pub fn detect(host: *proc.Host, flag: ?driver.Kind) Error!driver.Driver {
    if (flag) |k| return explicit(host, k);

    var trace: std.ArrayList([]const u8) = .empty;
    defer trace.deinit(host.gpa);

    // 0. PESQUE_BACKEND (empty string counts as unset).
    if (host.get("PESQUE_BACKEND")) |b| {
        if (b.len > 0) {
            const kind = parseKind(b) orelse {
                host.err("PESQUE_BACKEND must be docker or systemd, got: {s}.", .{b});
                return error.Usage;
            };
            return explicit(host, kind);
        }
    }

    // 1. A running container (docker backend), then a systemd unit. Windows
    //    keeps docker only.
    if (builtin.os.tag != .windows) {
        if (try tryDocker(host, &trace)) |d| return .{ .docker = d };
        if (try trySystemd(host, &trace)) |d| return d;
    } else {
        if (try tryDocker(host, &trace)) |d| return .{ .docker = d };
        try traceNote(host, &trace, "systemd is not supported on windows", .{});
    }

    // 2. Nothing found: error 3 with the trace.
    host.err("could not detect a backend.", .{});
    for (trace.items) |t| host.printTo(.stderr, "  tried: {s}\n", .{t});
    host.printTo(.stderr, "  create a container ('pesque up' with PESQUE_BACKEND=docker), or force one with --backend docker|systemd.\n", .{});
    return error.DriverFailed;
}

fn traceNote(host: *proc.Host, trace: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) Error!void {
    const line = std.fmt.allocPrint(host.gpa, fmt, args) catch return error.OutOfMemory;
    try trace.append(host.gpa, line);
}

fn explicit(host: *proc.Host, kind: driver.Kind) Error!driver.Driver {
    switch (kind) {
        .docker => return .{ .docker = dockerFromEnv(host) },
        .systemd => {
            if (builtin.os.tag == .windows) {
                host.err("the systemd backend is not supported on windows (docker is).", .{});
                return error.DriverFailed;
            }
            const unit = host.get("PESQUE_SERVICE") orelse "pesque";
            try verifyUnit(host, unit);
            return .{ .systemd = .{ .unit = unit, .release = resolveRelease(host, unit) } };
        },
    }
}

/// The docker container settings, from the environment (PESQUE_*), with the
/// defaults baked into `driver.Docker`.
fn dockerFromEnv(host: *proc.Host) driver.Docker {
    var d: driver.Docker = .{};
    if (host.get("PESQUE_CONTAINER")) |v| d.container = v;
    if (host.get("PESQUE_IMAGE")) |v| d.image = v;
    if (host.get("PESQUE_DATA")) |v| d.data = v;
    if (host.get("PESQUE_CONFIG")) |v| {
        d.config = v;
    } else if (Io.Dir.cwd().realPathFileAlloc(host.io, "pesque.conf", host.gpa) catch null) |p| {
        // Same convention as the server: with PDS_CONFIG unset it reads
        // `pesque.conf` in the working directory. PESQUE_CONFIG still wins.
        d.config = p;
    }
    if (host.get("PESQUE_PUBLISH")) |v| d.publish = v;
    return d;
}

/// The release directory: PESQUE_RELEASE wins, else the unit's ExecStart, else
/// /opt/pesque (the tarball install's default).
fn resolveRelease(host: *proc.Host, unit: []const u8) []const u8 {
    if (host.get("PESQUE_RELEASE")) |r| return r;
    if (systemd.releaseFromUnit(host, unit)) |r| return r;
    return "/opt/pesque";
}

fn tryDocker(host: *proc.Host, trace: *std.ArrayList([]const u8)) Error!?driver.Docker {
    var d = dockerFromEnv(host);
    const argv = [_][]const u8{
        host.progs.docker, "inspect", d.container, "--format", "{{.Config.Image}}",
    };
    const cap = host.capture(&argv) catch |e| switch (e) {
        error.DriverFailed => {
            try traceNote(host, trace, "docker is not usable (spawn failed)", .{});
            return null;
        },
        else => return e,
    };
    defer host.freeCapture(cap);
    if (!cap.ok()) {
        try traceNote(host, trace, "no container named '{s}' (docker inspect)", .{d.container});
        return null;
    }
    if (d.image.len == 0) d.image = host.gpa.dupe(u8, cap.line()) catch return error.OutOfMemory;
    return d;
}

fn unitCheck(host: *proc.Host, trace: *std.ArrayList([]const u8)) Error!?driver.Driver {
    const unit = host.get("PESQUE_SERVICE") orelse "pesque";
    const argv = [_][]const u8{ host.progs.systemctl, "cat", unit };
    const cap = host.capture(&argv) catch |e| switch (e) {
        error.DriverFailed => {
            try traceNote(host, trace, "systemctl is not usable (spawn failed)", .{});
            return null;
        },
        else => return e,
    };
    defer host.freeCapture(cap);
    if (!cap.ok()) {
        try traceNote(host, trace, "no systemd unit named '{s}' (systemctl cat)", .{unit});
        return null;
    }
    return driver.Driver{ .systemd = .{ .unit = unit, .release = resolveRelease(host, unit) } };
}

fn trySystemd(host: *proc.Host, trace: *std.ArrayList([]const u8)) Error!?driver.Driver {
    return unitCheck(host, trace);
}

fn verifyUnit(host: *proc.Host, unit: []const u8) Error!void {
    const argv = [_][]const u8{ host.progs.systemctl, "cat", unit };
    const cap = host.capture(&argv) catch |e| return e;
    defer host.freeCapture(cap);
    if (!cap.ok()) {
        host.err("no systemd unit named '{s}'. Set PESQUE_SERVICE to the unit name, or pick the right --backend.", .{unit});
        return error.DriverFailed;
    }
}

// --- the `backend` command ---------------------------------------------------

pub fn printReport(host: *proc.Host, d: driver.Driver) Error!u8 {
    host.out("backend: {s}", .{@tagName(d.kind())});
    switch (d) {
        .docker => |dc| {
            host.out("container: {s}", .{dc.container});
            host.out("image:     {s}", .{if (dc.image.len > 0) dc.image else "(resolved from the running container)"});
            host.out("data:      {s} -> /data", .{dc.data});
            if (dc.config.len > 0) host.out("config:    {s} -> /data/pesque.conf", .{dc.config});
            host.out("publish:   {s}", .{dc.publish});
        },
        .systemd => |s| {
            host.out("unit:    {s}", .{s.unit});
            host.out("release: {s}", .{s.release});
        },
    }
    const data = try d.dataDir(host);
    switch (data) {
        .volume => |v| host.out("data dir:  volume {s}", .{v}),
        .path => |p| host.out("data dir:  {s}", .{p}),
    }
    host.out("one-off tasks: {s}", .{oneOffShape(d)});
    host.out("lifecycle:     {s}", .{if (d.ownsLifecycle()) "owned (up/down/restart/update)" else "foreign (the unit owns the service; up/down/restart/update are no-ops)"});
    host.out("interactive:   {s}", .{if (d.interactive()) "yes" else "no"});
    return 0;
}

fn oneOffShape(d: driver.Driver) []const u8 {
    return switch (d) {
        .docker => "docker run --rm -i -v <PESQUE_DATA>:/data -v <conf>:/data/pesque.conf",
        .systemd => "direct exec of <release>/bin/pesque as the service user",
    };
}
