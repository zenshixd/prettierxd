const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;
const posix = std.posix;

const PRETTIERXD_SOCKET_FILENAME = "prettierxd.sock";

pub fn main() !void {
    var timer = std.time.Timer.start() catch unreachable;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const socketFilename = try getSocketFilename(gpa.allocator());
    defer gpa.allocator().free(socketFilename);

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    _ = args.skip(); // skip executable name
    const filename = args.next() orelse {
        std.debug.print("No filename provided\n", .{});
        return;
    };
    const range = parseRangeArgs(&args);
    std.log.debug("filename: {s}, range: {}", .{ filename, range });

    const stream = try connectToPrettierDaemon(socketFilename);
    defer stream.close();

    std.log.debug("connected, waiting for stdin", .{});
    const stdin = std.io.getStdIn();
    std.log.debug("connected to socket in {d}ms", .{timer.read() / 1_000_000});

    try stream.writeAll(filename);
    try stream.writeAll(&[_]u8{0});
    try stream.writeAll(range.start);
    try stream.writeAll(",");
    try stream.writeAll(range.end);
    try stream.writeAll(&[_]u8{0});
    try streamUntilEof(&timer, stdin.reader(), stream.writer());
    try stream.writeAll(&[_]u8{0});

    std.log.debug("send in {d}ms, waiting for response", .{timer.read() / 1_000_000});
    try stream.reader().streamUntilDelimiter(std.io.getStdOut().writer(), 0, null);

    std.log.debug("done in {d}ms", .{timer.read() / 1_000_000});
}

fn getSocketFilename(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const socketFilename = try std.fs.path.join(allocator, &.{ "\\\\?\\pipe", PRETTIERXD_SOCKET_FILENAME });
        return socketFilename;
    }

    var envMap = try std.process.getEnvMap(allocator);
    defer envMap.deinit();

    const tmpDir = envMap.get("TMPDIR") orelse "/tmp";
    const socketFilename = try std.fs.path.join(allocator, &.{ tmpDir, PRETTIERXD_SOCKET_FILENAME });
    return socketFilename;
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

fn streamUntilEof(timer: *std.time.Timer, source_reader: anytype, dest_writer: anytype) !void {
    var buf: [1024]u8 = undefined;
    while (true) {
        const read = try source_reader.read(&buf);
        std.log.debug("read {d}, took {d}ms", .{ read, timer.read() / 1_000_000 });

        try dest_writer.writeAll(buf[0..read]);

        const isEof = try source_reader.context.getEndPos() == 0;
        if (isEof) break;
    }
}

pub const DaemonStream = if (builtin.os.tag == .windows) std.fs.File else std.net.Stream;

fn connectToSocket(socketFilename: []const u8) anyerror!DaemonStream {
    std.log.debug("connecting to socket {s}", .{socketFilename});
    return switch (builtin.os.tag) {
        .windows => try std.fs.createFileAbsolute(socketFilename, .{ .read = true }),
        .linux, .macos => std.net.connectUnixSocket(socketFilename),
        else => @panic("unsupported os"),
    };
}

fn connectToPrettierDaemon(socketFilename: []const u8) !DaemonStream {
    const stream = connectToSocket(socketFilename) catch |err| switch (err) {
        error.ConnectionRefused,
        error.FileNotFound,
        => {
            std.log.debug("connection refused, restarting prettier daemon", .{});
            return startPrettierDaemon(socketFilename);
        },
        else => return err,
    };
    return stream;
}

fn startPrettierDaemon(socketFilename: []const u8) !DaemonStream {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.fs.deleteFileAbsolute(socketFilename) catch |err| {
        if (err != error.FileNotFound) return err;
    };
    const exec_file = try std.fs.selfExeDirPathAlloc(gpa.allocator());
    std.log.debug("exec file: {s}", .{exec_file});
    defer gpa.allocator().free(exec_file);

    const server_file = try std.fs.path.resolve(gpa.allocator(), &[_][]const u8{ exec_file, "../../index.js" });
    defer gpa.allocator().free(server_file);
    std.debug.assert(server_file.len > 0);
    std.log.debug("server file: {s}", .{server_file});

    try startProcess(gpa.allocator(), .{
        .args = &[_][]const u8{ "node", server_file },
    });

    std.log.debug("child process spawned", .{});
    return try waitUntilDeamonReady(socketFilename);
}

