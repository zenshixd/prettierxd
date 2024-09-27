const std = @import("std");

const MAX_BUFFER_SIZE = 1024 * 1024 * 1024 * 4; // 4MB

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    const filename = args.next() orelse return;

    const stream = try std.net.connectUnixSocket("/tmp/prettierd.sock");
    defer stream.close();

    std.log.info("connected, waiting for stdin", .{});
    const stdin = std.io.getStdIn();

    try stream.writeAll(filename);
    try stream.writeAll("$");
    try streamUntilEof(stdin.reader(), stream.writer());
    try stream.writeAll("$$$");

    std.log.info("waiting for data", .{});
    try streamUntilEof(stream.reader(), std.io.getStdOut().writer());
}

fn streamUntilEof(source_reader: anytype, dest_writer: anytype) !void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const read = try source_reader.read(&buf);

        if (read == 0) break;
        try dest_writer.writeAll(buf[0..read]);
    }
}
