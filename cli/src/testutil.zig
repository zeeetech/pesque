//! Shared test scaffolding: writes the fake `docker`/`systemctl`/
//! `systemd-run`/`journalctl`/`curl` shims into a temp dir, points a
//! `proc.Host` at them, and parses the invocation log back out for
//! assertions. The shims are wired by explicit path (not PATH) because argv[0]
//! resolution always consults the parent environment in 0.17.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const proc = @import("proc.zig");

pub const docker_shim = @embedFile("../test/shims/docker");
pub const systemctl_shim = @embedFile("../test/shims/systemctl");
pub const systemd_run_shim = @embedFile("../test/shims/systemd-run");
pub const journalctl_shim = @embedFile("../test/shims/journalctl");
pub const curl_shim = @embedFile("../test/shims/curl");
pub const pesque_shim = @embedFile("../test/shims/pesque");

pub const Ctx = struct {
    arena_state: *std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    host: *proc.Host,
    env: *std.process.Environ.Map,
    log_path: []const u8,
    tmp_path: []const u8,

    const Shim = struct { name: []const u8, body: []const u8 };

    pub fn init() !Ctx {
        const gpa = testing.allocator;
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        const arena = arena_state.allocator();

        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const tmp_rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
        const tmp_path = Io.Dir.cwd().realPathFileAlloc(testing.io, tmp_rel, arena) catch unreachable;

        const env = try arena.create(std.process.Environ.Map);
        env.* = std.process.Environ.Map.init(arena);
        // Tests never want real backend detection to succeed by accident.
        try env.put("PESQUE_BACKEND", "compose");

        const bin_dir = try std.fs.path.join(arena, &.{ tmp_path, "bin" });
        try Io.Dir.cwd().createDirPath(testing.io, bin_dir);
        const log_path = try std.fs.path.join(arena, &.{ tmp_path, "invocations.log" });
        const shim_files = [_]Shim{
            .{ .name = "docker", .body = docker_shim },
            .{ .name = "systemctl", .body = systemctl_shim },
            .{ .name = "systemd-run", .body = systemd_run_shim },
            .{ .name = "journalctl", .body = journalctl_shim },
            .{ .name = "curl", .body = curl_shim },
            .{ .name = "pesque", .body = pesque_shim },
        };
        for (shim_files) |shim| {
            const p = try std.fs.path.join(arena, &.{ bin_dir, shim.name });
            try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = shim.body });
            try Io.Dir.cwd().setFilePermissions(testing.io, p, .fromMode(0o755), .{});
        }
        try env.put("PESQUE_FAKE_LOG", log_path);

        const host = try arena.create(proc.Host);
        host.* = .{
            .gpa = arena,
            .io = testing.io,
            .environ = env,
            .progs = .{
                .docker = try std.fs.path.join(arena, &.{ bin_dir, "docker" }),
                .systemctl = try std.fs.path.join(arena, &.{ bin_dir, "systemctl" }),
                .systemd_run = try std.fs.path.join(arena, &.{ bin_dir, "systemd-run" }),
                .journalctl = try std.fs.path.join(arena, &.{ bin_dir, "journalctl" }),
                .curl = try std.fs.path.join(arena, &.{ bin_dir, "curl" }),
            },
            // Keep printed output off the build runner's protocol stream.
            .stdout_to_stderr = true,
        };
        // Deterministic regardless of the harness.
        proc.Host.stdin_tty_override = false;
        proc.Host.root_override = null;
        return .{
            .arena_state = arena_state,
            .tmp = tmp,
            .host = host,
            .env = env,
            .log_path = log_path,
            .tmp_path = tmp_path,
        };
    }

    pub fn deinit(self: *Ctx) void {
        proc.Host.stdin_tty_override = null;
        proc.Host.root_override = null;
        self.tmp.cleanup();
        const gpa = self.arena_state.child_allocator;
        self.arena_state.deinit();
        gpa.destroy(self.arena_state);
    }

    /// The absolute path of a shim binary, e.g. to point a driver at it.
    pub fn shimPath(self: *Ctx, name: []const u8) []const u8 {
        return std.fs.path.join(self.arena_state.allocator(), &.{ self.tmp_path, "bin", name }) catch unreachable;
    }

    /// Lay out a fake release tree at `<tmp>/opt/pesque` with the fake
    /// `bin/pesque` shim, for the systemd non-root direct-exec path.
    pub fn makeRelease(self: *Ctx) ![]const u8 {
        const release = try std.fs.path.join(self.arena_state.allocator(), &.{ self.tmp_path, "opt", "pesque" });
        const bin_dir = try std.fs.path.join(self.arena_state.allocator(), &.{ release, "bin" });
        try Io.Dir.cwd().createDirPath(testing.io, bin_dir);
        const p = try std.fs.path.join(self.arena_state.allocator(), &.{ bin_dir, "pesque" });
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = pesque_shim });
        try Io.Dir.cwd().setFilePermissions(testing.io, p, .fromMode(0o755), .{});
        return release;
    }

    /// All logged invocations, innermost-last. Each invocation is a slice of
    /// argv strings; invocations are separated by the shim's empty line.
    pub fn invocations(self: *Ctx) ![][]const []const u8 {
        const content = Io.Dir.cwd().readFileAlloc(testing.io, self.log_path, self.arena_state.allocator(), .limited(1 << 20)) catch
            return error.TestUnexpectedResult;
        var invocations_list: std.ArrayList([]const []const u8) = .empty;
        var current: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) {
                if (current.items.len > 0) {
                    try invocations_list.append(self.arena_state.allocator(), try current.toOwnedSlice(self.arena_state.allocator()));
                }
                continue;
            }
            try current.append(self.arena_state.allocator(), line);
        }
        if (current.items.len > 0) {
            try invocations_list.append(self.arena_state.allocator(), try current.toOwnedSlice(self.arena_state.allocator()));
        }
        return invocations_list.toOwnedSlice(self.arena_state.allocator());
    }

    /// The last logged invocation (the run itself, not a preceding inspect).
    pub fn lastInvocation(self: *Ctx) ![]const []const u8 {
        const all = try self.invocations();
        try testing.expect(all.len > 0);
        return all[all.len - 1];
    }

    pub fn expectArg(inv: []const []const u8, arg: []const u8) !void {
        for (inv) |a| {
            if (std.mem.eql(u8, a, arg)) return;
        }
        std.debug.print("expected argument {s} in:\n", .{arg});
        for (inv) |a| std.debug.print("  {s}\n", .{a});
        return error.TestUnexpectedResult;
    }

    pub fn expectNoArg(inv: []const []const u8, arg: []const u8) !void {
        for (inv) |a| {
            if (std.mem.eql(u8, a, arg)) {
                std.debug.print("did not expect argument {s} in:\n", .{arg});
                for (inv) |a2| std.debug.print("  {s}\n", .{a2});
                return error.TestUnexpectedResult;
            }
        }
    }

    /// The invocation's argv ends with `seq` (the release command tail).
    pub fn expectTail(inv: []const []const u8, seq: []const []const u8) !void {
        try testing.expect(inv.len >= seq.len);
        if (inv.len < seq.len) return error.TestUnexpectedResult;
        const start = inv.len - seq.len;
        for (seq, 0..) |s, i| {
            if (!std.mem.eql(u8, inv[start + i], s)) {
                std.debug.print("expected tail element {s} at position {d}\n", .{ s, i });
                for (inv) |a| std.debug.print("  {s}\n", .{a});
                return error.TestUnexpectedResult;
            }
        }
    }
};

/// A compose-style project directory (docker-compose.yml present).
pub fn makeProjectDir(self: *Ctx, sub: []const u8) ![]const u8 {
    const dir = try std.fs.path.join(self.arena_state.allocator(), &.{ self.tmp_path, sub });
    try Io.Dir.cwd().createDirPath(testing.io, dir);
    const marker = try std.fs.path.join(self.arena_state.allocator(), &.{ dir, "docker-compose.yml" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = marker, .data = "services: {}\n" });
    return dir;
}

test "ctx builds and logs" {
    var ctx = try Ctx.init();
    defer ctx.deinit();
    try ctx.env.put("PESQUE_FAKE_EXIT", "0");
    const code = try ctx.host.run(&.{ ctx.host.progs.docker, "compose", "version" });
    try testing.expectEqual(@as(u8, 0), code);
    const invs = try ctx.invocations();
    try testing.expectEqual(@as(usize, 1), invs.len);
    try Ctx.expectArg(invs[0], "compose");
}
