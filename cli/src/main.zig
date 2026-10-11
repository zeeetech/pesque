//! pesque — host-side CLI for operating a Pesque (ATProto PDS) server.
//!
//! Layer B of the unified operations API: a thin, static transport that
//! dispatches driver verbs directly and forwards domain verbs to the release
//! via `driver.run_once` -> `/app/bin/pesque <verb> <argv>`. The release is
//! the single source of truth; this binary reimplements no domain logic
//! (spec D4: it parses nothing from verb stdout, only exit codes).
//!
//! Frozen exit codes: 0 ok, 1 domain failure, 2 usage, 3 driver/environment.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const proc = @import("proc.zig");
const driver = @import("driver.zig");
const detect = @import("detect.zig");
const prompt = @import("prompt.zig");
const fetch = @import("fetch.zig");

const Error = proc.Error;

const usage_text =
    \\usage: pesque [--backend compose|docker|systemd|nixos] [--yes] <command> [args...]
    \\
    \\Server lifecycle (driver verbs):
    \\  setup                      guided install (compose and docker backends)
    \\  up | down | restart        start, stop (data is kept), restart
    \\  update [tag]               pull + restart (no-op on nixos)
    \\  logs [-f] [--tail N]       follow or show the server logs
    \\  health                     container/service health
    \\  backend                    print the detected backend, capabilities, paths
    \\  version                    print the CLI and release versions
    \\
    \\Accounts and domain tasks (run inside the release):
    \\  account create --handle H --email E [--password-env VAR]
    \\  account list
    \\  account delete --did D | --handle H
    \\  account takedown --did D | --handle H      (deactivate)
    \\  account activate --did D | --handle H
    \\  account reset-password --did D | --handle H
    \\  invite create [--count N] [--uses N] [--for DID]
    \\  migrate --old-pds URL --handle H --email E [--plc-token T]
    \\  doctor                     run the federation preflight
    \\  backup [--out DIR]         live-safe backup (VACUUM INTO + blobs)
    \\  restore <archive.tar.gz>   cold restore (stops the service)
    \\  config validate | config template [--out PATH]
    \\  crawl request              ask the relay to crawl this server
    \\
    \\Passwords never take a --password VALUE flag: use --password-env VAR, the
    \\ACCOUNT_PASSWORD/MIGRATE_PASSWORD environment, or a no-echo prompt.
    \\
    \\Environment: PESQUE_BACKEND PESQUE_ROOT PESQUE_CONTAINER PESQUE_IMAGE
    \\  PESQUE_TAG PESQUE_BUILD PESQUE_RESTART_CMD PESQUE_SERVICE PESQUE_RELEASE
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var host = proc.Host{
        .gpa = init.arena.allocator(),
        .io = init.io,
        .environ = init.environ_map,
    };
    // toSlice includes argv[0] (the program path); everything after is ours.
    const user_args = if (args.len > 0) args[1..] else args;
    const code = run(&host, user_args) catch |e| mapError(e);
    std.process.exit(code);
}

/// Frozen exit codes (D4): 0 ok, 1 domain failure (propagated child code),
/// 2 usage/input, 3 driver/environment.
fn mapError(e: anyerror) u8 {
    return switch (e) {
        error.Usage, error.NotATty => 2,
        else => 3,
    };
}

/// Parse global flags, then dispatch. Everything after the command word
/// belongs to the command.
pub fn run(host: *proc.Host, args: []const []const u8) Error!u8 {
    var i: usize = 0;
    backend_flag = null;
    var yes = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(host);
            return 0;
        } else if (std.mem.eql(u8, arg, "--yes")) {
            yes = true;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i >= args.len) return usage(host, "--backend needs a value: compose, docker, systemd or nixos", .{});
            backend_flag = detect.parseKind(args[i]) orelse
                return usage(host, "unknown backend '{s}'. Use compose, docker, systemd or nixos", .{args[i]});
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            const value = arg["--backend=".len..];
            backend_flag = detect.parseKind(value) orelse
                return usage(host, "unknown backend '{s}'. Use compose, docker, systemd or nixos", .{value});
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return usage(host, "unknown global flag '{s}'", .{arg});
        } else {
            break;
        }
    }
    const rest = args[i..];
    if (rest.len == 0) {
        printUsage(host);
        return error.Usage;
    }
    return dispatch(host, yes, rest);
}

