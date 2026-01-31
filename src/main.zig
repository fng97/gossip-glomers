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

    // TODO: Use a buffered writer. When do you flush? End of tick?
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    var node: Node = try .init(arena, stdin, stdout);
    defer node.deinit();

    while (true) try node.tick();

    @panic("Exited event loop");
}

// Messages are sent and received from stdout and stdin respectively. Logs go to stderr so override
// the default logger (uses stdout).
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

const Node = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    id: []const u8,
    // peers: []const []const u8,
    /// Counter for IDs for messages sent from this node.
    msg_count: usize = 1,
    msgs: std.ArrayList(isize) = .empty,

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

        std.log.debug("Received init msg. I am node {s}", .{msg.body.extra.init.node_id});
        const other_nodes = try std.mem.join(allocator, ", ", msg.body.extra.init.node_ids);
        defer allocator.free(other_nodes);
        std.log.debug("Nodes in cluster: {s}", .{other_nodes});

        var n: Node = .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .id = try allocator.dupe(u8, msg.body.extra.init.node_id),
            // .peers = try allocator.dupe(u8, msg.body.extra.init.node_ids),
        };

        // Reply with init_ok ack.
        try n.send(.{
            .src = msg.body.extra.init.node_id,
            .dest = msg.src,
            .body = .{
                .type = .init_ok,
                .in_reply_to = msg.body.msg_id,
                .extra = .{ .init_ok = .{} },
            },
        });

        return n;
    }

    pub fn deinit(n: *Node) void {
        n.allocator.free(n.id);
        defer n.msgs.deinit(n.allocator);
        // n.allocator.free(n.peers);
    }

    pub fn tick(n: *Node) !void {
        const msg = try recv(n.allocator, n.reader);

        switch (msg.body.extra) {
            .echo => |e| try n.send(.{
                .src = n.id,
                .dest = msg.src,
                .body = .{
                    .type = .echo_ok,
                    .msg_id = n.msg_id(),
                    .in_reply_to = msg.body.msg_id,
                    .extra = .{ .echo_ok = .{ .echo = e.echo } },
                },
            }),
            .generate => try n.send(.{
                .src = n.id,
                .dest = msg.src,
                .body = .{
                    .type = .generate_ok,
                    .msg_id = n.msg_id(),
                    .in_reply_to = msg.body.msg_id,
                    .extra = .{ .generate_ok = .{ .id = new_id() } },
                },
            }),
            .broadcast => |b| {
                try n.msgs.append(n.allocator, b.message);
                try n.send(.{
                    .src = n.id,
                    .dest = msg.src,
                    .body = .{
                        .type = .broadcast_ok,
                        .msg_id = n.msg_id(),
                        .in_reply_to = msg.body.msg_id,
                        .extra = .{ .broadcast_ok = .{} },
                    },
                });
            },
            .topology => try n.send(.{
                .src = n.id,
                .dest = msg.src,
                .body = .{
                    // TODO: Store topology? Don't we get this at the start?
                    .type = .topology_ok,
                    .msg_id = n.msg_id(),
                    .in_reply_to = msg.body.msg_id,
                    .extra = .{ .topology_ok = .{} },
                },
            }),
            .read => try n.send(.{
                .src = n.id,
                .dest = msg.src,
                .body = .{
                    .type = .read_ok,
                    .msg_id = n.msg_id(),
                    .in_reply_to = msg.body.msg_id,
                    .extra = .{ .read_ok = .{ .messages = n.msgs.items } },
                },
            }),
            .init => @panic("Received second init message"),
            .echo_ok,
            .init_ok,
            .generate_ok,
            .broadcast_ok,
            .read_ok,
            .topology_ok,
            => std.debug.panic("Received unexpected message: {s}", .{@tagName(msg.body.extra)}),
        }
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
        broadcast,
        broadcast_ok,
        read,
        read_ok,
        topology,
        topology_ok,
    };

    const Body = struct {
        type: Kind,
        msg_id: ?usize = null,
        in_reply_to: ?usize = null,
        extra: Extra,

        const Extra = union(Kind) {
            init: struct {
                node_id: []const u8,
                node_ids: []const []const u8,
            },
            init_ok: struct {},
            echo: struct {
                echo: []const u8,
            },
            echo_ok: struct {
                echo: []const u8,
            },
            generate: struct {},
            generate_ok: struct {
                id: usize,
            },
            broadcast: struct {
                message: isize,
            },
            broadcast_ok: struct {},
            read: struct {},
            read_ok: struct {
                messages: []isize,
            },
            topology: struct {
                // TODO: Use tags for node/client ids? Ignore for now.
                // topology: []struct {},
            },
            topology_ok: struct {},

            // FIXME: Fix these docs.
            /// Define the parsing of this tagged union. The default parsinge expects the object to
            /// be nested under the tag but the extra fields exist in the parent object. The parent
            /// Body struct will parse common fields (type, msg_id, in_reply_to) using defaults, and
            /// we handle the tag-specific fields here based on the "type" field.
            pub fn jsonParseFromValue(
                allocator: std.mem.Allocator,
                value: std.json.Value,
                options: std.json.ParseOptions,
            ) !Extra {
                const kind = value.object.get("type").?.string;

                // If a field in the union matches the "type" of this object, parse the object as
                // the type that `kind` corresponds to.
                const type_info = @typeInfo(Extra).@"union";
                inline for (type_info.fields) |field| if (std.mem.eql(u8, field.name, kind)) {
                    return @unionInit(
                        Extra,
                        field.name,
                        try std.json.innerParseFromValue(field.type, allocator, value, options),
                    );
                };

                return error.UnknownField;
            }

            /// Define serialisation for the same reasons deserialisation was defined above. Instead
            /// of nesting this tagged union's value in a tag key (the default), write the value
            /// directly.
            pub fn jsonStringify(e: Extra, writer: anytype) !void {
                switch (e) {
                    inline else => |extra| try writer.write(extra),
                }
            }
        };

        /// Define custom parsing to handle flattened structure. The JSON has all fields
        /// at the same level, so we parse common fields and delegate extra fields to Extra.
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) !Body {
            // Parse the entire value first
            const value = try std.json.Value.jsonParse(allocator, source, options);
            const obj = value.object;

            // Extract common fields
            const kind_str = obj.get("type").?.string;
            const kind = std.meta.stringToEnum(Kind, kind_str) orelse return error.UnknownField;
            const msg_id = if (obj.get("msg_id")) |v| @as(usize, @intCast(v.integer)) else null;
            const in_reply_to = if (obj.get("in_reply_to")) |v| @as(usize, @intCast(v.integer)) else null;

            // Parse extra fields using the entire value (Extra.jsonParse will extract what it needs)
            var o = options;
            o.ignore_unknown_fields = true;
            const extra = try std.json.innerParseFromValue(Extra, allocator, value, o);

            return Body{
                .type = kind,
                .msg_id = msg_id,
                .in_reply_to = in_reply_to,
                .extra = extra,
            };
        }

        /// Overload serialisation to flatten all fields: serialise `Extra` at the level of its
        /// parent. We write the common fields (type, msg_id, in_reply_to) first. We then write
        /// `Extra`'s fields if they exist. `init_ok`, for example, doesn't have any `Extra` fields
        /// so only the common fields are serialised.
        pub fn jsonStringify(b: Body, writer: anytype) !void {
            try writer.beginObject();

            try writer.objectField("type");
            try writer.write(@tagName(b.type));

            if (b.msg_id) |id| {
                try writer.objectField("msg_id");
                try writer.write(id);
            }

            if (b.in_reply_to) |id| {
                try writer.objectField("in_reply_to");
                try writer.write(id);
            }

            // Write the fields in `Extra`.
            switch (b.extra) { // switch on the tag
                inline else => |value| { // pull out the value
                    const type_info = @typeInfo(@TypeOf(value));
                    std.debug.assert(type_info == .@"struct");
                    inline for (type_info.@"struct".fields) |field| {
                        try writer.objectField(field.name);
                        try writer.write(@field(value, field.name));
                    }
                },
            }

            try writer.endObject();
        }
    };
};

