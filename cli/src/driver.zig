//! The driver interface: a tagged union over the closed backend set
//! (docker, systemd) with exhaustive switches. Implementations live in
//! `drivers/`.
//!
//! Two shapes, two owners. The docker backend is imperative: the CLI creates
//! the container and owns its lifecycle. The systemd backend is declarative:
//! the unit owns the service (up/down/restart/update are no-ops with a
//! message), and one-offs run the release directly as the service user.
const std = @import("std");
const proc = @import("proc.zig");
const docker = @import("drivers/docker.zig");
const systemd = @import("drivers/systemd.zig");

pub const Kind = enum { docker, systemd };

/// One one-off task: `/app/bin/pesque <verb> <argv>` inside the driver's
/// runtime. Mirrors `Pesque.Ops.RunOnce` on the Elixir side.
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
    /// A docker volume (the docker backend).
    volume: []const u8,
    /// A host path (docker bind mount / systemd).
    path: []const u8,
};

pub const Docker = struct {
    container: []const u8 = "pesque",
    /// Empty until resolved from PESQUE_IMAGE or the running container.
    image: []const u8 = "",
    /// Host path or named volume mounted at /data (PESQUE_DATA).
    data: []const u8 = "pesque-data",
    /// Host path to a pesque.conf mounted read-only at /data/pesque.conf
    /// (PESQUE_CONFIG). Empty means the container configures itself from its
    /// environment.
    config: []const u8 = "",
    /// Published-port spec for `docker run -p` (PESQUE_PUBLISH). The default
    /// keeps the server on loopback, where a proxy on the same host reaches it.
    publish: []const u8 = "127.0.0.1:4000:4000",
};

pub const Systemd = struct {
    unit: []const u8 = "pesque",
    release: []const u8 = "/opt/pesque",
};

pub const Driver = union(Kind) {
    docker: Docker,
    systemd: Systemd,

    pub fn kind(self: Driver) Kind {
        return switch (self) {
            .docker => .docker,
            .systemd => .systemd,
        };
    }

    /// Run a one-off domain verb. Exit codes propagate (0 ok, 1 domain
    /// failure); driver/environment failures come back as errors (3).
    pub fn runOnce(self: Driver, host: *proc.Host, ro: RunOnce) proc.Error!u8 {
        return switch (self) {
            .docker => |d| docker.runOnce(d, host, ro),
            .systemd => |d| systemd.runOnce(d, host, ro),
        };
    }

    /// Bring the service up. Docker creates the container if it is absent.
    /// Systemd: the unit owns the lifecycle, so it is a no-op.
    pub fn up(self: Driver, host: *proc.Host) proc.Error!u8 {
        return switch (self) {
            .docker => |d| docker.up(d, host),
            .systemd => |d| systemd.noopLifecycle(d, host, "up"),
        };
    }

    /// Take the service down. NEVER deletes data.
    pub fn down(self: Driver, host: *proc.Host) proc.Error!u8 {
        return switch (self) {
            .docker => |d| docker.down(d, host),
            .systemd => |d| systemd.noopLifecycle(d, host, "down"),
        };
    }

    pub fn restart(self: Driver, host: *proc.Host) proc.Error!u8 {
        return switch (self) {
            .docker => |d| docker.restart(d, host),
            .systemd => |d| systemd.noopLifecycle(d, host, "restart"),
        };
    }

    pub fn logs(self: Driver, host: *proc.Host, opts: LogOpts) proc.Error!u8 {
        return switch (self) {
            .docker => |d| docker.logs(d, host, opts),
            .systemd => |d| systemd.logs(d, host, opts),
        };
    }

    pub fn health(self: Driver, host: *proc.Host) proc.Error!Health {
        return switch (self) {
            .docker => |d| docker.health(d, host),
            .systemd => |d| systemd.health(d, host),
        };
    }

    /// Quiet status probe used by the health wait (prints nothing).
    pub fn pollStatus(self: Driver, host: *proc.Host) proc.Error!Poll {
        return switch (self) {
            .docker => |d| docker.pollStatus(host, d.container),
            .systemd => |d| systemd.pollStatus(d, host),
        };
    }

    /// Whether the managed server process is active, independent of its
    /// health endpoint. Restore uses this to prove the writer is stopped.
    pub fn running(self: Driver, host: *proc.Host) proc.Error!bool {
        return switch (self) {
            .docker => |d| docker.running(d, host),
            .systemd => |d| systemd.running(d, host),
        };
    }

    pub fn dataDir(self: Driver, host: *proc.Host) proc.Error!DataDir {
        return switch (self) {
            .docker => |d| docker.dataDir(d, host),
            .systemd => |d| systemd.dataDir(d, host),
        };
    }

    /// Can one-off tasks be attached to an interactive terminal?
    pub fn interactive(self: Driver) bool {
        return switch (self) {
            .docker, .systemd => true,
        };
    }

    /// Does the driver own the service lifecycle (up/down/restart/update)?
    pub fn ownsLifecycle(self: Driver) bool {
        return switch (self) {
            .docker => true,
            .systemd => false,
        };
    }

    /// `update [tag]`: docker pulls and recreates the container with the same
    /// settings; systemd no-ops (the release is managed outside the CLI).
    pub fn update(self: Driver, host: *proc.Host, tag: ?[]const u8) proc.Error!u8 {
        return switch (self) {
            .docker => |d| docker.update(d, host, tag),
            .systemd => |d| systemd.noopUpdate(d, host),
        };
    }
};
