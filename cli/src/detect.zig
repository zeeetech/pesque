//! Backend discovery and the `backend` command.
//!
//! Order (spec §4): `--backend`/`PESQUE_BACKEND` -> upward search for
//! `docker-compose.yml` -> `docker inspect <PESQUE_CONTAINER|pesque>` ->
//! `systemctl` + unit `<PESQUE_SERVICE|pesque>` (nixos when
//! /run/current-system exists) -> error 3 with the trace of what was tried.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const proc = @import("proc.zig");
const driver = @import("driver.zig");

const Error = proc.Error;

pub fn parseKind(value: []const u8) ?driver.Kind {
    if (std.mem.eql(u8, value, "compose")) return .compose;
    if (std.mem.eql(u8, value, "docker")) return .docker;
    if (std.mem.eql(u8, value, "systemd")) return .systemd;
    if (std.mem.eql(u8, value, "nixos")) return .nixos;
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
                host.err("PESQUE_BACKEND must be compose, docker, systemd or nixos, got: {s}.", .{b});
                return error.Usage;
            };
            return explicit(host, kind);
        }
    }

    // 1. Upward search for a docker-compose.yml (compose install).
    if (try findCompose(host, &trace)) |d| return .{ .compose = d };

    // 2. A running container (docker backend), then a systemd unit. Windows
    //    keeps docker/compose only.
    if (builtin.os.tag != .windows) {
        if (try tryDocker(host, &trace)) |d| return .{ .docker = d };
        if (try trySystemd(host, &trace)) |d| return d;
    } else {
        try traceNote(host, &trace, "systemd is not supported on windows", .{});
    }

    // 3. Nothing found: error 3 with the trace.
    host.err("could not detect a backend.", .{});
    for (trace.items) |t| host.printTo(.stderr, "  tried: {s}\n", .{t});
    host.printTo(.stderr, "  run from the compose install directory, or force one with --backend compose|docker|systemd|nixos.\n", .{});
    return error.DriverFailed;
}

fn traceNote(host: *proc.Host, trace: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) Error!void {
    const line = std.fmt.allocPrint(host.gpa, fmt, args) catch return error.OutOfMemory;
    try trace.append(host.gpa, line);
}

fn explicit(host: *proc.Host, kind: driver.Kind) Error!driver.Driver {
    switch (kind) {
        .compose => {
            const dir = try composeRoot(host);
            return .{ .compose = .{ .project_dir = dir, .build = buildFlag(host) } };
        },
        .docker => {
            return .{ .docker = .{
                .container = host.get("PESQUE_CONTAINER") orelse "pesque",
                .image = host.get("PESQUE_IMAGE") orelse "",
            } };
        },
        .systemd => {
            if (builtin.os.tag == .windows) {
                host.err("the systemd backend is not supported on windows (docker and compose are).", .{});
                return error.DriverFailed;
            }
            try verifyUnit(host, host.get("PESQUE_SERVICE") orelse "pesque");
            return .{ .systemd = .{ .unit = host.get("PESQUE_SERVICE") orelse "pesque" } };
        },
        .nixos => {
            if (builtin.os.tag == .windows) {
                host.err("the nixos backend is not supported on windows (docker and compose are).", .{});
                return error.DriverFailed;
            }
            const unit = host.get("PESQUE_SERVICE") orelse "pesque";
            try verifyUnit(host, unit);
            return .{ .nixos = .{ .unit = unit, .release = host.get("PESQUE_RELEASE") orelse "/opt/pesque" } };
        },
    }
}

fn buildFlag(host: *proc.Host) bool {
    const v = host.get("PESQUE_BUILD") orelse return false;
    return std.mem.eql(u8, v, "1");
}

/// Where the compose search starts and (if set) stops.
fn searchRoot(host: *proc.Host) Error![]const u8 {
    const root = host.get("PESQUE_ROOT") orelse ".";
    return Io.Dir.cwd().realPathFileAlloc(host.io, root, host.gpa) catch {
        host.err("cannot resolve {s} (does it exist?).", .{root});
        return error.DriverFailed;
    };
}

