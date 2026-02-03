const std = @import("std");
const config = @import("config");

test "echo workload" {
    var child = std.process.Child.init(&.{
        "maelstrom",                 "test",
        "--workload",                "echo",
        "--rate",                    "50",
        "--node-count",              "1",
        "--time-limit",              "3",
        "--bin=" ++ config.exe_path,
    }, std.testing.allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    const term = try child.spawnAndWait();
    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
}