fn usage(host: *proc.Host, comptime fmt: []const u8, args: anytype) Error!u8 {
    host.err(fmt, args);
    host.printTo(.stderr, "run 'pesque --help' for the command list.\n", .{});
    return error.Usage;
}

/// For fns whose payload is not u8: same message, same exit code.
fn failUsage(host: *proc.Host, comptime fmt: []const u8, args: anytype) Error {
    _ = usage(host, fmt, args) catch {};
    return error.Usage;
}

fn printUsage(host: *proc.Host) void {
    host.printTo(.stdout, usage_text, .{});
}

// --- command table -----------------------------------------------------------

/// The parsed `--backend` global flag (or null to detect). File-scoped: one
/// command runs per process.
var backend_flag: ?driver.Kind = null;

/// Every verb resolves the backend through here, so `--backend` (and the
/// PESQUE_BACKEND env it mirrors) applies uniformly.
fn detectBackend(host: *proc.Host) Error!driver.Driver {
    return detect.detect(host, backend_flag);
}

fn dispatch(host: *proc.Host, yes: bool, cmd: []const []const u8) Error!u8 {
    const name = cmd[0];
    const rest = cmd[1..];
    if (std.mem.eql(u8, name, "setup")) return setup(host, yes, rest);
    if (std.mem.eql(u8, name, "up")) return lifecycle(host, .up, rest);
    if (std.mem.eql(u8, name, "down")) return lifecycle(host, .down, rest);
    if (std.mem.eql(u8, name, "restart")) return lifecycle(host, .restart, rest);
    if (std.mem.eql(u8, name, "update")) return update(host, rest);
    if (std.mem.eql(u8, name, "logs")) return logs(host, rest);
    if (std.mem.eql(u8, name, "health")) return health(host, rest);
    if (std.mem.eql(u8, name, "backend")) return backendCmd(host, rest);
    if (std.mem.eql(u8, name, "version")) return version(host, rest);
    if (std.mem.eql(u8, name, "help")) {
        printUsage(host);
        return 0;
    }
    // Domain verbs: the release owns the logic; the CLI resolves password
    // inputs and forwards everything through run_once.
    if (std.mem.eql(u8, name, "account")) return account(host, rest);
    if (std.mem.eql(u8, name, "invite")) return invite(host, rest);
    if (std.mem.eql(u8, name, "migrate")) return migrate(host, rest);
    if (std.mem.eql(u8, name, "doctor")) return simpleVerb(host, "doctor", rest);
    if (std.mem.eql(u8, name, "backup")) return backup(host, rest);
    if (std.mem.eql(u8, name, "restore")) return restore(host, rest);
    if (std.mem.eql(u8, name, "config")) return configVerb(host, rest);
    if (std.mem.eql(u8, name, "crawl")) return crawl(host, rest);
    _ = try usage(host, "unknown command '{s}'", .{name});
    return error.Usage;
}

fn noSubArgs(host: *proc.Host, args: []const []const u8, what: []const u8) Error!void {
    if (args.len > 0) {
        host.err("'{s}' takes no arguments (got '{s}').", .{ what, args[0] });
        return error.Usage;
    }
}

// --- driver verbs -------------------------------------------------------------

const Lifecycle = enum { up, down, restart };

fn lifecycle(host: *proc.Host, which: Lifecycle, args: []const []const u8) Error!u8 {
    const what = @tagName(which);
    if (args.len > 0) {
        host.err("'{s}' takes no arguments (got '{s}').", .{ what, args[0] });
        return error.Usage;
    }
    const d = try detectBackend(host);
    return switch (which) {
        .up => d.up(host),
        .down => d.down(host),
        .restart => d.restart(host),
    };
}

fn update(host: *proc.Host, args: []const []const u8) Error!u8 {
    const tag: ?[]const u8 = if (args.len > 0) args[0] else null;
    if (args.len > 1) {
        host.err("'update' takes at most one argument (the tag), got {d}.", .{args.len});
        return error.Usage;
    }
    const d = try detectBackend(host);
    return d.update(host, tag);
}

