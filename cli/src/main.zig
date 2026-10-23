//! pesque: host-side CLI for operating a Pesque (ATProto PDS) server.
//!
//! A thin transport: driver verbs dispatch directly, domain verbs forward to
//! the release via `driver.run_once` -> `/app/bin/pesque <verb> <argv>`. The
//! release owns the domain logic; this binary parses nothing from verb
//! stdout, only exit codes.
//!
//! Two deployment shapes. The docker backend is imperative: the CLI creates
//! the container and owns its lifecycle. The systemd backend is declarative:
//! the unit owns the service (lifecycle verbs no-op) and one-offs run the
//! release directly as the service user. TLS is the operator's job in both.
//!
//! Frozen exit codes: 0 ok, 1 domain failure, 2 usage, 3 driver/environment.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const build_options = @import("build_options");
const proc = @import("proc.zig");
const driver = @import("driver.zig");
const detect = @import("detect.zig");

const Error = proc.Error;

const usage_text =
    \\usage: pesque [--backend docker|systemd] <command> [args...]
    \\
    \\Server lifecycle:
    \\  up | down | restart        docker: create/stop/restart the container
    \\                             systemd: no-op, the unit owns the service
    \\  update [tag]               docker: pull + recreate the container
    \\                             systemd: no-op
    \\  logs [-f] [--tail N]       follow or show the server logs
    \\  health                     container/service health
    \\  backend                    print the detected backend, capabilities, paths
    \\  version                    print the CLI and release versions
    \\
    \\Accounts and domain tasks (run inside the release):
    \\  account create --handle H --email E
    \\  account list
    \\  account delete --did D | --handle H
    \\  account takedown --did D | --handle H      (deactivate)
    \\  account activate --did D | --handle H
    \\  account reset-password --did D | --handle H
    \\  account plc-token --did D | --handle H    (code for signPlcOperation)
    \\  account email-token --did D | --handle H  (code for confirmEmail)
    \\  account reset-token --did D | --handle H  (code for resetPassword)
    \\  account app-passwords --did D | --handle H
    \\  account revoke-app-password --did D | --handle H --name N
    \\  invite create [--count N] [--uses N] [--for DID]
    \\  migrate --old-pds URL --handle H --email E
    \\  doctor                     run the federation preflight
    \\  status                     the operator report: identity, accounts, storage
    \\  backup [--out DIR]         live-safe backup (VACUUM INTO + blobs)
    \\  restore <archive.tar.gz>   cold restore (stops the service)
    \\  config validate | config template [--out PATH]
    \\  crawl request              ask the relay to crawl this server
    \\  lexicon add --from URL [--ref REF] [--dir SUBPATH]
    \\                             install a git repo's lexicons, then restart
    \\
    \\First run: write a config (config template --out pesque.conf), edit it,
    \\'pesque up', then 'pesque account create'. Put the TLS proxy in front
    \\yourself; the server speaks plain HTTP and advertises https.
    \\
    \\Passwords never take a --password VALUE flag and never come from the
    \\environment: the verb prompts with echo off, or reads a line from stdin
    \\(`echo secret | pesque ...`). The PLC token is no different: no
    \\--plc-token flag, set MIGRATE_PLC_TOKEN in the environment.
    \\
    \\Environment: PESQUE_BACKEND PESQUE_CONTAINER PESQUE_IMAGE PESQUE_DATA
    \\  PESQUE_CONFIG PESQUE_PUBLISH PESQUE_SERVICE PESQUE_RELEASE
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

