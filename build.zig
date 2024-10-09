const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigcli = b.dependency("zigcli", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "prettierxd",
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pckgJson = readPckgJson(b) catch @panic("failed to read package.json");
    const options = b.addOptions();
    options.addOption([]const u8, "name", pckgJson.name);
    options.addOption([]const u8, "version", pckgJson.version);
    std.debug.assert(std.mem.eql(u8, pckgJson.name, "prettierxd"));

    exe.root_module.addImport("package", options.createModule());
    exe.root_module.addImport("simargs", zigcli.module("simargs"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("package", options.createModule());
    exe_unit_tests.root_module.addImport("simargs", zigcli.module("simargs"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

pub const PckgJson = struct {
    name: []const u8,
    version: []const u8,
};

fn readPckgJson(b: *std.Build) !PckgJson {
    const file = std.fs.cwd().openFile("package.json", .{}) catch @panic("failed to open package.json");
    defer file.close();

    const content = try file.readToEndAlloc(b.allocator, std.math.maxInt(usize));

    return std.json.parseFromSliceLeaky(PckgJson, b.allocator, content, .{
        .ignore_unknown_fields = true,
    });
}