fn logs(host: *proc.Host, args: []const []const u8) Error!u8 {
    var opts: driver.LogOpts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-f")) {
            opts.follow = true;
        } else if (std.mem.eql(u8, args[i], "--tail")) {
            i += 1;
            if (i >= args.len) return usage(host, "--tail needs a number", .{});
            opts.tail = std.fmt.parseInt(u64, args[i], 10) catch
                return usage(host, "--tail needs a number, got '{s}'", .{args[i]});
        } else {
            return usage(host, "unknown option '{s}' for 'logs'", .{args[i]});
        }
    }
    const d = try detectBackend(host);
    return d.logs(host, opts);
}

fn health(host: *proc.Host, args: []const []const u8) Error!u8 {
    try noSubArgs(host, args, "health");
    const d = try detectBackend(host);
    const h = try d.health(host);
    switch (h) {
        .healthy => host.out("healthy", .{}),
        .degraded => {
            host.out("degraded", .{});
            return 1;
        },
    }
    return 0;
}

fn backendCmd(host: *proc.Host, args: []const []const u8) Error!u8 {
    try noSubArgs(host, args, "backend");
    const d = try detectBackend(host);
    return detect.printReport(host, d);
}

fn version(host: *proc.Host, args: []const []const u8) Error!u8 {
    try noSubArgs(host, args, "version");
    host.out("pesque-cli {s}", .{build_options.cli_version});
    // The release's stock `version` command boots no VM (instant).
    const d = detectBackend(host) catch |e| {
        host.note("the release version is unavailable: no backend detected.", .{});
        return e;
    };
    return d.runOnce(host, .{ .verb = "version" });
}

// --- domain verbs ---------------------------------------------------------------

/// Resolve the password for a verb: `--password-env VAR` -> the conventional
/// env var -> no-echo prompt -> refuse (D3). Returns the RunOnce env entry.
fn passwordInput(host: *proc.Host, pw_env_flag: ?[]const u8, conventional: []const u8, prompt_text: []const u8) Error!proc.Env {
    if (pw_env_flag) |var_name| {
        const value = host.get(var_name) orelse
            return failInput(host, "the password variable {s} (from --password-env) is not set.", .{var_name});
        return .{ .key = conventional, .value = value };
    }
    // An empty conventional var counts as unset.
    if (host.get(conventional)) |existing| {
        if (existing.len > 0) {
            // Already in the environment: bare passthrough, value never on argv.
            return .{ .key = conventional };
        }
    }
    const value = prompt.secret(host, prompt_text) catch |e| switch (e) {
        error.NotATty => return failInput(host, "no password source: pass --password-env VAR, set {s} in the environment, or run from a terminal to be prompted.", .{conventional}),
        else => return e,
    };
    if (value.len == 0) {
        return failInput(host, "the password cannot be empty.", .{});
    }
    return .{ .key = conventional, .value = value };
}

fn failInput(host: *proc.Host, comptime fmt: []const u8, args: anytype) Error {
    host.err(fmt, args);
    return error.Usage;
}

fn account(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len == 0) return usage(host, "'account' needs a subcommand: create, list, delete, takedown, activate or reset-password", .{});
    const sub = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, sub, "list")) {
        return simpleVerbNamed(host, "account", "list", rest);
    }
    if (std.mem.eql(u8, sub, "create")) {
        const f = try parseAccountCreate(host, rest);
        return runAccountCreate(host, f);
    }
    if (std.mem.eql(u8, sub, "delete") or std.mem.eql(u8, sub, "takedown") or
        std.mem.eql(u8, sub, "activate") or std.mem.eql(u8, sub, "reset-password"))
    {
        const sel = try parseSelector(host, rest);
        var env: std.ArrayList(proc.Env) = .empty;
        defer env.deinit(host.gpa);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(host.gpa);
        try argv.appendSlice(host.gpa, &.{ sub, sel.flag, sel.value });
        // delete and reset-password authorize with the account's password.
        if (!std.mem.eql(u8, sub, "takedown") and !std.mem.eql(u8, sub, "activate")) {
            try env.append(host.gpa, try passwordInput(host, sel.password_env, "ACCOUNT_PASSWORD", "Account password (not shown): "));
        }
        return runDomain(host, "account", argv.items, env.items);
    }
    return usage(host, "unknown account subcommand '{s}'", .{sub});
}