/// Frozen exit codes: 0 ok, 1 domain failure (propagated child code),
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
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage(host);
            return 0;
        } else if (std.mem.eql(u8, arg, "--backend")) {
            i += 1;
            if (i >= args.len) return usage(host, "--backend needs a value: docker or systemd", .{});
            backend_flag = detect.parseKind(args[i]) orelse
                return usage(host, "unknown backend '{s}'. Use docker or systemd", .{args[i]});
        } else if (std.mem.startsWith(u8, arg, "--backend=")) {
            const value = arg["--backend=".len..];
            backend_flag = detect.parseKind(value) orelse
                return usage(host, "unknown backend '{s}'. Use docker or systemd", .{value});
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
    return dispatch(host, rest);
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

fn dispatch(host: *proc.Host, cmd: []const []const u8) Error!u8 {
    const name = cmd[0];
    const rest = cmd[1..];
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
    if (std.mem.eql(u8, name, "status")) return simpleVerb(host, "status", rest);
    if (std.mem.eql(u8, name, "backup")) return backup(host, rest);
    if (std.mem.eql(u8, name, "restore")) return restore(host, rest);
    if (std.mem.eql(u8, name, "config")) return configVerb(host, rest);
    if (std.mem.eql(u8, name, "crawl")) return crawl(host, rest);
    if (std.mem.eql(u8, name, "lexicon")) return lexicon(host, rest);
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

fn failInput(host: *proc.Host, comptime fmt: []const u8, args: anytype) Error {
    host.err(fmt, args);
    return error.Usage;
}

fn account(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len == 0) return usage(host, "'account' needs a subcommand: create, list, delete, takedown, activate, reset-password, plc-token, email-token, reset-token, app-passwords or revoke-app-password", .{});
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
        std.mem.eql(u8, sub, "activate") or std.mem.eql(u8, sub, "reset-password") or
        std.mem.eql(u8, sub, "plc-token") or std.mem.eql(u8, sub, "email-token") or
        std.mem.eql(u8, sub, "reset-token"))
    {
        const sel = try parseSelector(host, rest);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(host.gpa);
        try argv.appendSlice(host.gpa, &.{ sub, sel.flag, sel.value });
        // The verbs that authorize with the account's password (delete and
        // reset-password) read it themselves: the release prompts, or takes
        // it from stdin.
        return runDomain(host, "account", argv.items, &.{});
    }
    if (std.mem.eql(u8, sub, "app-passwords")) {
        const sel = try parseSelector(host, rest);
        return runDomain(host, "account", &.{ "app-passwords", sel.flag, sel.value }, &.{});
    }
    if (std.mem.eql(u8, sub, "revoke-app-password")) {
        const parsed = try parseSelectorNamed(host, rest);
        return runDomain(host, "account", &.{ "revoke-app-password", parsed.sel.flag, parsed.sel.value, "--name", parsed.name }, &.{});
    }
    return usage(host, "unknown account subcommand '{s}'", .{sub});
}

const AccountCreate = struct {
    handle: ?[]const u8 = null,
    email: ?[]const u8 = null,
    public_ip: ?[]const u8 = null,
};

fn parseAccountCreate(host: *proc.Host, args: []const []const u8) Error!AccountCreate {
    var f = AccountCreate{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--handle")) {
            f.handle = try valueFlag(host, args, &i, "--handle");
        } else if (std.mem.eql(u8, args[i], "--email")) {
            f.email = try valueFlag(host, args, &i, "--email");
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
    if (host.get("PDS_PUBLIC_IP") != null) f.public_ip = "PDS_PUBLIC_IP";
    return f;
}

fn runAccountCreate(host: *proc.Host, f: AccountCreate) Error!u8 {
    const d = try detectBackend(host);
    var env: std.ArrayList(proc.Env) = .empty;
    defer env.deinit(host.gpa);
    if (f.public_ip != null) {
        try env.append(host.gpa, .{ .key = "PDS_PUBLIC_IP" });
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{"create"});
    if (f.handle) |h| try argv.appendSlice(host.gpa, &.{ "--handle", h });
    if (f.email) |e| try argv.appendSlice(host.gpa, &.{ "--email", e });
    // The password is the release's to read: it prompts, or takes stdin.
    return d.runOnce(host, .{ .verb = "account", .argv = argv.items, .env = env.items, .interactive = true });
}

const Selector = struct {
    flag: []const u8,
    value: []const u8,
};

/// `--did D` XOR `--handle H`.
fn parseSelector(host: *proc.Host, args: []const []const u8) Error!Selector {
    var did: ?[]const u8 = null;
    var handle: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--did")) {
            did = try valueFlag(host, args, &i, "--did");
        } else if (std.mem.eql(u8, args[i], "--handle")) {
            handle = try valueFlag(host, args, &i, "--handle");
        } else {
            return failUsage(host, "unknown option '{s}' (use --did D or --handle H)", .{args[i]});
        }
    }
    if ((did == null) == (handle == null)) {
        return failInput(host, "pick exactly one: --did D or --handle H.", .{});
    }
    if (did) |d| return .{ .flag = "--did", .value = d };
    return .{ .flag = "--handle", .value = handle.? };
}

