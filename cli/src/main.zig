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
    \\  migrate --old-pds URL --handle H --email E
    \\  doctor                     run the federation preflight
    \\  backup [--out DIR]         live-safe backup (VACUUM INTO + blobs)
    \\  restore <archive.tar.gz>   cold restore (stops the service)
    \\  config validate | config template [--out PATH]
    \\  crawl request              ask the relay to crawl this server
    \\
    \\Passwords never take a --password VALUE flag: use --password-env VAR, the
    \\ACCOUNT_PASSWORD/MIGRATE_PASSWORD environment, or a no-echo prompt. The
    \\PLC token is no different: no --plc-token flag, set MIGRATE_PLC_TOKEN in
    \\the environment.
    \\
    \\Environment: PESQUE_BACKEND PESQUE_ROOT PESQUE_CONTAINER PESQUE_IMAGE
    \\  PESQUE_TAG PESQUE_BUILD PESQUE_RESTART_CMD PESQUE_SERVICE PESQUE_RELEASE
    \\  MIGRATE_PLC_TOKEN
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
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--old-pds")) {
            old_pds = try valueFlag(host, args, &i, "--old-pds");
        } else if (std.mem.eql(u8, args[i], "--handle")) {
            handle = try valueFlag(host, args, &i, "--handle");
        } else if (std.mem.eql(u8, args[i], "--email")) {
            email = try valueFlag(host, args, &i, "--email");
        } else if (std.mem.eql(u8, args[i], "--plc-token")) {
            // No secret on argv (the CLI's own doctrine): the token goes
            // through the same bare-env mechanism as the passwords.
            return failInput(host, "--plc-token would put the token on the command line. Set MIGRATE_PLC_TOKEN in the environment instead; it is forwarded to the verb like the passwords.", .{});
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
    // The PLC token is a secret: bare passthrough only, like the passwords.
    if (host.get("MIGRATE_PLC_TOKEN") != null) {
        try env.append(host.gpa, .{ .key = "MIGRATE_PLC_TOKEN" });
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{ "--old-pds", old_pds.?, "--handle", handle.?, "--email", email.? });
    return runDomain(host, "migrate", argv.items, env.items);
}

/// Resolve a host path to an absolute one for same-path mounts.
fn absPath(host: *proc.Host, path: []const u8) Error![]const u8 {
    return Io.Dir.cwd().realPathFileAlloc(host.io, path, host.gpa) catch {
        host.err("path '{s}' does not exist (or is not accessible).", .{path});
        return error.DriverFailed;
    };
}

/// Same, for a path that may not exist yet (`config template --out` writes
/// the file): realpath the parent directory and re-join the basename. The
/// parent must exist.
fn absPathCreating(host: *proc.Host, path: []const u8) Error![]const u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    const abs_dir = try absPath(host, dir);
    return std.fs.path.join(host.gpa, &.{ abs_dir, std.fs.path.basename(path) }) catch error.OutOfMemory;
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
    const outcome = d.runOnce(host, .{
        .verb = "restore",
        .argv = &.{abs},
        .mounts = &.{.{ .source = abs, .target = abs }},
        .interactive = true,
    });
    // The server comes back even when the restore itself failed, and a
    // failed bring-up must not be swallowed: exiting 0 with the service
    // down is exactly the state the operator cannot see.
    if (stopped) {
        const up_code: u8 = d.up(host) catch 3;
        if (up_code != 0) {
            host.err("the service did not come back up after the restore; run 'pesque up' and check 'pesque logs'.", .{});
            if (outcome) |c| {
                if (c == 0) return up_code;
            } else |_| {}
        }
    }
    return outcome;
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
        // The file is being created; only its parent has to exist.
        const abs = try absPathCreating(host, path);
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

fn writeDotEnv(host: *proc.Host, project_dir: []const u8, hostname: []const u8, mode: []const u8, yes: bool) Error!void {
    const path = std.fs.path.join(host.gpa, &.{ project_dir, ".env" }) catch return error.OutOfMemory;
    // .env is the operator's file: COMPOSE_PROFILES=auto-update, PESQUE_TAG
    // pins and friends live here (the rollback path in docs/guides/
    // operations.md) and must survive a re-run. Setup owns only the two keys
    // below.
    const existing = try readFileOpt(host, path);
    defer if (existing) |c| host.gpa.free(c);
    const owned = [_]Owned{
        .{ .key = "PDS_HOSTNAME", .value = hostname },
        .{ .key = "PDS_MODE", .value = mode },
    };
    try writeOwnedConfig(host, path, existing, "=", &owned, yes);
}

/// One key setup owns in a config file it rewrites.
const Owned = struct { key: []const u8, value: []const u8 };