const AccountCreate = struct {
    handle: ?[]const u8 = null,
    email: ?[]const u8 = null,
    password: proc.Env = undefined,
    public_ip: ?[]const u8 = null,
};

fn parseAccountCreate(host: *proc.Host, args: []const []const u8) Error!AccountCreate {
    var f = AccountCreate{};
    var pw_env: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--handle")) {
            f.handle = try valueFlag(host, args, &i, "--handle");
        } else if (std.mem.eql(u8, args[i], "--email")) {
            f.email = try valueFlag(host, args, &i, "--email");
        } else if (std.mem.eql(u8, args[i], "--password-env")) {
            pw_env = try valueFlag(host, args, &i, "--password-env");
        } else {
            return failUsage(host, "unknown option '{s}' for 'account create'", .{args[i]});
        }
    }
    if (f.handle == null and host.get("ACCOUNT_HANDLE") == null) {
        return failInput(host, "account create needs --handle H (or ACCOUNT_HANDLE in the environment).", .{});
    }
    if (f.email == null and host.get("ACCOUNT_EMAIL") == null) {
        return failInput(host, "account create needs --email E (or ACCOUNT_EMAIL in the environment).", .{});
    }
    f.password = try passwordInput(host, pw_env, "ACCOUNT_PASSWORD", "Password for the new account (at least 8 characters, not shown): ");
    if (host.get("PDS_PUBLIC_IP") != null) f.public_ip = "PDS_PUBLIC_IP";
    return f;
}

/// Run the `account create` domain verb.
fn runAccountCreate(host: *proc.Host, f: AccountCreate) Error!u8 {
    const d = try detectBackend(host);
    var env: std.ArrayList(proc.Env) = .empty;
    defer env.deinit(host.gpa);
    try env.append(host.gpa, f.password);
    if (f.public_ip != null) {
        try env.append(host.gpa, .{ .key = "PDS_PUBLIC_IP" });
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{"create"});
    if (f.handle) |h| try argv.appendSlice(host.gpa, &.{ "--handle", h });
    if (f.email) |e| try argv.appendSlice(host.gpa, &.{ "--email", e });
    return d.runOnce(host, .{ .verb = "account", .argv = argv.items, .env = env.items, .interactive = true });
}

const Selector = struct {
    flag: []const u8,
    value: []const u8,
    password_env: ?[]const u8 = null,
};

/// `--did D` XOR `--handle H`, with an optional `--password-env VAR`.
fn parseSelector(host: *proc.Host, args: []const []const u8) Error!Selector {
    var did: ?[]const u8 = null;
    var handle: ?[]const u8 = null;
    var password_env: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--did")) {
            did = try valueFlag(host, args, &i, "--did");
        } else if (std.mem.eql(u8, args[i], "--handle")) {
            handle = try valueFlag(host, args, &i, "--handle");
        } else if (std.mem.eql(u8, args[i], "--password-env")) {
            password_env = try valueFlag(host, args, &i, "--password-env");
        } else {
            return failUsage(host, "unknown option '{s}' (use --did D or --handle H)", .{args[i]});
        }
    }
    if ((did == null) == (handle == null)) {
        return failInput(host, "pick exactly one: --did D or --handle H.", .{});
    }
    if (did) |d| return .{ .flag = "--did", .value = d, .password_env = password_env };
    return .{ .flag = "--handle", .value = handle.?, .password_env = password_env };
}

fn valueFlag(host: *proc.Host, args: []const []const u8, i: *usize, name: []const u8) Error![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return failUsage(host, "{s} needs a value", .{name});
    return args[i.*];
}

/// Run a domain verb that is a plain passthrough (no inputs to resolve).
fn simpleVerb(host: *proc.Host, verb: []const u8, args: []const []const u8) Error!u8 {
    try noSubArgs(host, args, verb);
    return runDomain(host, verb, &.{}, &.{});
}

fn simpleVerbNamed(host: *proc.Host, verb: []const u8, sub: []const u8, args: []const []const u8) Error!u8 {
    try noSubArgs(host, args, sub);
    return runDomain(host, verb, &.{sub}, &.{});
}

