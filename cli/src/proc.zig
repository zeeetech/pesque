//! Process helpers: child spawning (argv arrays, never `sh -c`), environment
//! handling, and the CLI's output conventions.
//!
//! Exit-code discipline: a child's exit code propagates; death by signal maps
//! to 1; failure to spawn maps to 3 (driver/environment failure), after
//! printing an `error:` line with a fix.
const std = @import("std");
const Io = std.Io;

/// One entry of `RunOnce.env`. `value == null` means bare passthrough: the
/// value must already be present in this process's environment, and the driver
/// passes only the key on the command line (`-e KEY`), so it never shows in
/// `ps`. A non-null value (a prompted secret) is injected into the child
/// environment; the command line still carries only the bare key.
pub const Env = struct {
    key: []const u8,
    value: ?[]const u8 = null,
};

pub const Mount = struct {
    source: []const u8,
    target: []const u8,
};

/// Programs the drivers shell out to. Tests point these at fake binaries
/// instead of manipulating PATH.
pub const Progs = struct {
    docker: []const u8 = "docker",
    systemctl: []const u8 = "systemctl",
    systemd_run: []const u8 = "systemd-run",
    journalctl: []const u8 = "journalctl",
    curl: []const u8 = "curl",
    git: []const u8 = "git",
};

