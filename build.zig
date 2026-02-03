const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const node_exe = b.addExecutable(.{
        .name = "gossip_glomers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(node_exe);

    const test_step = b.step("test", "Run tests");
    const node_tests = b.addTest(.{ .name = "node", .root_module = node_exe.root_module });
    const node_tests_run = b.addRunArtifact(node_tests);
    test_step.dependOn(&node_tests_run.step);
    const ctx = .{
        .b = b,
        .test_step = test_step,
        .node_exe = node_exe,
        .target = target,
        .optimize = optimize,
    };
    add_maelstrom_test(ctx, "src/echo.zig");
    add_maelstrom_test(ctx, "src/generate.zig");
    add_maelstrom_test(ctx, "src/broadcast.zig");
}

fn add_maelstrom_test(
    ctx: anytype,
    test_file: []const u8,
) void {
    const tests = ctx.b.addTest(.{
        .name = std.fs.path.stem(test_file),
        .root_module = ctx.b.createModule(.{
            .root_source_file = ctx.b.path(test_file),
            .target = ctx.target,
            .optimize = ctx.optimize,
        }),
    });
    const tests_run = ctx.b.addRunArtifact(tests);

    // Pass the node_exe install path to the maelstrom tests.
    const options = ctx.b.addOptions();
    options.addOption([]const u8, "exe_path", ctx.b.getInstallPath(.bin, ctx.node_exe.name));
    tests.root_module.addOptions("config", options);
    tests_run.step.dependOn(ctx.b.getInstallStep()); // ensure node_exe installed

    ctx.test_step.dependOn(&tests_run.step);
}