/// Detect the backend and dispatch `bin/pesque <verb> <argv>` through run_once.
fn runDomain(host: *proc.Host, verb: []const u8, argv: []const []const u8, env: []const proc.Env) Error!u8 {
    const d = try detectBackend(host);
    return d.runOnce(host, .{ .verb = verb, .argv = argv, .env = env, .interactive = true });
}

fn invite(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "create")) {
        return usage(host, "'invite' only knows 'create'", .{});
    }
    var count: ?[]const u8 = null;
    var uses: ?[]const u8 = null;
    var for_did: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--count")) {
            count = try valueFlag(host, args, &i, "--count");
        } else if (std.mem.eql(u8, args[i], "--uses")) {
            uses = try valueFlag(host, args, &i, "--uses");
        } else if (std.mem.eql(u8, args[i], "--for")) {
            for_did = try valueFlag(host, args, &i, "--for");
        } else {
            return usage(host, "unknown option '{s}' for 'invite create'", .{args[i]});
        }
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{"create"});
    if (count) |c| try argv.appendSlice(host.gpa, &.{ "--count", c });
    if (uses) |u| try argv.appendSlice(host.gpa, &.{ "--uses", u });
    if (for_did) |f| try argv.appendSlice(host.gpa, &.{ "--for", f });
    // The verb also reads INVITE_COUNT/INVITE_USES; forward them when set.
    var env: std.ArrayList(proc.Env) = .empty;
    defer env.deinit(host.gpa);
    for ([_][]const u8{ "INVITE_COUNT", "INVITE_USES" }) |key| {
        if (host.get(key) != null) try env.append(host.gpa, .{ .key = key });
    }
    return runDomain(host, "invite", argv.items, env.items);
}

fn migrate(host: *proc.Host, args: []const []const u8) Error!u8 {
    var old_pds: ?[]const u8 = null;
    var handle: ?[]const u8 = null;
    var email: ?[]const u8 = null;
    var plc_token: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--old-pds")) {
            old_pds = try valueFlag(host, args, &i, "--old-pds");
        } else if (std.mem.eql(u8, args[i], "--handle")) {
            handle = try valueFlag(host, args, &i, "--handle");
        } else if (std.mem.eql(u8, args[i], "--email")) {
            email = try valueFlag(host, args, &i, "--email");
        } else if (std.mem.eql(u8, args[i], "--plc-token")) {
            plc_token = try valueFlag(host, args, &i, "--plc-token");
        } else {
            return usage(host, "unknown option '{s}' for 'migrate'", .{args[i]});
        }
    }
    if (old_pds == null) return failInput(host, "migrate needs --old-pds URL.", .{});
    if (handle == null) return failInput(host, "migrate needs --handle H.", .{});
    if (email == null) return failInput(host, "migrate needs --email E.", .{});

    const password = try passwordInput(host, null, "MIGRATE_PASSWORD", "Password for the account (not shown): ");
    var env: std.ArrayList(proc.Env) = .empty;
    defer env.deinit(host.gpa);
    try env.append(host.gpa, password);
    if (plc_token == null and host.get("MIGRATE_PLC_TOKEN") != null) {
        try env.append(host.gpa, .{ .key = "MIGRATE_PLC_TOKEN" });
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{ "--old-pds", old_pds.?, "--handle", handle.?, "--email", email.? });
    if (plc_token) |t| try argv.appendSlice(host.gpa, &.{ "--plc-token", t });
    return runDomain(host, "migrate", argv.items, env.items);
}

/// Resolve a host path to an absolute one for same-path mounts.
fn absPath(host: *proc.Host, path: []const u8) Error![]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(host.io, path, host.gpa) catch {
        host.err("path '{s}' does not exist (or is not accessible).", .{path});
        return error.DriverFailed;
    };
}

fn backup(host: *proc.Host, args: []const []const u8) Error!u8 {
    var out_dir: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            out_dir = try valueFlag(host, args, &i, "--out");
        } else {
            return usage(host, "unknown option '{s}' for 'backup'", .{args[i]});
        }
    }
    const given = out_dir orelse ".";
    const abs = try absPath(host, given);
    const d = try detectBackend(host);
    // The archive is written through a same-path mount, so the file lands on
    // the host exactly where the verb says it does.
    return d.runOnce(host, .{
        .verb = "backup",
        .argv = &.{ "--out", abs },
        .mounts = &.{.{ .source = abs, .target = abs }},
        .interactive = true,
    });
}