/// PESQUE_ROOT (explicit compose root) must hold a docker-compose.yml.
fn composeRoot(host: *proc.Host) Error![]const u8 {
    const dir = try searchRoot(host);
    const marker = std.fs.path.join(host.gpa, &.{ dir, "docker-compose.yml" }) catch return error.OutOfMemory;
    Io.Dir.cwd().access(host.io, marker, .{}) catch {
        host.err("no docker-compose.yml in {s}. Run from the compose install directory or set PESQUE_ROOT to it.", .{dir});
        return error.DriverFailed;
    };
    return dir;
}

/// Walk up from the search root looking for docker-compose.yml.
fn findCompose(host: *proc.Host, trace: *std.ArrayList([]const u8)) Error!?driver.Compose {
    var dir = try searchRoot(host);
    // PESQUE_ROOT set: the search starts (and stops) there.
    const limited = host.get("PESQUE_ROOT") != null;
    while (true) {
        const marker = std.fs.path.join(host.gpa, &.{ dir, "docker-compose.yml" }) catch return error.OutOfMemory;
        if (Io.Dir.cwd().access(host.io, marker, .{})) {
            return driver.Compose{ .project_dir = dir, .build = buildFlag(host) };
        } else |_| {}
        try traceNote(host, trace, "no docker-compose.yml in {s}", .{dir});
        if (limited) return null;
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null; // filesystem root reached
        dir = parent;
    }
}

fn tryDocker(host: *proc.Host, trace: *std.ArrayList([]const u8)) Error!?driver.Docker {
    const container = host.get("PESQUE_CONTAINER") orelse "pesque";
    const argv = [_][]const u8{
        host.progs.docker, "inspect", container, "--format", "{{.Config.Image}}",
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
        try traceNote(host, trace, "no container named '{s}' (docker inspect)", .{container});
        return null;
    }
    return driver.Docker{
        .container = container,
        .image = host.get("PESQUE_IMAGE") orelse (host.gpa.dupe(u8, cap.line()) catch return error.OutOfMemory),
    };
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
    // NixOS systems carry /run/current-system.
    const nixos_system = Io.Dir.cwd().access(host.io, "/run/current-system", .{});
    if (nixos_system) {
        return driver.Driver{ .nixos = .{
            .unit = unit,
            .release = host.get("PESQUE_RELEASE") orelse "/opt/pesque",
        } };
    } else |_| {}
    return driver.Driver{ .systemd = .{ .unit = unit } };
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
        .compose => |c| {
            host.out("project dir:  {s}", .{c.project_dir});
            host.out("service:      {s}", .{c.service});
            host.out("compose file: {s}", .{try std.fs.path.join(host.gpa, &.{ c.project_dir, "docker-compose.yml" })});
        },
        .docker => |dc| {
            host.out("container: {s}", .{dc.container});
            host.out("image:     {s}", .{if (dc.image.len > 0) dc.image else "(resolved from the running container)"});
        },
        .systemd => |s| {
            host.out("unit:    {s}", .{s.unit});
            host.out("release: {s}", .{s.release});
        },
        .nixos => |n| {
            host.out("unit:    {s}", .{n.unit});
            host.out("release: {s} (PESQUE_RELEASE)", .{n.release});
        },
    }
    const data = try d.dataDir(host);
    switch (data) {
        .volume => |v| host.out("data:     volume {s}", .{v}),
        .path => |p| host.out("data:     {s}", .{p}),
    }
    host.out("one-off tasks: {s} /app/bin/pesque <verb> <argv>", .{oneOffShape(d)});
    host.out("lifecycle:     {s}", .{if (d.ownsLifecycle()) "owned (up/down/restart/update)" else "foreign (this backend refuses up/down; the service manager owns it)"});
    host.out("interactive:   {s}", .{if (d.interactive()) "yes" else "no"});
    return 0;
}

fn oneOffShape(d: driver.Driver) []const u8 {
    return switch (d) {
        .compose => "docker compose run --rm --no-deps pesque",
        .docker => "docker run --rm -i --volumes-from <container> --env-file <PDS_* mirror>",
        .systemd => "systemd-run --pipe --wait --collect -p User=pesque -p Group=pesque",
        .nixos => "systemd-run --pipe --wait --collect (or direct exec) via ${PESQUE_RELEASE}",
    };
}