fn valueFlag(host: *proc.Host, args: []const []const u8, i: *usize, name: []const u8) Error![]const u8 {
    i.* += 1;
    if (i.* >= args.len) return failUsage(host, "{s} needs a value", .{name});
    return args[i.*];
}

/// `--did D` XOR `--handle H`, plus a required `--name N`. The name is not a
/// secret, so it may travel by flag.
fn parseSelectorNamed(host: *proc.Host, args: []const []const u8) Error!struct { sel: Selector, name: []const u8 } {
    var did: ?[]const u8 = null;
    var handle: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--did")) {
            if (did != null) return failUsage(host, "--did given twice", .{});
            did = try valueFlag(host, args, &i, "--did");
        } else if (std.mem.eql(u8, args[i], "--handle")) {
            if (handle != null) return failUsage(host, "--handle given twice", .{});
            handle = try valueFlag(host, args, &i, "--handle");
        } else if (std.mem.eql(u8, args[i], "--name")) {
            if (name != null) return failUsage(host, "--name given twice", .{});
            name = try valueFlag(host, args, &i, "--name");
        } else {
            return failUsage(host, "unknown option '{s}' (use --did D or --handle H, plus --name N)", .{args[i]});
        }
    }
    if ((did == null) == (handle == null)) {
        return failInput(host, "pick exactly one: --did D or --handle H.", .{});
    }
    if (name == null) {
        return failInput(host, "revoke-app-password needs --name N, the name the app password was created with.", .{});
    }
    const sel: Selector = if (did) |d|
        .{ .flag = "--did", .value = d }
    else
        .{ .flag = "--handle", .value = handle.? };
    return .{ .sel = sel, .name = name.? };
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
            // No secret on argv: the token takes the same bare-env path as
            // the passwords.
            return failInput(host, "--plc-token would put the token on the command line. Set MIGRATE_PLC_TOKEN in the environment instead; it is forwarded to the verb.", .{});
        } else {
            return usage(host, "unknown option '{s}' for 'migrate'", .{args[i]});
        }
    }
    if (old_pds == null) return failInput(host, "migrate needs --old-pds URL.", .{});
    if (handle == null) return failInput(host, "migrate needs --handle H.", .{});
    if (email == null) return failInput(host, "migrate needs --email E.", .{});

    var env: std.ArrayList(proc.Env) = .empty;
    defer env.deinit(host.gpa);
    // The PLC token is a secret: bare passthrough only. The password is the
    // release's to read: it prompts, or takes stdin.
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
    const d = try detectBackend(host);
    // Without --out the archive goes to the service's data directory, not the
    // working directory: the CLI runs as the service user (`sudo -u pesque
    // pesque backup`), whose cwd is often one it cannot read, and resolving "."
    // there failed before the archive was ever made.
    const given = out_dir orelse (try defaultOutDir(host, d));
    const abs = try absPath(host, given);
    // The archive is written through a same-path mount, so the file lands on
    // the host exactly where the verb says it does.
    return d.runOnce(host, .{
        .verb = "backup",
        .argv = &.{ "--out", abs },
        .mounts = &.{.{ .source = abs, .target = abs }},
        .interactive = true,
    });
}