/// Read a small text file, or null when it does not exist yet.
fn readFileOpt(host: *proc.Host, path: []const u8) Error!?[]u8 {
    return Io.Dir.cwd().readFileAlloc(host.io, path, host.gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => null,
        else => {
            host.err("could not read {s}.", .{path});
            return error.DriverFailed;
        },
    };
}

/// Write `path` as `<key><eq><value>` lines: the owned keys are updated in
/// place (missing ones appended) and every other line — operator keys,
/// comments — survives byte-for-byte. When an owned key already holds a
/// different value, refuse unless --yes: re-running setup must not silently
/// reconfigure a provisioned server.
fn writeOwnedConfig(host: *proc.Host, path: []const u8, existing: ?[]const u8, eq: []const u8, owned: []const Owned, yes: bool) Error!void {
    const g = host.gpa;
    if (existing) |content| {
        var bad_key: ?[]const u8 = null;
        var bad_old: []const u8 = "";
        var bad_new: []const u8 = "";
        var scan = std.mem.splitScalar(u8, content, '\n');
        while (scan.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const at = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..at], " \t");
            var value = std.mem.trim(u8, trimmed[at + 1 ..], " \t");
            // compose strips surrounding quotes from .env values; compare
            // unquoted so a quoted old value is not a false conflict.
            if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
            {
                value = value[1 .. value.len - 1];
            }
            for (owned) |o| {
                if (!std.mem.eql(u8, key, o.key)) continue;
                if (!std.mem.eql(u8, value, o.value) and bad_key == null) {
                    bad_key = o.key;
                    bad_old = value;
                    bad_new = o.value;
                }
            }
        }
        if (bad_key) |k| {
            if (!yes) {
                host.err("{s} already sets {s}={s}, but setup would write {s}={s}.", .{ path, k, bad_old, k, bad_new });
                host.printTo(.stderr,
                    \\
                    \\  Re-running setup must not silently reconfigure a provisioned server.
                    \\  Pass --yes to apply the new values anyway (setup only rewrites its own
                    \\  keys; every other line in the file is kept), or edit the file by hand.
                    \\
                , .{});
                return error.DriverFailed;
            }
            host.note("{s}: updating {s}={s} to {s}={s}.", .{ path, k, bad_old, k, bad_new });
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(g);
    const done = g.alloc(bool, owned.len) catch return error.OutOfMemory;
    defer g.free(done);
    @memset(done, false);
    if (existing) |content| {
        var it = std.mem.splitScalar(u8, content, '\n');
        var first = true;
        while (it.next()) |line| {
            if (!first) out.append(g, '\n') catch return error.OutOfMemory;
            first = false;
            var replaced = false;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.indexOfScalar(u8, trimmed, '=')) |at| {
                const key = std.mem.trim(u8, trimmed[0..at], " \t");
                for (owned, 0..) |o, i| {
                    if (!std.mem.eql(u8, key, o.key)) continue;
                    out.appendSlice(g, o.key) catch return error.OutOfMemory;
                    out.appendSlice(g, eq) catch return error.OutOfMemory;
                    out.appendSlice(g, o.value) catch return error.OutOfMemory;
                    done[i] = true;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) out.appendSlice(g, line) catch return error.OutOfMemory;
        }
    }
    for (owned, 0..) |o, i| {
        if (done[i]) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            out.append(g, '\n') catch return error.OutOfMemory;
        }
        out.appendSlice(g, o.key) catch return error.OutOfMemory;
        out.appendSlice(g, eq) catch return error.OutOfMemory;
        out.appendSlice(g, o.value) catch return error.OutOfMemory;
        out.append(g, '\n') catch return error.OutOfMemory;
    }
    Io.Dir.cwd().writeFile(host.io, .{ .sub_path = path, .data = out.items }) catch {
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
    try writeDotEnv(host, c.project_dir, asked.hostname, if (asked.multi) "path_multi" else "conformant_single", yes);
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
    // pesque.conf can carry many operator keys (see pesque.conf.example);
    // setup owns only hostname and mode, and a re-run preserves the rest.
    const existing = try readFileOpt(host, conf_path);
    defer if (existing) |content| host.gpa.free(content);
    const owned = [_]Owned{
        .{ .key = "hostname", .value = asked.hostname },
        .{ .key = "mode", .value = if (asked.multi) "path_multi" else "conformant_single" },
    };
    try writeOwnedConfig(host, conf_path, existing, " = ", &owned, yes);
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

// --- setup config rewrite -----------------------------------------------------

test "setup .env: fresh write, operator keys kept, conflict refused unless --yes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    var host = proc.Host{ .gpa = arena, .io = testing.io, .environ = &env_map, .stdout_to_stderr = true };

    const tmp_rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const base = Io.Dir.cwd().realPathFileAlloc(testing.io, tmp_rel, arena) catch unreachable;
    const env_path = try std.fs.path.join(arena, &.{ base, ".env" });

    const owned = [_]Owned{
        .{ .key = "PDS_HOSTNAME", .value = "pds.example.com" },
        .{ .key = "PDS_MODE", .value = "conformant_single" },
    };

    // Fresh write: exactly the owned lines.
    try writeOwnedConfig(&host, env_path, null, "=", &owned, false);
    var got = try Io.Dir.cwd().readFileAlloc(testing.io, env_path, arena, .limited(1 << 20));
    try testing.expectEqualStrings("PDS_HOSTNAME=pds.example.com\nPDS_MODE=conformant_single\n", got);

    // Re-run over an operator's file, same values: nothing changes. The
    // rollback keys (COMPOSE_PROFILES, PESQUE_TAG) survive untouched.
    const with_operator_keys = "# mine\nCOMPOSE_PROFILES=auto-update\nPESQUE_TAG=v1.4.2\nPDS_HOSTNAME=pds.example.com\nPDS_MODE=conformant_single\n";
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = env_path, .data = with_operator_keys });
    try writeOwnedConfig(&host, env_path, with_operator_keys, "=", &owned, false);
    got = try Io.Dir.cwd().readFileAlloc(testing.io, env_path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(with_operator_keys, got);

    // Quoted old values compare unquoted (compose strips them): no conflict.
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = env_path, .data = "PDS_HOSTNAME=\"pds.example.com\"\nPDS_MODE=conformant_single\n" });
    try writeOwnedConfig(&host, env_path, "PDS_HOSTNAME=\"pds.example.com\"\nPDS_MODE=conformant_single\n", "=", &owned, false);

    // Different values: refuse without --yes, and write nothing.
    const different = [_]Owned{
        .{ .key = "PDS_HOSTNAME", .value = "other.example.com" },
        .{ .key = "PDS_MODE", .value = "conformant_single" },
    };
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = env_path, .data = with_operator_keys });
    try testing.expectError(error.DriverFailed, writeOwnedConfig(&host, env_path, with_operator_keys, "=", &different, false));
    got = try Io.Dir.cwd().readFileAlloc(testing.io, env_path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(with_operator_keys, got);

    // --yes: owned keys update in place, every other line is kept.
    try writeOwnedConfig(&host, env_path, with_operator_keys, "=", &different, true);
    got = try Io.Dir.cwd().readFileAlloc(testing.io, env_path, arena, .limited(1 << 20));
    try testing.expectEqualStrings("# mine\nCOMPOSE_PROFILES=auto-update\nPESQUE_TAG=v1.4.2\nPDS_HOSTNAME=other.example.com\nPDS_MODE=conformant_single\n", got);
}

