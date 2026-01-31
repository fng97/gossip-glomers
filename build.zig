const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "gossip_glomers",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
    const echo = b.addSystemCommand(&.{
        "maelstrom",    "test",
        "--workload",   "echo",
        "--node-count", "1",
        "--time-limit", "10",
    });
    echo.addPrefixedArtifactArg("--bin=", exe);
    test_step.dependOn(&echo.step);
    const unique_ids = b.addSystemCommand(&.{
        "maelstrom",      "test",
        "--workload",     "unique-ids",
        "--rate",         "1000",
        "--node-count",   "3",
        "--time-limit",   "30",
        "--availability", "total",
        "--nemesis",      "partition",
    });
    unique_ids.addPrefixedArtifactArg("--bin=", exe);
    test_step.dependOn(&unique_ids.step);
    const broadcast_a = b.addSystemCommand(&.{
        "maelstrom",    "test",
        "--workload",   "broadcast",
        "--rate",       "10",
        "--node-count", "1",
        "--time-limit", "20",
    });
    broadcast_a.addPrefixedArtifactArg("--bin=", exe);
    test_step.dependOn(&broadcast_a.step);
}