/// Where a backup lands when --out is absent. The systemd backend runs the verb
/// directly against the data directory, the one place the service user is sure
/// to reach; the docker backend mounts the output path same-path into the
/// container, so "." keeps the operator's working directory (which the
/// container sees through the mount).
fn defaultOutDir(host: *proc.Host, d: driver.Driver) Error![]const u8 {
    return switch (d) {
        .systemd => switch (try d.dataDir(host)) {
            .path => |p| p,
            .volume => ".",
        },
        .docker => ".",
    };
}

fn restore(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len != 1) return usage(host, "restore takes the archive path: pesque restore <archive.tar.gz>", .{});
    const abs = try absPath(host, args[0]);
    const d = try detectBackend(host);
    // Restore is cold: stop the service first when the CLI owns the
    // lifecycle; the verb refuses a locked db as a second line of defense.
    var stopped = false;
    if (d.ownsLifecycle()) {
        _ = try d.down(host);
        stopped = true;
    } else {
        host.note("the service is managed outside this CLI: if the archive restore refuses a locked database, stop the service and run this again.", .{});
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

/// `lexicon add --from URL`: clone a repository on the host, then hand the
/// checkout to the release verb and restart so the server loads what it wrote.
fn lexicon(host: *proc.Host, args: []const []const u8) Error!u8 {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "add")) {
        return usage(host, "'lexicon' only knows 'add'", .{});
    }
    var from: ?[]const u8 = null;
    var ref: ?[]const u8 = null;
    var dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--from")) {
            from = try valueFlag(host, args, &i, "--from");
        } else if (std.mem.eql(u8, args[i], "--ref")) {
            ref = try valueFlag(host, args, &i, "--ref");
        } else if (std.mem.eql(u8, args[i], "--dir")) {
            dir = try valueFlag(host, args, &i, "--dir");
        } else {
            return usage(host, "unknown option '{s}' for 'lexicon add'", .{args[i]});
        }
    }
    const url = from orelse
        return failInput(host, "lexicon add needs --from URL, the git repository holding the lexicons.", .{});

    const d = try detectBackend(host);

    // The runtime image carries no git, so the clone happens here, on the
    // host, and the checkout is mounted into the one-off for the release verb
    // to read: a same-path mount, like backup and restore. The checkout holds
    // only public repository content, so it is made world-traversable: on the
    // systemd backend the one-off may run as the `pesque` user while this CLI
    // runs as root, and a 0700 directory would be unreadable to it.
    const tmp = try host.makeTempDir();
    defer host.removeTempDir(tmp);
    if (builtin.os.tag != .windows) {
        Io.Dir.cwd().setFilePermissions(host.io, tmp, .fromMode(0o755), .{}) catch {};
    }
    const checkout = std.fs.path.join(host.gpa, &.{ tmp, "repo" }) catch return error.OutOfMemory;

    var clone: std.ArrayList([]const u8) = .empty;
    defer clone.deinit(host.gpa);
    try clone.appendSlice(host.gpa, &.{ host.progs.git, "clone", "--depth", "1" });
    if (ref) |r| try clone.appendSlice(host.gpa, &.{ "--branch", r });
    try clone.appendSlice(host.gpa, &.{ "--", url, checkout });
    host.step("cloning {s}", .{url});
    const cloned = try host.run(clone.items);
    if (cloned != 0) return cloned;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{ "add", "--from", checkout });
    if (dir) |v| try argv.appendSlice(host.gpa, &.{ "--dir", v });

    const code = try d.runOnce(host, .{
        .verb = "lexicon",
        .argv = argv.items,
        .mounts = &.{.{ .source = checkout, .target = checkout }},
        .interactive = true,
    });
    if (code != 0) return code;

    host.step("restarting to load the new lexicons", .{});
    return d.restart(host);
}

fn runDomainWith(host: *proc.Host, verb: []const u8, argv: []const []const u8, env: []const proc.Env, mounts: []const proc.Mount) Error!u8 {
    const d = try detectBackend(host);
    return d.runOnce(host, .{ .verb = verb, .argv = argv, .env = env, .mounts = mounts, .interactive = true });
}

test {
    _ = @import("proc_test.zig");
    _ = @import("driver_test.zig");
    _ = @import("main_test.zig");
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
