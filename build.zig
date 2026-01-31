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

    const echo_step = b.step("echo", "Run echo workload");
    const echo = b.addSystemCommand(&.{
        "maelstrom",    "test",
        "--workload",   "echo",
        "--rate",       "50",
        "--node-count", "1",
        "--time-limit", "3",
    });
    echo.addPrefixedArtifactArg("--bin=", exe);
    echo_step.dependOn(&echo.step);

    const generate_step = b.step("generate", "Run generate workload");
    const generate = b.addSystemCommand(&.{
        "maelstrom",      "test",
        "--workload",     "unique-ids",
        "--rate",         "10000",
        "--node-count",   "3",
        "--time-limit",   "3",
        "--availability", "total",
        "--nemesis",      "partition",
    });
    generate.addPrefixedArtifactArg("--bin=", exe);
    generate_step.dependOn(&generate.step);

    const broadcast_step = b.step("broadcast", "Run broadcast workload");
    const broadcast_a = b.addSystemCommand(&.{
        "maelstrom",    "test",
        "--workload",   "broadcast",
        "--rate",       "100",
        "--node-count", "1",
        "--time-limit", "3",
    });
    broadcast_a.addPrefixedArtifactArg("--bin=", exe);
    broadcast_step.dependOn(&broadcast_a.step);
}
