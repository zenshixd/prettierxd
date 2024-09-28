const std = @import("std");
const builtin = @import("builtin");

const MAX_BUFFER_SIZE = 1024 * 1024 * 1024 * 4; // 4MB
const PRETTIERXD_SOCKET_FILENAME = "/tmp/prettierxd.sock";

pub fn main() !void {
    var timer = std.time.Timer.start() catch unreachable;

    var args = std.process.args();
    _ = args.skip(); // skip executable name
    const filename = args.next() orelse {
        std.debug.print("No filename provided\n", .{});
        return;
    };
    const range = parseRangeArgs(&args);
    std.log.debug("filename: {s}, range: {}", .{ filename, range });

    const stream = try connectToPrettierDaemon();
    defer stream.close();

    std.log.debug("connected, waiting for stdin", .{});
    const stdin = std.io.getStdIn();

    try stream.writeAll(filename);
    try stream.writeAll(&[_]u8{0});
    try stream.writeAll(range.start);
    try stream.writeAll(",");
    try stream.writeAll(range.end);
    try stream.writeAll(&[_]u8{0});
    try streamUntilEof(stdin.reader(), stream.writer());
    try stream.writeAll(&[_]u8{0});

    std.log.debug("waiting for response", .{});
    try streamUntilEof(stream.reader(), std.io.getStdOut().writer());

    std.log.debug("done in {d}ms", .{timer.read() / 1_000_000});
}

const Range = struct {
    start: []const u8 = "-1",
    end: []const u8 = "-1",
};

fn parseRangeArgs(args: *std.process.ArgIterator) Range {
    var range = Range{};

    var arg = args.next();
    if (arg == null) return range;

    const matchers = .{
        .{ "--range-start", "start" },
        .{ "--range-end", "end" },
    };
    inline for (matchers) |kv| {
        var split_iter = std.mem.splitScalar(u8, arg.?, '=');
        if (std.mem.eql(u8, split_iter.next().?, kv[0])) {
            @field(range, kv[1]) = split_iter.next() orelse {
                std.debug.print("No value provided for {s}\n", .{kv[0]});
                return range;
            };

            arg = args.next() orelse return range;
        }
    }

    return range;
}

fn streamUntilEof(source_reader: anytype, dest_writer: anytype) !void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const read = try source_reader.read(&buf);

        if (read == 0) break;
        try dest_writer.writeAll(buf[0..read]);
    }
}

fn connectToPrettierDaemon() !std.net.Stream {
    const stream = std.net.connectUnixSocket(PRETTIERXD_SOCKET_FILENAME) catch |err| switch (err) {
        error.ConnectionRefused,
        error.FileNotFound,
        => {
            std.log.debug("connection refused, restarting prettier daemon", .{});
            return startPrettierDaemon();
        },
        else => return err,
    };
    return stream;
}

fn startPrettierDaemon() !std.net.Stream {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.fs.deleteFileAbsolute(PRETTIERXD_SOCKET_FILENAME) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    const exec_file = try std.fs.selfExeDirPathAlloc(gpa.allocator());
    std.log.debug("exec file: {s}", .{exec_file});
    defer gpa.allocator().free(exec_file);

    const server_file = try std.fs.path.resolve(gpa.allocator(), &[_][]const u8{ exec_file, "../../index.js" });
    defer gpa.allocator().free(server_file);
    std.debug.assert(server_file.len > 0);
    std.log.debug("server file: {s}", .{server_file});

    var child_process = std.process.Child.init(&[_][]const u8{ "node", server_file }, gpa.allocator());

    const behaviour = .Ignore;
    child_process.stdin_behavior = behaviour;
    child_process.stdout_behavior = behaviour;
    child_process.stderr_behavior = behaviour;

    try child_process.spawn();
    return try waitUntilDeamonReady();
}

fn waitUntilDeamonReady() !std.net.Stream {
    std.log.debug("waiting for socket", .{});
    var stream: std.net.Stream = undefined;
    while (true) {
        stream = std.net.connectUnixSocket(PRETTIERXD_SOCKET_FILENAME) catch |err| switch (err) {
            error.ConnectionRefused,
            error.FileNotFound,
            => continue,
            else => return err,
        };
        break;
    }

    std.log.debug("socket connected", .{});
    return stream;
}