fn restore(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len != 1) return usage(host, "restore takes the archive path: pesque restore <archive.tar.gz>", .{});
    const abs = try absPath(host, args[0]);
    const d = try detectBackend(host);
    // Restore is cold (D5): stop the service first when the CLI owns the
    // lifecycle; the verb refuses a locked db as a second line of defense.
    var stopped = false;
    if (d.ownsLifecycle()) {
        _ = try d.down(host);
        stopped = true;
    } else {
        host.note("the service is not managed by this CLI: if the archive restore refuses a locked database, stop the container and run this again.", .{});
    }
    const code = try d.runOnce(host, .{
        .verb = "restore",
        .argv = &.{abs},
        .mounts = &.{.{ .source = abs, .target = abs }},
        .interactive = true,
    });
    // The server comes back even when the restore itself failed.
    if (stopped) {
        _ = d.up(host) catch 3;
    }
    return code;
}

fn configVerb(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len == 0) return usage(host, "'config' needs a subcommand: validate or template", .{});
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "validate")) {
        return simpleVerbNamed(host, "config", "validate", rest);
    }
    if (std.mem.eql(u8, sub, "template")) {
        var out_path: ?[]const u8 = null;
        var i: usize = 0;
        while (i < rest.len) : (i += 1) {
            if (std.mem.eql(u8, rest[i], "--out")) {
                out_path = try valueFlag(host, rest, &i, "--out");
            } else {
                return usage(host, "unknown option '{s}' for 'config template'", .{rest[i]});
            }
        }
        const path = out_path orelse return runDomain(host, "config", &.{"template"}, &.{});
        const abs = try absPath(host, path);
        // The template is written through a same-path mount of its parent dir.
        const parent = std.fs.path.dirname(abs) orelse ".";
        return runDomainWith(host, "config", &.{ "template", "--out", abs }, &.{}, &.{.{ .source = parent, .target = parent }});
    }
    return usage(host, "unknown config subcommand '{s}'", .{sub});
}

fn crawl(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "request")) {
        return usage(host, "'crawl' only knows 'request'", .{});
    }
    return simpleVerbNamed(host, "crawl", "request", args[1..]);
}

fn runDomainWith(host: *proc.Host, verb: []const u8, argv: []const []const u8, env: []const proc.Env, mounts: []const proc.Mount) Error!u8 {
    const d = try detectBackend(host);
    return d.runOnce(host, .{ .verb = verb, .argv = argv, .env = env, .mounts = mounts, .interactive = true });
}

// --- setup --------------------------------------------------------------------

/// Guided install for the compose and docker backends. `--yes` runs it from
/// the environment only (no prompts), which is what install.sh drives.
fn setup(host: *proc.Host, yes: bool, args: []const []const u8) Error!u8 {
    try noSubArgs(host, args, "setup");
    const d = try detectBackend(host);
    switch (d) {
        .compose => |c| return setupCompose(host, yes, c),
        .docker => |c| return setupDocker(host, yes, c),
        else => {
            host.err("setup supports the compose and docker backends; this server is managed by {s}.", .{@tagName(d.kind())});
            return error.DriverFailed;
        },
    }
}

fn writeDotEnv(host: *proc.Host, project_dir: []const u8, hostname: []const u8, mode: []const u8) Error!void {
    const path = std.fs.path.join(host.gpa, &.{ project_dir, ".env" }) catch return error.OutOfMemory;
    const content = std.fmt.allocPrint(host.gpa, "PDS_HOSTNAME={s}\nPDS_MODE={s}\n", .{ hostname, mode }) catch return error.OutOfMemory;
    Io.Dir.cwd().writeFile(host.io, .{ .sub_path = path, .data = content }) catch {
        host.err("could not write {s}.", .{path});
        return error.DriverFailed;
    };
}

const Hostname = struct { hostname: []const u8, multi: bool };

