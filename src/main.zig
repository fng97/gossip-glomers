const std = @import("std");

// TODO: Figure out how to use `std.json.Reader.init`: `std.json.parseFromTokenSource`.
// TODO: If I'm sticking with the arena allocator, I should use the `Leaky` `json` methods.

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = logFn };

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    const stdin = &stdin_reader.interface;

    // TODO: Use a buffered writer. When do you flush?
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    var node: Node = try .init(arena, stdin, stdout);
    defer node.deinit();

    while (true) try node.tick();

    @panic("Exited event loop");
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

// TODO: Use *reflection* to create the Body union from a list of structs (maybe anonymous as
// below). It should use the `type` field to determine the union tag. Maybe worth sticking in
// `mst_id` by default? Same for `in_reply_to` where the tag has `_ok`? Could have an interface like
// this:
//
// const _ = BodyFromKinds(.{
//     struct { kind: Kind = .init, node_id: usize, node_ids: []usize },
//     struct { kind: Kind = .echo, echo: []const u8 },
// });

const Node = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    id: []const u8,
    /// Counter for IDs for messages sent from this node.
    msg_count: usize = 1,

    fn recv(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Message {
        const line = try reader.takeDelimiterInclusive('\n');
        const parsed = try std.json.parseFromSlice(Message, allocator, line, .{
            // Maelstrom includes a top-level "id" field on init for some reason.
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return parsed.value;
    }

    fn send(n: *Node, msg: Message) !void {
        try n.writer.print("{f}\n", .{std.json.fmt(msg, .{})});
    }

    /// Read initialisation message, set node ID, and respond with `init_ok`.
    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) !Node {
        const msg = try recv(allocator, reader);

        std.log.debug("Received init msg. I am node {s}", .{msg.body.init.node_id});
        const other_nodes = try std.mem.join(allocator, ", ", msg.body.init.node_ids);
        defer allocator.free(other_nodes);
        std.log.debug("Nodes in cluster: {s}", .{other_nodes});

        var n: Node = .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .id = try allocator.dupe(u8, msg.body.init.node_id),
        };

        // Reply with init_ok ack.
        try n.send(.{
            .src = msg.body.init.node_id,
            .dest = msg.src,
            .body = .{
                .init_ok = .{
                    .type = .init_ok,
                    .in_reply_to = msg.body.init.msg_id,
                },
            },
        });

        return n;
    }

    pub fn tick(n: *Node) !void {
        const msg = try recv(n.allocator, n.reader);

        switch (msg.body) {
            .echo => |b| try n.send(.{
                .src = n.id,
                .dest = msg.src,
                .body = .{
                    .echo_ok = .{
                        .msg_id = n.msg_id(),
                        .in_reply_to = b.msg_id,
                        .echo = b.echo,
                    },
                },
            }),
            .generate => |b| try n.send(.{
                .src = n.id,
                .dest = msg.src,
                .body = .{
                    .generate_ok = .{
                        .msg_id = n.msg_id(),
                        .in_reply_to = b.msg_id,
                        .id = new_id(),
                    },
                },
            }),
            .init => unreachable,
            .echo_ok, .init_ok, .generate_ok => unreachable,
        }
    }

    pub fn deinit(n: *Node) void {
        n.allocator.free(n.id);
    }

    fn msg_id(n: *Node) usize {
        const id = n.msg_count;
        n.msg_count += 1;
        return id;
    }

    fn new_id() usize {
        return std.crypto.random.int(usize);
    }
};

const Message = struct {
    src: []const u8,
    dest: []const u8,
    body: Body,

    /// The message type. We're calling it `Kind` because `type` is a Zig keyword. These *must*
    /// match the `"type"` strings in the message `"body"` object.
    const Kind = enum {
        init,
        init_ok,
        echo,
        echo_ok,
        generate,
        generate_ok,
    };

    const Body = union(enum) {
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
        generate: struct {
            type: Kind = .generate,
            msg_id: usize,
        },
        generate_ok: struct {
            type: Kind = .generate_ok,
            msg_id: usize,
            in_reply_to: usize,
            id: usize,
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
        ) !Body {
            const value = try std.json.Value.jsonParse(allocator, source, options);
            const kind = value.object.get("type").?.string;

            // If a field in the union matches the "type" of this object, serialise the object as
            // the type that `kind` corresponds to. This relies on the `Message.Kind` tag
            // (`field.name`) matching the value of "type".
            const type_info = @typeInfo(Body).@"union";
            inline for (type_info.fields) |field| if (std.mem.eql(u8, field.name, kind)) {
                return @unionInit(
                    Body,
                    field.name,
                    try std.json.innerParseFromValue(field.type, allocator, value, options),
                );
            };

            return error.UnknownField;
        }

        /// Define serialisation for the same reasons deserialisation was defined above. Instead of
        /// nesting this tagged union's value in a tag key (the default), write the value directly.
        pub fn jsonStringify(b: Body, writer: anytype) !void {
            switch (b) {
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