test "setup pesque.conf: same rewrite rules with the spaced separator" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    var host = proc.Host{ .gpa = arena, .io = testing.io, .environ = &env_map, .stdout_to_stderr = true };

    const tmp_rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const base = Io.Dir.cwd().realPathFileAlloc(testing.io, tmp_rel, arena) catch unreachable;
    const conf_path = try std.fs.path.join(arena, &.{ base, "pesque.conf" });

    const owned = [_]Owned{
        .{ .key = "hostname", .value = "pds.example.com" },
        .{ .key = "mode", .value = "conformant_single" },
    };
    const operator_conf = "# pesque configuration.\nidentity = plc\nhostname = pds.example.com\nmode = conformant_single\n";
    try writeOwnedConfig(&host, conf_path, operator_conf, " = ", &owned, false);
    const got = try Io.Dir.cwd().readFileAlloc(testing.io, conf_path, arena, .limited(1 << 20));
    try testing.expectEqualStrings(operator_conf, got);
}

test "absPathCreating: the file being created need not exist, its parent does" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env_map = std.process.Environ.Map.init(arena);
    var host = proc.Host{ .gpa = arena, .io = testing.io, .environ = &env_map, .stdout_to_stderr = true };

    const tmp_rel = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const base = Io.Dir.cwd().realPathFileAlloc(testing.io, tmp_rel, arena) catch unreachable;
    const dir = try std.fs.path.join(arena, &.{ base, "newdir" });
    try Io.Dir.cwd().createDirPath(testing.io, dir);

    // The file does not exist; the resolved path is parent + basename.
    const abs = try absPathCreating(&host, try std.fs.path.join(arena, &.{ dir, "pesque.conf" }));
    try testing.expectEqualStrings(try std.fs.path.join(arena, &.{ dir, "pesque.conf" }), abs);

    // A missing parent is still refused.
    try testing.expectError(error.DriverFailed, absPathCreating(&host, try std.fs.path.join(arena, &.{ base, "nope", "pesque.conf" })));
}