fn askHostnameMode(host: *proc.Host, yes: bool) Error!Hostname {
    const env_hostname = host.get("PDS_HOSTNAME");
    const env_mode = host.get("PDS_MODE");
    if (yes and env_hostname == null) {
        return failInput(host, "PDS_HOSTNAME is not set. With --yes, setup reads the hostname and mode from the environment.", .{});
    }
    var hostname: []const u8 = undefined;
    var multi = false;
    if (env_hostname) |h| {
        hostname = h;
    } else {
        hostname = try prompt.line(host, "Domain clients will use to reach this server (e.g. pds.example.com): ");
        if (hostname.len == 0) return failInput(host, "a domain is required.", .{});
    }
    if (env_mode) |m| {
        multi = std.mem.eql(u8, m, "path_multi");
    } else {
        host.out("", .{});
        host.out("Will this server host:", .{});
        host.out("  1) just your own account (simplest)", .{});
        host.out("  2) accounts for several people", .{});
        const choice = try prompt.line(host, "choose [1]: ");
        multi = std.mem.eql(u8, choice, "2");
    }
    return .{ .hostname = hostname, .multi = multi };
}

fn publicIp(host: *proc.Host) ?[]const u8 {
    const ip = fetch.get(host, "https://api.ipify.org") catch return null;
    const trimmed = std.mem.trim(u8, ip, " \r\n");
    return if (trimmed.len > 0) trimmed else null;
}

fn setupCompose(host: *proc.Host, yes: bool, c: driver.Compose) Error!u8 {
    const d = driver.Driver{ .compose = c };
    host.step("configuration", .{});
    const asked = try askHostnameMode(host, yes);

    try dnsNote(host, asked.hostname);
    const env_file = std.fs.path.join(host.gpa, &.{ c.project_dir, ".env" }) catch return error.OutOfMemory;
    try writeDotEnv(host, c.project_dir, asked.hostname, if (asked.multi) "path_multi" else "conformant_single");
    host.out("Wrote {s} (PDS_HOSTNAME={s}).", .{ env_file, asked.hostname });

    _ = try d.up(host);

    if (!(try waitHealthy(host, d))) {
        host.printTo(.stdout, "\n", .{});
        host.step("recent logs", .{});
        _ = d.logs(host, .{ .tail = 40 }) catch {};
        host.printTo(.stdout, "\n", .{});
        host.err("the server did not come up. Check the logs above (or run 'pesque logs').", .{});
        return error.DriverFailed;
    }
    host.out("The server is up.", .{});

    host.step("first account", .{});
    var handle_buf: std.ArrayList(u8) = .empty;
    defer handle_buf.deinit(host.gpa);
    var handle: []const u8 = undefined;
    if (asked.multi) {
        const username = try prompt.line(host, "Username for your account (e.g. alice): ");
        if (username.len == 0) return failInput(host, "a username is required.", .{});
        handle_buf.appendSlice(host.gpa, username) catch return error.OutOfMemory;
        handle_buf.append(host.gpa, '.') catch return error.OutOfMemory;
        handle_buf.appendSlice(host.gpa, asked.hostname) catch return error.OutOfMemory;
        handle = handle_buf.items;
    } else {
        handle = asked.hostname;
    }
    const email = try prompt.line(host, "Email for your account: ");
    if (email.len == 0) return failInput(host, "an email is required.", .{});
    const password = try passwordInput(host, null, "ACCOUNT_PASSWORD", "Password (at least 8 characters, not shown): ");

    const ip = publicIp(host);
    var env: std.ArrayList(proc.Env) = .empty;
    defer env.deinit(host.gpa);
    try env.append(host.gpa, password);
    if (ip) |v| try env.append(host.gpa, .{ .key = "PDS_PUBLIC_IP", .value = v });
    const code = try d.runOnce(host, .{
        .verb = "account",
        .argv = &.{ "create", "--handle", handle, "--email", email },
        .env = env.items,
        .interactive = true,
    });
    if (code != 0) return code;

    host.step("federation preflight", .{});
    _ = d.runOnce(host, .{ .verb = "doctor", .interactive = true }) catch {
        host.note("the preflight could not run; try 'pesque doctor' once the server has settled.", .{});
    };

    printBanner(host, asked.hostname, handle, dataLabel(host, d) catch null, env_file, ip);
    return 0;
}