/// Everything the drivers need to spawn children and print.
pub const Host = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    progs: Progs = .{},
    /// Under `zig build test` the test binary's stdout is the build runner's
    /// protocol stream, so tests set this to keep their printed output off it.
    stdout_to_stderr: bool = false,

    pub fn get(self: *Host, key: []const u8) ?[]const u8 {
        return self.environ.get(key);
    }

    /// Overridden in tests to pin both tty branches.
    pub var stdin_tty_override: ?bool = null;

    /// Overridden in tests to exercise both systemd run_once paths (root
    /// via systemd-run, non-root direct exec).
    pub var root_override: ?bool = null;

    /// Base directory for the systemd run_once env mirror. Null means
    /// /run on Linux (the one tree the systemd manager sees even under
    /// PrivateTmp); tests point this at their sandbox.
    pub var run_once_base: ?[]const u8 = null;

    pub fn stdinIsTty(self: *Host) bool {
        if (stdin_tty_override) |t| return t;
        return Io.File.stdin().isTty(self.io) catch false;
    }

    // --- output conventions -------------------------------------------------

    /// `==> step` (stdout). Blank line before.
    pub fn step(self: *Host, comptime fmt: []const u8, args: anytype) void {
        self.printTo(.stdout, "\n==> " ++ fmt ++ "\n", args);
    }

    /// `note: <nonfatal>` (stdout).
    pub fn note(self: *Host, comptime fmt: []const u8, args: anytype) void {
        self.printTo(.stdout, "note: " ++ fmt ++ "\n", args);
    }

    /// `error: <what + fix>` (stderr).
    pub fn err(self: *Host, comptime fmt: []const u8, args: anytype) void {
        self.printTo(.stderr, "error: " ++ fmt ++ "\n", args);
    }

    /// Plain stdout line.
    pub fn out(self: *Host, comptime fmt: []const u8, args: anytype) void {
        self.printTo(.stdout, fmt ++ "\n", args);
    }

    pub const Stream = enum { stdout, stderr };

    pub fn printTo(self: *Host, which: Stream, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
        defer self.gpa.free(text);
        const file: Io.File = switch (which) {
            .stdout => if (self.stdout_to_stderr) .stderr() else .stdout(),
            .stderr => .stderr(),
        };
        file.writeStreamingAll(self.io, text) catch {};
    }

    // --- environment --------------------------------------------------------

    /// Resolve `RunOnce.env` before spawning: bare entries must already be
    /// present (they are passed as `-e KEY` only); valued entries are injected
    /// into this process's environment so the child runtime picks them up.
    pub fn resolveEnv(self: *Host, envs: []const Env) Error!void {
        for (envs) |e| {
            if (e.value) |v| {
                const key = self.gpa.dupe(u8, e.key) catch return error.OutOfMemory;
                const value = self.gpa.dupe(u8, v) catch return error.OutOfMemory;
                self.environ.put(key, value) catch return error.OutOfMemory;
                continue;
            }
            if (self.environ.get(e.key) == null) {
                self.err("{s} is not set. Set it in the environment, then run this again.", .{e.key});
                return error.MissingEnv;
            }
        }
    }

    // --- spawning -----------------------------------------------------------

    /// Run a child with all three stdio inherited. Returns the child's exit
    /// code; death by signal maps to 1; spawn failure maps to 3.
    pub fn run(self: *Host, argv: []const []const u8) Error!u8 {
        var child = self.spawn(argv) catch |e| return e;
        const term = child.wait(self.io) catch return error.DriverFailed;
        return termToExit(term);
    }

    /// Run a child capturing stdout/stderr (stdin ignored). Caller frees the
    /// capture with `freeCapture`.
    pub fn capture(self: *Host, argv: []const []const u8) Error!Capture {
        const res = std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .environ_map = self.environ,
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return error.DriverFailed,
            else => return self.spawnFail(argv, e),
        };
        return .{ .argv = argv, .term = res.term, .stdout = res.stdout, .stderr = res.stderr };
    }

    pub fn freeCapture(self: *Host, c: Capture) void {
        self.gpa.free(c.stdout);
        self.gpa.free(c.stderr);
    }

    pub const Capture = struct {
        argv: []const []const u8,
        term: std.process.Child.Term,
        stdout: []u8,
        stderr: []u8,

        pub fn ok(self: Capture) bool {
            return self.term == .exited and self.term.exited == 0;
        }

        /// Trimmed stdout (one-line outputs like container ids or statuses).
        pub fn line(self: Capture) []const u8 {
            return std.mem.trim(u8, self.stdout, " \t\r\n");
        }
    };

    fn spawn(self: *Host, argv: []const []const u8) Error!std.process.Child {
        return std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = self.environ,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |e| return self.spawnFail(argv, e);
    }

    /// Spawn failure is a driver/environment failure (3). Print what + fix.
    fn spawnFail(self: *Host, argv: []const []const u8, e: anyerror) Error {
        const prog = std.fs.path.basename(argv[0]);
        const reason = switch (e) {
            error.FileNotFound => "not found",
            error.AccessDenied, error.PermissionDenied => "not executable (permission denied)",
            error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "system resources exhausted",
            error.OutOfMemory => return error.OutOfMemory,
            else => "unexpected error",
        };
        self.err("cannot run '{s}': {s}.", .{ prog, reason });
        if (fixFor(prog)) |fix| self.printTo(.stderr, "  {s}\n", .{fix});
        return error.DriverFailed;
    }

    /// Build a private temp directory (mode 0700 on POSIX) for files like the
    /// docker `--env-file` mirror. Caller removes it with `removeTempDir`.
    pub fn makeTempDir(self: *Host) Error![]const u8 {
        const base = self.get("TMPDIR") orelse self.get("TEMP") orelse switch (@import("builtin").os.tag) {
            .windows => "C:\\Windows\\Temp",
            else => "/tmp",
        };
        return self.makeTempDirUnder(base, "");
    }

    /// Same, under an explicit base with a name prefix. The systemd driver
    /// uses /run (same tree for this process and the systemd manager, even
    /// under PrivateTmp) with a recognizable prefix.
    pub fn makeTempDirUnder(self: *Host, base: []const u8, prefix: []const u8) Error![]const u8 {
        var raw: [8]u8 = undefined;
        self.io.random(&raw);
        var name_buf: [40]u8 = undefined;
        @memcpy(name_buf[0..prefix.len], prefix);
        const hex_chars = "0123456789abcdef";
        var name_len: usize = prefix.len;
        for (raw) |byte| {
            name_buf[name_len] = hex_chars[byte >> 4];
            name_buf[name_len + 1] = hex_chars[byte & 0xf];
            name_len += 2;
        }
        const name = name_buf[0..name_len];
        const path = std.fs.path.join(self.gpa, &.{ base, name }) catch return error.OutOfMemory;
        const private: Io.File.Permissions = if (@import("builtin").os.tag == .windows)
            .default_dir
        else
            .fromMode(0o700);
        Io.Dir.cwd().createDir(self.io, path, private) catch {
            self.gpa.free(path);
            return error.DriverFailed;
        };
        return path;
    }

    pub fn removeTempDir(self: *Host, path: []const u8) void {
        Io.Dir.cwd().deleteTree(self.io, path) catch {};
        self.gpa.free(path);
    }
};

fn termToExit(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        // Killed by a signal (or stopped): treat as a failed run, not as a
        // driver/environment failure.
        .signal, .stopped => 1,
        .unknown => 1,
    };
}

fn fixFor(prog: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prog, "docker")) {
        return "Install Docker Engine (Linux) or Docker Desktop (macOS/Windows), then run this again.";
    }
    if (std.mem.eql(u8, prog, "systemctl") or std.mem.eql(u8, prog, "systemd-run") or std.mem.eql(u8, prog, "journalctl")) {
        return "This command drives a systemd service and needs a Linux host with systemd. Use the compose or docker backend here.";
    }
    if (std.mem.eql(u8, prog, "curl")) {
        return "Install curl (https://curl.se), then run this again.";
    }
    if (std.mem.eql(u8, prog, "git")) {
        return "Install git (https://git-scm.com), then run this again.";
    }
    return null;
}

pub const Error = error{
    DriverFailed,
    MissingEnv,
    NotATty,
    OutOfMemory,
    Usage,
};
