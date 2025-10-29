const std = @import("std");

// TODO: Figure out how to use `std.json.Reader`.

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
        // std.log.debug("Received stdin line: {s}", .{line[0..line.len]});

        const parsed = try std.json.parseFromSlice(Message, arena, line, .{});
        defer parsed.deinit();
        const init = parsed.value;
        std.log.debug("I am node {s}", .{init.body.init.node_id});
        const joined = try std.mem.join(arena, ", ", init.body.init.node_ids);
        defer arena.free(joined);
        std.log.debug("Nodes in cluster: {s}", .{joined});

        const response = Message{
            .src = init.body.init.node_id,
            .dest = init.src,
            .body = .{ .init_ok = .{
                .type = .init_ok,
                .in_reply_to = init.body.init.msg_id,
            } },
        };
        const response_formatted = std.json.fmt(response, .{ .emit_null_optional_fields = false });
        // std.log.debug("Sending stdout line: {f}", .{response_formatted});
        try stdout.print("{f}\n", .{response_formatted});
        break :id try arena.dupe(u8, init.body.init.node_id);
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
            .body = .{ .echo_ok = .{
                .type = .echo_ok,
                .msg_id = new_id(),
                .in_reply_to = message.body.echo.msg_id,
                .echo = message.body.echo.echo,
            } },
        };
        const response_formatted = std.json.fmt(response, .{ .emit_null_optional_fields = false });
        std.log.debug("Sending stdout line: {f}", .{response_formatted});
        try stdout.print("{f}\n", .{response_formatted});
    }

    std.log.debug("{s}", .{"some info"});
}

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

// TODO: Can we create the Body type from a list of types (maybe anonymous as below) and have the
// `type` fields and values and the `msg_id` field automatically added? Could have an interface like
// this:
//
// const _ = BodyFromKinds(.{
//     .init = struct { node_id: usize, node_ids: []usize },
//     .echo = struct { echo: []const u8 },
// });

pub const Message = struct {
    id: ?usize = null, // maelstrom includes this field on init for some reason
    src: []const u8,
    dest: []const u8,
    body: Body,

    pub const Kind = enum {
        init,
        init_ok,
        echo,
        echo_ok,
    };

    pub const Body = union(Kind) {
        init: struct {
            type: Kind = .init,
            msg_id: usize,
            node_id: []const u8,
            node_ids: []const []const u8,
        },
        init_ok: struct {
            type: Kind = .init_ok,
            in_reply_to: usize,
        },
        echo: struct {
            type: Kind = .echo,
            msg_id: usize,
            echo: []const u8,
        },
        echo_ok: struct {
            type: Kind = .echo_ok,
            msg_id: usize,
            echo: []const u8,
            in_reply_to: usize,
        },

        /// Define the parsing of this tagged union (as opposed to using the default) because the
        /// expected schema does not nest the object under the tag.
        ///
        /// Zig expects something like (note the first "echo" key):
        ///
        /// ```
        /// {
        ///   "src": "c1",
        ///   "dest": "n1",
        ///   "body": {
        ///     "echo": {
        ///       "type": "echo",
        ///       "msg_id": 1,
        ///       "echo": "Please echo 35"
        ///     }
        ///   }
        /// }
        /// ```
        ///
        /// but we get something like this:
        ///
        /// ```
        /// {
        ///   "src": "c1",
        ///   "dest": "n1",
        ///   "body": {
        ///     "type": "echo",
        ///     "msg_id": 1,
        ///     "echo": "Please echo 35"
        ///   }
        /// }
        /// ```
        ///
        /// To parse, we can first check the `Kind` assigned to "type" (which is always included)
        /// and parse the value as the type it corresponds to.
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !@This() {
            const value = try std.json.Value.jsonParse(allocator, source, options);
            const kind = value.object.get("type").?.string;

            // If a field in the union matches the "type" of this object, serialise the object as
            // the type that `kind` corresponds to. This relies on the `Message.Kind` tag
            // (`field.name`) matching the value of "type".
            const type_info = @typeInfo(@This()).@"union";
            inline for (type_info.fields) |field| if (std.mem.eql(u8, field.name, kind)) {
                return @unionInit(
                    @This(),
                    field.name,
                    try std.json.innerParseFromValue(field.type, allocator, value, options),
                );
            };

            return error.UnknownField;
        }

        /// Define serialisation for the same reasons deserialisation was defined above. Instead of
        /// nesting this tagged union's value in a tag key (the default), write the value directly.
        pub fn jsonStringify(this: @This(), writer: anytype) !void {
            switch (this) {
                inline else => |body| try writer.write(body),
            }
        }
    };
};