/// Serialise the value to JSON (with indentation) returning a slice. The caller is responsible for
/// freeing the slice (e.g. with `std.testing.allocator.free(j)`).
fn allocPrintJson(
    value: anytype,
) ![]const u8 {
    return try std.fmt.allocPrint(
        std.testing.allocator,
        "{f}",
        .{std.json.fmt(value, .{ .whitespace = .indent_2 })},
    );
}

// These tests are really just documentation. They helped me get up to speed with serialisation and
// deserialisation in `std.json`.

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
    const Struct = struct {
        const Enum = enum { tag };
        const TaggedUnion = union(Enum) { tag: bool };
        tagged_union: TaggedUnion,
    };

    const s = Struct{ .tagged_union = .{ .tag = true } };

    const j = try allocPrintJson(s);
    defer std.testing.allocator.free(j);

    try std.testing.expectEqualStrings(
        \\{
        \\  "tagged_union": {
        //  ^ This is the nesting we avoid using the JSON overloads in `Extra` and `Body` above.
        \\    "tag": true
        \\  }
        \\}
    , j);
}

// Sanity check JSON serialisation and deserialisation. Message `"body"`s contain different flags
// depending on the specified `"type"`. A tagged union allows us to store different fields in
// `Extra` depending on the tag (`"type"`) but it requires some `std.json` overload magic (found in
// `Body` and `Extra`).
test Message {
    const j =
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
    ;

    const deserialised = try std.json.parseFromSlice(Message, std.testing.allocator, j, .{});
    defer deserialised.deinit();
    const serialised = try allocPrintJson(deserialised.value);
    defer std.testing.allocator.free(serialised);

    try std.testing.expectEqualStrings(j, serialised);
}
