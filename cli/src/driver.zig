//! The driver interface: a tagged union over the closed backend set
//! (compose, docker, systemd, nixos) with exhaustive switches, per spec D2.
//! Implementations live in `drivers/`.
const std = @import("std");
const proc = @import("proc.zig");
const compose = @import("drivers/compose.zig");
const docker = @import("drivers/docker.zig");
const systemd = @import("drivers/systemd.zig");
const nixos = @import("drivers/nixos.zig");

pub const Kind = enum { compose, docker, systemd, nixos };

/// One one-off task: `/app/bin/pesque <verb> <argv>` inside the driver's
/// runtime. Mirrors the `Pesque.Ops.RunOnce` contract (spec §2).
pub const RunOnce = struct {
    verb: []const u8,
    argv: []const []const u8 = &.{},
    /// Verb inputs, passed as bare `-e KEY` so values never show in `ps`.
    env: []const proc.Env = &.{},
    /// Host paths mounted into the one-off at the same path (backup/restore).
    /// Ignored by backends that run on the host filesystem directly.
    mounts: []const proc.Mount = &.{},
    interactive: bool = false,
};

pub const LogOpts = struct {
    follow: bool = false,
    tail: ?u64 = null,
};

pub const Health = enum { healthy, degraded };

/// Quiet tri-state for polling (setup's health wait prints nothing per try).
pub const Poll = enum { healthy, starting, down };

/// Where the server's data lives, as far as the driver can tell.
pub const DataDir = union(enum) {
    /// A docker volume (compose/docker backends).
    volume: []const u8,
    /// A host path (systemd/nixos backends).
    path: []const u8,
};

pub const Compose = struct {
    /// Absolute directory holding docker-compose.yml.
    project_dir: []const u8,
    /// PESQUE_BUILD=1: build the image from source instead of pulling.
    build: bool = false,
    service: []const u8 = "pesque",
};

pub const Docker = struct {
    container: []const u8 = "pesque",
    /// Empty until resolved from the running container.
    image: []const u8 = "",
};

pub const Systemd = struct {
    unit: []const u8 = "pesque",
    release: []const u8 = "/opt/pesque",
};

pub const Nixos = struct {
    unit: []const u8 = "pesque",
    release: []const u8 = "/opt/pesque",
};

pub const Driver = union(Kind) {
    compose: Compose,
    docker: Docker,
    systemd: Systemd,
    nixos: Nixos,

    pub fn kind(self: Driver) Kind {
        return switch (self) {
            .compose => .compose,
            .docker => .docker,
            .systemd => .systemd,
            .nixos => .nixos,
        };
    }

    /// Run a one-off domain verb. Exit codes propagate (0 ok, 1 domain
    /// failure); driver/environment failures come back as errors (3).
    pub fn runOnce(self: Driver, host: *proc.Host, ro: RunOnce) proc.Error!u8 {
        return switch (self) {
            .compose => |d| compose.runOnce(d, host, ro),
            .docker => |d| docker.runOnce(d, host, ro),
            .systemd => |d| systemd.runOnce(d, host, ro),
            .nixos => |d| nixos.runOnce(d, host, ro),
        };
    }

    /// Bring the service up. Foreign-lifecycle backends refuse (3) or no-op.
    pub fn up(self: Driver, host: *proc.Host) proc.Error!u8 {
        return switch (self) {
            .compose => |d| compose.up(d, host),
            .docker => |d| docker.refuseLifecycle(host, "start", "docker start {s}", .{d.container}),
            .systemd => |d| systemd.start(d, host),
            .nixos => |d| nixos.noopLifecycle(d, host, "up"),
        };
    }

    /// Take the service down. NEVER deletes data (`down` never passes `-v`).
    pub fn down(self: Driver, host: *proc.Host) proc.Error!u8 {
        return switch (self) {
            .compose => |d| compose.down(d, host),
            .docker => |d| docker.refuseLifecycle(host, "stop", "docker stop {s}", .{d.container}),
            .systemd => |d| systemd.stop(d, host),
            .nixos => |d| nixos.noopLifecycle(d, host, "down"),
        };
    }

    pub fn restart(self: Driver, host: *proc.Host) proc.Error!u8 {
        return switch (self) {
            .compose => |d| compose.restart(d, host),
            .docker => |d| docker.restart(d, host),
            .systemd => |d| systemd.restart(d, host),
            .nixos => |d| nixos.restart(d, host),
        };
    }

    /// Pull (or build) the release. On systemd this downloads the release
    /// tarball and swaps the /opt/pesque symlink.
    pub fn pull(self: Driver, host: *proc.Host, tag: ?[]const u8) proc.Error!u8 {
        return switch (self) {
            .compose => |d| compose.pull(d, host, tag),
            .docker => |d| docker.pull(d, host, tag),
            .systemd => |d| systemd.pull(d, host, tag),
            .nixos => |d| nixos.noopUpdate(d, host),
        };
    }

    pub fn logs(self: Driver, host: *proc.Host, opts: LogOpts) proc.Error!u8 {
        return switch (self) {
            .compose => |d| compose.logs(d, host, opts),
            .docker => |d| docker.logs(d, host, opts),
            .systemd => |d| systemd.logs(d, host, opts),
            .nixos => |d| nixos.logs(d, host, opts),
        };
    }

    pub fn health(self: Driver, host: *proc.Host) proc.Error!Health {
        return switch (self) {
            .compose => |d| compose.health(d, host),
            .docker => |d| docker.health(d, host),
            .systemd => |d| systemd.health(d, host),
            .nixos => |d| nixos.health(d, host),
        };
    }

    /// Quiet status probe used by setup's health wait (prints nothing).
    pub fn pollStatus(self: Driver, host: *proc.Host) proc.Error!Poll {
        return switch (self) {
            .compose => |d| compose.pollStatus(d, host),
            .docker => |d| docker.pollStatus(host, d.container),
            .systemd => |d| systemd.pollStatus(d, host),
            .nixos => |d| systemd.pollStatus(.{ .unit = d.unit, .release = d.release }, host),
        };
    }

    pub fn dataDir(self: Driver, host: *proc.Host) proc.Error!DataDir {
        return switch (self) {
            .compose => |d| compose.dataDir(d, host),
            .docker => |d| docker.dataDir(d, host),
            .systemd => |d| systemd.dataDir(d, host),
            .nixos => |d| nixos.dataDir(d, host),
        };
    }

    /// Can one-off tasks be attached to an interactive terminal?
    pub fn interactive(self: Driver) bool {
        return switch (self) {
            .compose, .docker, .systemd, .nixos => true,
        };
    }

    /// Does the driver own the service lifecycle (up/down/update)?
    pub fn ownsLifecycle(self: Driver) bool {
        return switch (self) {
            .compose, .systemd => true,
            .docker, .nixos => false,
        };
    }

    /// `update [tag]`: pull (or build) + restart, per backend semantics.
    /// Compose uses `up -d` (restart alone keeps the old container), docker
    /// hands over to PESQUE_RESTART_CMD, systemd swaps the /opt symlink and
    /// restarts the unit, nixos is a no-op.
    pub fn update(self: Driver, host: *proc.Host, tag: ?[]const u8) proc.Error!u8 {
        return switch (self) {
            .compose => |d| compose.update(d, host, tag),
            .docker => |d| docker.update(d, host, tag),
            .systemd => |d| systemd.update(d, host, tag),
            .nixos => |d| nixos.noopUpdate(d, host),
        };
    }
};