/// Serialise the value to JSON (with indentation) returning a slice. The caller is responsible for
/// freeing the slice with `std.testing.allocator.free`.
fn allocPrintJson(
    value: anytype,
) ![]const u8 {
    return try std.fmt.allocPrint(
        std.testing.allocator,
        "{f}",
        .{std.json.fmt(value, .{ .whitespace = .indent_2 })},
    );
}

test "tag values are serialised as strings" {
    const E = enum { a, b };
    const S = struct { tag: E = .a };

    const j = try allocPrintJson(S{});
    defer std.testing.allocator.free(j);

    try std.testing.expectEqualStrings(
        \\{
        \\  "tag": "a"
        \\}
    , j);
}

test "stringified tagged unions nest value under tag" {
    const Msg = struct {
        src: []const u8,
        dest: []const u8,
        body: Body,

        const Kind = enum { init, echo };

        const Body = union(Kind) {
            init: struct {
                type: Kind = .init,
                msg_id: usize,
                node_id: []const u8,
                node_ids: []const []const u8,
            },
            echo: struct {
                type: Kind = .echo,
                msg_id: usize,
                echo: []const u8,
            },
        };
    };

    const m = Msg{
        .src = "c1",
        .dest = "n1",
        .body = .{
            .echo = .{
                .type = .echo,
                .msg_id = 1,
                .echo = "Please echo 35",
            },
        },
    };
    const j = try allocPrintJson(m);
    defer std.testing.allocator.free(j);

    try std.testing.expectEqualStrings(
        \\{
        \\  "src": "c1",
        \\  "dest": "n1",
        \\  "body": {
        \\    "echo": {
        //    ^ This is the nesting we want to avoid.
        \\      "type": "echo",
        \\      "msg_id": 1,
        \\      "echo": "Please echo 35"
        \\    }
        \\  }
        \\}
    , j);
}

test "serialise" {
    const m: Message = .{
        .src = "c1",
        .dest = "n1",
        .body = .{
            .init = .{
                .type = .init,
                .msg_id = 1,
                .node_id = "n1",
                .node_ids = &.{ "n1", "n2", "n3" },
            },
        },
    };

    const j = try allocPrintJson(m);
    defer std.testing.allocator.free(j);

    try std.testing.expectEqualStrings(
        \\{
        \\  "src": "c1",
        \\  "dest": "n1",
        \\  "body": {
        \\    "type": "init",
        \\    "msg_id": 1,
        \\    "node_id": "n1",
        \\    "node_ids": [
        \\      "n1",
        \\      "n2",
        \\      "n3"
        \\    ]
        \\  }
        \\}
    , j);
}

test "deserialise" {
    const parsed = try std.json.parseFromSlice(Message, std.testing.allocator,
        \\{
        \\  "src": "c1",
        \\  "dest": "n1",
        \\  "body": {
        \\    "type": "echo",
        \\    "msg_id": 1,
        \\    "echo": "Please echo 35"
        \\  }
        \\}
    , .{});
    defer parsed.deinit();
    const m = parsed.value;

    try std.testing.expectEqualStrings("c1", m.src);
    try std.testing.expectEqualStrings("n1", m.dest);
    try std.testing.expectEqual(.echo, m.body.echo.type);
    try std.testing.expectEqual(1, m.body.echo.msg_id);
    try std.testing.expectEqualStrings("Please echo 35", m.body.echo.echo);
}
