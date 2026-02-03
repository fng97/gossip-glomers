const std = @import("std");
const config = @import("config");

test "generate workload" {
    var child = std.process.Child.init(&.{
        "maelstrom",                 "test",
        "--workload",                "unique-ids",
        "--rate",                    "10000",
        "--node-count",              "3",
        "--time-limit",              "3",
        "--availability",            "total",
        "--nemesis",                 "partition",
        "--bin=" ++ config.exe_path,
    }, std.testing.allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
}
