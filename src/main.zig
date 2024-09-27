const std = @import("std");

pub fn main() !void {
    const stream = try std.net.connectUnixSocket("/tmp/prettierd.sock");
    defer stream.close();

    var buffer: [1024]u8 = undefined;
    var reader = stream.reader();
    var writer = stream.writer();

    try writer.writeAll("hello");

    while (true) {
        const read = try reader.read(&buffer);
        if (read == 0) break;
        std.debug.print("{s}", .{buffer[0..read]});
    }
}