fn setupDocker(host: *proc.Host, yes: bool, c: driver.Docker) Error!u8 {
    host.step("configuration", .{});
    const asked = try askHostnameMode(host, yes);
    try dnsNote(host, asked.hostname);

    const conf_dir = try searchCwd(host);
    const conf_path = std.fs.path.join(host.gpa, &.{ conf_dir, "pesque.conf" }) catch return error.OutOfMemory;
    const content = std.fmt.allocPrint(host.gpa, "hostname = {s}\nmode = {s}\n", .{ asked.hostname, if (asked.multi) "path_multi" else "conformant_single" }) catch return error.OutOfMemory;
    Io.Dir.cwd().writeFile(host.io, .{ .sub_path = conf_path, .data = content }) catch {
        host.err("could not write {s}.", .{conf_path});
        return error.DriverFailed;
    };
    host.out("Wrote {s} (hostname={s}).", .{ conf_path, asked.hostname });
    host.printTo(.stdout,
        \\
        \\Mount it at /data/pesque.conf and start the container, for example:
        \\
        \\  docker run -d --name {s} -p 4000:4000 \
        \\    -v pesque-data:/data \
        \\    -v "{s}:/data/pesque.conf" \
        \\    <image>
        \\
        \\Or set PDS_HOSTNAME and PDS_MODE as environment variables on the service.
        \\
        \\Once it is running:
        \\
        \\  pesque doctor
        \\  pesque account create --handle alice.{s} --email you@{s}
        \\
    , .{ c.container, conf_path, asked.hostname, asked.hostname });
    return 0;
}

fn searchCwd(host: *proc.Host) Error![]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(host.io, ".", host.gpa) catch error.OutOfMemory;
}

fn dataLabel(host: *proc.Host, d: driver.Driver) Error![]const u8 {
    return switch (try d.dataDir(host)) {
        .volume => |v| std.fmt.allocPrint(host.gpa, "docker volume {s}", .{v}) catch error.OutOfMemory,
        .path => |p| p,
    };
}

fn printBanner(host: *proc.Host, hostname: []const u8, handle: []const u8, data: ?[]const u8, config: []const u8, ip: ?[]const u8) void {
    host.printTo(.stdout,
        \\
        \\Done. Your server is at https://{s}.
        \\
        \\  first account: {s}
        \\  data:          {s}
        \\  configuration: {s}
        \\
    , .{ hostname, handle, data orelse "(the server's data directory)", config });
    if (ip) |v| {
        host.printTo(.stdout,
            \\
            \\  DNS records:   {s}  A  {s}
            \\
        , .{ hostname, v });
    } else {
        host.printTo(.stdout,
            \\
            \\  DNS records:   {s} must have an A record before clients can connect.
            \\
        , .{hostname});
    }
    host.printTo(.stdout,
        \\
        \\Next:
        \\  pesque logs -f          follow the server logs
        \\  pesque account list     list accounts
        \\  pesque --help           everything else
        \\
    , .{});
}

/// Best-effort DNS note: nonfatal, printed only when the name does not resolve.
fn dnsNote(host: *proc.Host, hostname: []const u8) Error!void {
    const hn = Io.net.HostName.init(hostname) catch return;
    var buffer: [16]Io.net.HostName.LookupResult = undefined;
    var queue = Io.Queue(Io.net.HostName.LookupResult).init(&buffer);
    Io.net.HostName.lookup(hn, host.io, &queue, .{ .port = 443 }) catch {
        host.note("{s} does not resolve yet. Create its A record first, or TLS will not be issued until DNS propagates.", .{hostname});
        return;
    };
    _ = queue.getOne(host.io) catch {
        host.note("{s} does not resolve yet. Create its A record first, or TLS will not be issued until DNS propagates.", .{hostname});
        return;
    };
}

/// Poll the container health after `up` (45 tries, 2s apart, like the old
/// script). Quiet per try: anything but healthy keeps polling.
fn waitHealthy(host: *proc.Host, d: driver.Driver) Error!bool {
    host.printTo(.stdout, "waiting for the server to become healthy", .{});
    defer host.printTo(.stdout, "\n", .{});
    var tries: usize = 0;
    while (tries < 45) : (tries += 1) {
        const status = d.pollStatus(host) catch return false;
        if (status == .healthy) return true;
        host.io.sleep(Io.Duration.fromSeconds(2), .real) catch {};
    }
    return false;
}

test {
    _ = @import("proc_test.zig");
    _ = @import("driver_test.zig");
    _ = @import("main_test.zig");
}