fn waitUntilDeamonReady(socketFilename: []const u8) !DaemonStream {
    std.log.debug("waiting for socket", .{});
    var stream: DaemonStream = undefined;
    while (true) {
        stream = connectToSocket(socketFilename) catch |err| switch (err) {
            error.ConnectionRefused,
            error.FileNotFound,
            => {
                std.log.debug("error: {s}", .{@errorName(err)});
                continue;
            },
            else => return err,
        };
        break;
    }

    std.log.debug("socket connected", .{});
    return stream;
}

fn startProcess(allocator: std.mem.Allocator, params: StartProcess) !void {
    return switch (builtin.os.tag) {
        .windows => try startProcessWindows(allocator, params),
        .linux, .macos => try startProcessPosix(allocator, params),
        else => @panic("unsupported os"),
    };
}

pub const StartProcess = struct {
    args: []const []const u8,
};

pub const CreationFlags = struct {
    pub const DETACHED_PROCESS = 0x00000008;
    pub const CREATE_NEW_PROCESS_GROUP = 0x00000200;
};

fn startProcessWindows(allocator: std.mem.Allocator, params: StartProcess) !void {
    var saAttr = windows.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .bInheritHandle = windows.TRUE,
        .lpSecurityDescriptor = null,
    };
    const null_pipe = windows.OpenFile(std.unicode.utf8ToUtf16LeStringLiteral("\\Device\\Null"), .{
        .access_mask = windows.GENERIC_READ | windows.GENERIC_WRITE | windows.SYNCHRONIZE,
        .share_access = windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE | windows.FILE_SHARE_DELETE,
        .sa = &saAttr,
        .creation = windows.OPEN_EXISTING,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.Unexpected, // not possible for "NUL"
        error.PipeBusy => return error.Unexpected, // not possible for "NUL"
        error.FileNotFound => return error.Unexpected, // not possible for "NUL"
        error.AccessDenied => return error.Unexpected, // not possible for "NUL"
        error.NameTooLong => return error.Unexpected, // not possible for "NUL"
        error.WouldBlock => return error.Unexpected, // not possible for "NUL"
        error.NetworkNotFound => return error.Unexpected, // not possible for "NUL"
        error.AntivirusInterference => return error.Unexpected, // not possible for "NUL"
        else => |e| return e,
    };
    defer posix.close(null_pipe);

    var siStartInfo = windows.STARTUPINFOW{
        .cb = @sizeOf(windows.STARTUPINFOW),
        .hStdError = null_pipe,
        .hStdOutput = null_pipe,
        .hStdInput = null_pipe,
        .dwFlags = windows.STARTF_USESTDHANDLES,

        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
    };
    var piProcInfo: windows.PROCESS_INFORMATION = undefined;
    const cmdline = try std.mem.join(allocator, " ", params.args);
    defer allocator.free(cmdline);

    const cmdlineW = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmdline);
    defer allocator.free(cmdlineW);

    return windows.CreateProcessW(
        null,
        cmdlineW.ptr,
        null,
        null,
        windows.TRUE,
        windows.CREATE_UNICODE_ENVIRONMENT | CreationFlags.DETACHED_PROCESS,
        null,
        null,
        &siStartInfo,
        &piProcInfo,
    );
}

fn startProcessPosix(allocator: std.mem.Allocator, params: StartProcess) !void {
    const dev_null_fd = posix.openZ("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch |err| switch (err) {
        error.PathAlreadyExists => unreachable,
        error.NoSpaceLeft => unreachable,
        error.FileTooBig => unreachable,
        error.DeviceBusy => unreachable,
        error.FileLocksNotSupported => unreachable,
        error.BadPathName => unreachable, // Windows-only
        error.WouldBlock => unreachable,
        error.NetworkNotFound => unreachable, // Windows-only
        else => |e| return e,
    };
    defer posix.close(dev_null_fd);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const argvZ = try arena.allocator().allocSentinel(?[*:0]const u8, params.args.len, null);
    for (params.args, 0..) |arg, i| argvZ[i] = (try arena.allocator().dupeZ(u8, arg)).ptr;

    const envp = try std.process.createEnvironFromExisting(arena.allocator(), @ptrCast(std.os.environ.ptr), .{});

    const pid_result = try posix.fork();

    if (pid_result == 0) {
        try posix.dup2(dev_null_fd, posix.STDIN_FILENO);
        try posix.dup2(dev_null_fd, posix.STDOUT_FILENO);
        try posix.dup2(dev_null_fd, posix.STDERR_FILENO);

        return posix.execvpeZ(argvZ[0].?, argvZ.ptr, envp.ptr);
    }
}
