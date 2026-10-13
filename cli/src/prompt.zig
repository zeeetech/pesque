//! Terminal prompts: plain line reads. When stdin is not a tty the read
//! refuses (error.NotATty): the prompts here are the last resort of the
//! flag -> env -> prompt order for non-secret values. Passwords are not read
//! here at all; the release owns them (no-echo prompt, or a line on stdin).
const std = @import("std");
const Io = std.Io;
const proc = @import("proc.zig");

const Error = proc.Error;

/// Read one line after printing `prompt`. Trailing CR/LF stripped.
pub fn line(host: *proc.Host, prompt: []const u8) Error![]const u8 {
    const file: Io.File = .stdout();
    file.writeStreamingAll(host.io, prompt) catch {};
    const raw = readLine(host) orelse return error.NotATty;
    return std.mem.trim(u8, raw, " \t\r\n");
}

/// Read one line from stdin as raw bytes. Null on EOF without data.
fn readLine(host: *proc.Host) ?[]const u8 {
    var buffer: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(host.io, &buffer);
    const line_bytes = reader.interface.takeDelimiterExclusive('\n') catch |e| switch (e) {
        error.EndOfStream => return null,
        else => return null,
    };
    return host.gpa.dupe(u8, line_bytes) catch null;
}
