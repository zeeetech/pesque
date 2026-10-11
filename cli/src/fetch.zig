//! Network access: std-only, everything through a `curl` subprocess (spec
//! D8), with checksums via `std.crypto` sha256.
const std = @import("std");
const Io = std.Io;
const proc = @import("proc.zig");

const Error = proc.Error;

const curl_flags = [_][]const u8{ "-fsSL", "--max-time", "30" };

/// The GitHub repo releases are fetched from.
pub fn releaseRepo(host: *proc.Host) []const u8 {
    return host.get("PESQUE_REPO") orelse "zeeetech/pesque";
}

/// GET a URL and return the body (caller owns it).
pub fn get(host: *proc.Host, url: []const u8) Error![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{host.progs.curl});
    try argv.appendSlice(host.gpa, &curl_flags);
    try argv.append(host.gpa, url);
    const cap = host.capture(argv.items) catch |e| return e;
    defer host.freeCapture(cap);
    if (!cap.ok()) return curlFailed(host, cap);
    return host.gpa.dupe(u8, cap.stdout) catch error.OutOfMemory;
}

/// Download a URL to a file.
pub fn downloadTo(host: *proc.Host, url: []const u8, dest: []const u8) Error!void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(host.gpa);
    try argv.appendSlice(host.gpa, &.{host.progs.curl});
    try argv.appendSlice(host.gpa, &curl_flags);
    try argv.appendSlice(host.gpa, &.{ "-o", dest });
    try argv.append(host.gpa, url);
    const cap = host.capture(argv.items) catch |e| return e;
    if (!cap.ok()) {
        host.freeCapture(cap);
        return curlFailed(host, cap);
    }
    host.freeCapture(cap);
}

fn curlFailed(host: *proc.Host, cap: proc.Host.Capture) Error {
    const tail_len = @min(cap.stderr.len, 200);
    host.err("download failed (curl exit {d}).", .{if (cap.term == .exited) cap.term.exited else 0});
    if (tail_len > 0) {
        const tail = cap.stderr[cap.stderr.len - tail_len ..];
        host.printTo(.stderr, "  {s}", .{std.mem.trim(u8, tail, " \r\n")});
    }
    return error.DriverFailed;
}

/// Resolve the `latest` release tag from the GitHub API.
pub fn latestTag(host: *proc.Host) Error![]const u8 {
    const url = std.fmt.allocPrint(host.gpa, "https://api.github.com/repos/{s}/releases/latest", .{releaseRepo(host)}) catch return error.OutOfMemory;
    const body = try get(host, url);
    const Latest = struct { tag_name: []const u8 };
    const parsed = std.json.parseFromSlice(Latest, host.gpa, body, .{ .ignore_unknown_fields = true }) catch {
        host.err("could not resolve the latest release tag (GitHub API). Pass the tag explicitly: 'pesque update <tag>'.", .{});
        return error.DriverFailed;
    };
    if (parsed.value.tag_name.len == 0) {
        host.err("could not resolve the latest release tag. Pass the tag explicitly: 'pesque update <tag>'.", .{});
        return error.DriverFailed;
    }
    return host.gpa.dupe(u8, parsed.value.tag_name) catch error.OutOfMemory;
}

// --- checksums ---------------------------------------------------------------

pub fn sha256File(host: *proc.Host, path: []const u8) Error![32]u8 {
    const file = Io.Dir.cwd().openFile(host.io, path, .{}) catch {
        host.err("cannot open {s} for checksumming.", .{path});
        return error.DriverFailed;
    };
    defer file.close(host.io);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(host.io, &buffer);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const n = reader.interface.readSliceShort(&buffer) catch {
            host.err("cannot read {s} for checksumming.", .{path});
            return error.DriverFailed;
        };
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return digest;
}

pub fn unpackTarGz(host: *proc.Host, tarball: []const u8, out_dir: Io.Dir) Error!void {
    const file = Io.Dir.cwd().openFile(host.io, tarball, .{}) catch {
        host.err("cannot open the downloaded tarball at {s}.", .{tarball});
        return error.DriverFailed;
    };
    defer file.close(host.io);
    var read_buf: [64 * 1024]u8 = undefined;
    var file_reader = file.reader(host.io, &read_buf);
    var decomp_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, &decomp_buf);
    std.tar.extract(host.io, out_dir, &decompress.reader, .{ .mode_mode = .executable_bit_only }) catch {
        host.err("the tarball at {s} is not a valid tar.gz archive.", .{tarball});
        return error.DriverFailed;
    };
}

/// Parse a SHA256SUMS file and verify `asset` matches `file_path`.
pub fn verifySums(host: *proc.Host, sums_path: []const u8, asset: []const u8, file_path: []const u8) Error!void {
    const g = host.gpa;
    const content = Io.Dir.cwd().readFileAlloc(host.io, sums_path, g, .limited(1 << 20)) catch {
        host.err("cannot read {s}; cannot verify the download. Delete it and retry, or verify by hand.", .{sums_path});
        return error.DriverFailed;
    };
    const expected_hex = sumsEntry(content, asset) orelse {
        host.err("{s} has no entry for {s}; cannot verify the download.", .{ sums_path, asset });
        return error.DriverFailed;
    };
    const digest = try sha256File(host, file_path);
    var actual_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&actual_hex, "{x}", .{digest}) catch unreachable;
    if (!std.ascii.eqlIgnoreCase(&actual_hex, expected_hex)) {
        host.err("checksum mismatch for {s}: expected {s}, got {s}. The download is corrupt or tampered with; do not install it.", .{ asset, expected_hex, &actual_hex });
        return error.DriverFailed;
    }
}

/// The hex digest of `asset`'s line in a `digest  filename` listing.
pub fn sumsEntry(content: []const u8, asset: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const digest = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const bare = std.fs.path.basename(name);
        if (std.mem.eql(u8, bare, asset)) return digest;
    }
    return null;
}
