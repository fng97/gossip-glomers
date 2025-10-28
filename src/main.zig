// TODO: Use atomic for global message counter.

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = logFn };

var message_count = std.atomic.Value(usize).init(1);
pub fn new_id() usize {
    return message_count.fetchAdd(1, .monotonic);
}

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    // Handle initialisation message: parse node ID and respond with `init_ok`.
    const node_id: []const u8 = id: {
        const line = try stdin.takeDelimiterInclusive('\n');
        std.log.debug("Received stdin line: {s}", .{line});

        const parsed = try std.json.parseFromSlice(Message, arena, line, .{});
        defer parsed.deinit();
        const init = parsed.value;
        std.log.debug("I am node {s}", .{init.body.node_id.?});
        const joined = try std.mem.join(arena, ", ", init.body.node_ids.?);
        defer arena.free(joined);
        std.log.debug("Nodes in cluster: {s}", .{joined});

        const response = Message{
            .src = init.body.node_id.?,
            .dest = init.src,
            .body = .{
                .type = "init_ok",
                .in_reply_to = init.body.msg_id.?,
            },
        };
        const response_formatted = std.json.fmt(response, .{ .emit_null_optional_fields = false });
        std.log.debug("Sending stdout line: {f}", .{response_formatted});
        try stdout.print("{f}\n", .{response_formatted});
        break :id try arena.dupe(u8, init.body.node_id.?);
    };

    while (true) {
        const line = try stdin.takeDelimiterInclusive('\n');
        std.log.debug("Received stdin line: {s}", .{line});

        const parsed = try std.json.parseFromSlice(
            Message,
            arena,
            line,
            .{},
        );
        defer parsed.deinit();
        const message = parsed.value;

        const response = Message{
            .src = node_id,
            .dest = message.src,
            .body = .{
                .type = "echo_ok",
                .msg_id = new_id(),
                .in_reply_to = message.body.msg_id,
                .echo = message.body.echo,
            },
        };
        const response_formatted = std.json.fmt(response, .{ .emit_null_optional_fields = false });
        std.log.debug("Sending stdout line: {f}", .{response_formatted});
        try stdout.print("{f}\n", .{response_formatted});
    }

    std.log.debug("{s}", .{"some info"});
}

const Message = struct {
    // TODO: If these nodes are always two characters could represnet them with an enum or just a
    // [2]const u8.
    id: ?usize = null,
    src: []const u8,
    dest: []const u8,
    body: Body,

    const Body = struct {
        type: []const u8,
        node_id: ?[]const u8 = null,
        node_ids: ?[]const []const u8 = null,
        msg_id: ?usize = null,
        in_reply_to: ?usize = null,
        echo: ?[]const u8 = null,
    };
};

/// See https://ziglang.org/documentation/0.15.2/std/#std.log.
fn logFn(
    comptime level: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ comptime level.asText() ++ "] ";
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    nosuspend stderr_writer.interface.print(prefix ++ format ++ "\n", args) catch return;
}

test "parse echo" {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(
        Message,
        arena,
        \\{
        \\  "src": "c1",
        \\  "dest": "n1",
        \\  "body": {
        \\    "type": "echo",
        \\    "msg_id": 1,
        \\    "echo": "Please echo 35"
        \\  }
        \\}
    ,
        .{},
    );
    defer parsed.deinit();
    const msg = parsed.value;

    try std.testing.expectEqualStrings("c1", msg.src);
    try std.testing.expectEqualStrings("n1", msg.dest);
    try std.testing.expectEqualStrings("echo", msg.body.type);
    try std.testing.expectEqual(1, msg.body.msg_id);
    try std.testing.expectEqualStrings("Please echo 35", msg.body.echo.?);

    std.debug.print("{}\n", .{msg});
}

const std = @import("std");
