const std = @import("std");
const builtin = @import("builtin");
const simargs = @import("simargs");
const package = @import("package");

const windows = std.os.windows;
const posix = std.posix;

var timer: std.time.Timer = undefined;

const TOTAL_MEMORY_SIZE = 1024 * 12; // hard limit of 4 KB
const PRETTIERXD_SOCKET_FILENAME = "prettierxd.sock";

pub const CliArgs = struct {
    @"range-start": i32 = -1,
    @"range-end": i32 = -1,
    ignorePath: []const u8 = ".prettierignore",
    version: bool = false,
};

pub fn main() !void {
    if (builtin.mode == .Debug) {
        timer = std.time.Timer.start() catch unreachable;
    }

    var alloc_buffer: [TOTAL_MEMORY_SIZE]u8 = undefined;
    var gpa = std.heap.FixedBufferAllocator.init(&alloc_buffer);
    debugLog("allocated {d} buffer", .{std.fmt.fmtIntSizeBin(alloc_buffer.len)});

    const cli = try simargs.parse(gpa.allocator(), CliArgs, null, package.version);
    if (cli.positional_args.len == 0) {
        std.debug.print("No filename provided\n", .{});
        return;
    }

    const socketFilename = try getSocketFilename(gpa.allocator());
    const filename = cli.positional_args[0];
    debugLog("filename: {s}", .{filename});
    const isAbsolute = std.fs.path.isAbsolute(filename);
    const fullPath = if (!isAbsolute) try std.fs.path.resolve(gpa.allocator(), &.{ try std.process.getCwdAlloc(gpa.allocator()), filename }) else filename;

    const range = .{
        .start = cli.args.@"range-start",
        .end = cli.args.@"range-end",
    };
    debugLog("fullPath: {s}, range: {}", .{ fullPath, range });

    const stream = try connectToPrettierDaemon(gpa.allocator(), socketFilename);
    defer stream.close();

    debugLog("connected, waiting for stdin", .{});
    const stdin = std.io.getStdIn();
    debugLog("connected to socket", .{});

    const buf = try gpa.allocator().alloc(u8, 1024);
    try stream.writeAll(fullPath);
    try stream.writeAll(&.{0});
    try std.fmt.format(stream.writer(), "{d},{d}", .{ range.start, range.end });
    try stream.writeAll(&.{0});
    try stream.writeAll(cli.args.ignorePath);
    try stream.writeAll(&.{0});
    try streamUntilEof(stdin.reader(), stream.writer(), buf);
    try stream.writeAll(&.{0});

    debugLog("waiting for response", .{});
    try streamUntilDelimiter(stream.reader(), std.io.getStdOut().writer(), buf, 0);

    debugLog("memory left: {d:.2} / {d:.2}", .{ std.fmt.fmtIntSizeBin(alloc_buffer.len - gpa.end_index), std.fmt.fmtIntSizeBin(TOTAL_MEMORY_SIZE) });
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .Debug) return;

    const time = timer.read();
    const stdout = std.io.getStdOut().writer();
    stdout.writeAll("debug: ") catch @panic("failed to write to stdout");
    std.fmt.format(stdout, fmt, args) catch @panic("failed to write to stdout");
    //const timeArgs = if (time < 1_000_000) .{ time / 1_000, "ns" } else .{ time / 1_000_000, "ms" };
    const timeArgs = .{ time / 1_000, "μs" };
    std.fmt.format(stdout, " [{d}{s} elapsed]\n", timeArgs) catch @panic("failed to write to stdout");
}

fn streamUntilEof(source_reader: anytype, dest_writer: anytype, buf: []u8) !void {
    while (true) {
        const read = try source_reader.read(buf);
        debugLog("read {d}", .{read});

        try dest_writer.writeAll(buf[0..read]);

        if (read < buf.len or read == 0) break;
    }
}

fn streamUntilDelimiter(
    source: anytype,
    writer: anytype,
    buf: []u8,
    delimiter: u8,
) anyerror!void {
    while (true) {
        const len = try source.read(buf);
        debugLog("read {d}", .{len});
        if (len == 0) return;
        if (buf[len - 1] == delimiter) {
            _ = try writer.write(buf[0 .. len - 1]);
            return;
        }
        _ = try writer.write(buf[0..len]);
    }
}

fn getSocketFilename(gpa: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const socketFilename = try std.fs.path.join(gpa, &.{ "\\\\?\\pipe", PRETTIERXD_SOCKET_FILENAME });
        return socketFilename;
    }

    const tmpDir = std.posix.getenv("TMPDIR") orelse "/tmp";
    const socketFilename = try std.fs.path.join(gpa, &.{ tmpDir, PRETTIERXD_SOCKET_FILENAME });

    return socketFilename;
}

pub const DaemonStream = if (builtin.os.tag == .windows) std.fs.File else std.net.Stream;

