//! Terminal prompts: plain line reads and no-echo password reads (termios on
//! POSIX). When stdin is not a tty and no password source exists, the caller
//! refuses: the prompts here are the last resort of the flag -> env -> prompt
//! order.
const std = @import("std");
const builtin = @import("builtin");
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

/// Read a secret without echo. Refuses (error.NotATty) when stdin is not a
/// terminal; the caller turns that into a usage refusal with the right fix.
pub fn secret(host: *proc.Host, prompt: []const u8) Error![]const u8 {
    if (!host.stdinIsTty()) return error.NotATty;
    const file: Io.File = .stdout();
    file.writeStreamingAll(host.io, prompt) catch {};

    switch (builtin.os.tag) {
        .windows => {
            // No console-mode API in std: read with echo, and say so.
            host.printTo(.stderr, "(input will be visible)\n", .{});
            const raw = readLine(host) orelse return error.NotATty;
            return std.mem.trim(u8, raw, " \t\r\n");
        },
        else => {
            const saved = std.posix.tcgetattr(0) catch {
                // Not actually a terminal after all; fall back to a plain read.
                const raw = readLine(host) orelse return error.NotATty;
                return std.mem.trim(u8, raw, " \t\r\n");
            };
            var no_echo = saved;
            no_echo.lflag.ECHO = false;
            std.posix.tcsetattr(0, .NOW, no_echo) catch {};
            defer std.posix.tcsetattr(0, .NOW, saved) catch {};

            const raw = readLine(host) orelse return error.NotATty;
            file.writeStreamingAll(host.io, "\n") catch {};
            return std.mem.trim(u8, raw, " \t\r\n");
        },
    }
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