fn connectToPrettierDaemon(gpa: std.mem.Allocator, socketFilename: []const u8) !DaemonStream {
    const stream = connectToSocket(socketFilename) catch |err| switch (err) {
        error.ConnectionRefused,
        error.FileNotFound,
        => {
            debugLog("connection refused, restarting prettier daemon", .{});
            return startPrettierDaemon(gpa, socketFilename);
        },
        else => return err,
    };
    return stream;
}

fn connectToSocket(socketFilename: []const u8) anyerror!DaemonStream {
    debugLog("connecting to socket {s}", .{socketFilename});
    return switch (builtin.os.tag) {
        .windows => try std.fs.createFileAbsolute(socketFilename, .{ .read = true }),
        .linux, .macos => std.net.connectUnixSocket(socketFilename),
        else => @compileError("unsupported os"),
    };
}

fn startPrettierDaemon(gpa: std.mem.Allocator, socketFilename: []const u8) !DaemonStream {
    const exec_file = try std.fs.selfExeDirPathAlloc(gpa);
    debugLog("exec file dir: {s}", .{exec_file});

    // We test for zig-out, because on Windows linking is different
    // On Windows linking is fucked, so we just copy the exec next to node.exe
    // On Linux/Mac Nodejs is simlinking as usual which means exeDirPath() points to exec in zig-out
    const daemonFile = if (std.mem.indexOf(u8, exec_file, "zig-out")) |_| "../../index.js" else "node_modules/prettierxd/index.js";
    const server_file = try std.fs.path.resolve(gpa, &[_][]const u8{ exec_file, daemonFile });
    debugLog("server file: {s}", .{server_file});
    const args = .{ "node", server_file } ++ if (builtin.mode == .Debug) .{} else .{"--debug"};

    try startProcess(gpa, .{
        .args = &args,
    });

    debugLog("child process spawned", .{});
    return try waitUntilDeamonReady(socketFilename);
}

fn waitUntilDeamonReady(socketFilename: []const u8) !DaemonStream {
    debugLog("waiting for socket", .{});
    var stream: DaemonStream = undefined;
    while (true) {
        stream = connectToSocket(socketFilename) catch |err| switch (err) {
            error.ConnectionRefused,
            error.FileNotFound,
            => {
                debugLog("error: {s}", .{@errorName(err)});
                if (builtin.mode == .Debug) std.time.sleep(std.time.ns_per_ms * 1000);
                continue;
            },
            else => return err,
        };
        break;
    }

    debugLog("socket connected", .{});
    return stream;
}

fn startProcess(allocator: std.mem.Allocator, params: StartProcess) !void {
    debugLog("startProcess, cwd: {s}", .{try std.process.getCwdAlloc(allocator)});
    return switch (builtin.os.tag) {
        .windows => try startProcessWindows(allocator, params),
        .linux, .macos => try startProcessPosix(allocator, params),
        else => @compileError("unsupported os"),
    };
}

pub const StartProcess = struct {
    args: []const []const u8,
};

pub const DETACHED_PROCESS = 0x00000008;

fn startProcessWindows(gpa: std.mem.Allocator, params: StartProcess) !void {
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
        .hStdError = if (builtin.mode == .Debug) try windows.GetStdHandle(windows.STD_ERROR_HANDLE) else null_pipe,
        .hStdOutput = if (builtin.mode == .Debug) try windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) else null_pipe,
        .hStdInput = if (builtin.mode == .Debug) try windows.GetStdHandle(windows.STD_INPUT_HANDLE) else null_pipe,
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

    const cmdline = try std.mem.join(gpa, " ", params.args);
    const cmdlineW = try std.unicode.utf8ToUtf16LeAllocZ(gpa, cmdline);

    return windows.CreateProcessW(
        null,
        cmdlineW.ptr,
        null,
        null,
        windows.TRUE,
        if (builtin.mode == .Debug) windows.CREATE_UNICODE_ENVIRONMENT else windows.CREATE_UNICODE_ENVIRONMENT | DETACHED_PROCESS,
        null,
        null,
        &siStartInfo,
        &piProcInfo,
    );
}

fn startProcessPosix(gpa: std.mem.Allocator, params: StartProcess) !void {
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

    const argvZ = try gpa.allocSentinel(?[*:0]const u8, params.args.len, null);
    for (params.args, 0..) |arg, i| argvZ[i] = (try gpa.dupeZ(u8, arg)).ptr;

    const envp = try std.process.createEnvironFromExisting(gpa, @ptrCast(std.os.environ.ptr), .{});

    const pid_result = try posix.fork();

    if (pid_result == 0) {
        if (builtin.mode != .Debug) {
            // Only Linux has setsid (and only Linux needs it, Mac is fine without it)
            if (builtin.os.tag == .linux) {
                _ = std.os.linux.setsid();
            }
            try posix.dup2(dev_null_fd, posix.STDIN_FILENO);
            try posix.dup2(dev_null_fd, posix.STDOUT_FILENO);
            try posix.dup2(dev_null_fd, posix.STDERR_FILENO);
        }

        return posix.execvpeZ(argvZ[0].?, argvZ.ptr, envp.ptr);
    }
}
