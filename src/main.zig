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
    const messages_received_max = 256;

    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    id: []const u8,
    /// Counter for IDs for messages sent from this node.
    messages_sent_count: usize = 1,
    messages_received: std.ArrayList(isize),
    topology: std.ArrayList([]const u8) = .empty,

    /// Read and parse the next message (newline-separated). The caller is responsible for calling
    /// `deinit()` on the returned value.
    fn recv(allocator: std.mem.Allocator, reader: *std.Io.Reader) !std.json.Parsed(Message) {
        const line = try reader.takeDelimiterInclusive('\n');
        const parsed = std.json.parseFromSlice(Message, allocator, line, .{}) catch |e| {
            std.log.err("Failed to parse message: {s}", .{line});
            return e;
        };

        return parsed;
    }

    fn send(node: *Node, message: Message) !void {
        try node.writer.print("{f}\n", .{
            std.json.fmt(message, .{ .emit_null_optional_fields = false }),
        });
    }

    /// Read initialisation message, set node ID, and respond with `init_ok`.
    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) !Node {
        const message = try recv(allocator, reader);
        defer message.deinit();
        const m = message.value;

        var node: Node = .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .id = try allocator.dupe(u8, m.body.extra.init.node_id),
            .messages_received = try .initCapacity(allocator, Node.messages_received_max),
        };

        try node.reply(m, .{ .init_ok = .{} });
        std.log.debug("Node {s} initialised", .{node.id});

        return node;
    }

    pub fn deinit(node: *Node) void {
        node.allocator.free(node.id);
        defer node.messages_received.deinit(node.allocator);
    }

    pub fn tick(node: *Node) !void {
        const message = try recv(node.allocator, node.reader);
        defer message.deinit();
        const m = message.value;

        switch (m.body.extra) {
            .echo => |e| try node.reply(m, .{ .echo_ok = .{ .echo = e.echo } }),
            .generate => try node.reply(m, .{ .generate_ok = .{ .id = new_id() } }),
            .broadcast => |b| {
                for (node.messages_received.items) |received_message| {
                    if (b.message == received_message) break; // we already have this message
                } else {
                    // Store message.
                    node.messages_received.appendAssumeCapacity(b.message);
                    // Send message to peer nodes according to topology.
                    for (node.topology.items) |node_id| try node.send(.{
                        .src = node.id,
                        .dest = try node.allocator.dupe(u8, node_id),
                        .body = .{
                            .type = .broadcast,
                            .msg_id = node.message_id(),
                            .in_reply_to = null,
                            .extra = .{
                                .broadcast = .{
                                    .message = b.message,
                                },
                            },
                        },
                    });
                }

                try node.reply(m, .{ .broadcast_ok = .{} });
            },
            .broadcast_ok => {}, // acks from peers
            .topology => |t| {
                // TODO: Assert topology is empty (i.e. it must only be set once).
                try node.topology.appendSlice(node.allocator, t.topology.map.get(node.id).?);
                try node.reply(m, .{ .topology_ok = .{} });
            },
            // Reply with all received messages.
            .read => try node.reply(m, .{
                .read_ok = .{ .messages = node.messages_received.items },
            }),
            .init => @panic("Received second init message"),
            .echo_ok,
            .init_ok,
            .generate_ok,
            .read_ok,
            .topology_ok,
            => std.debug.panic("Received unexpected message: {s}", .{@tagName(m.body.extra)}),
        }
    }

    fn message_id(node: *Node) usize {
        const id = node.messages_sent_count;
        node.messages_sent_count += 1;
        return id;
    }

    fn new_id() usize {
        return std.crypto.random.int(usize);
    }

    fn reply(node: *Node, message: Message, extra: Message.Body.Extra) !void {
        try node.send(.{
            .src = node.id,
            .dest = message.src,
            .body = .{
                .type = std.meta.activeTag(extra),
                .msg_id = node.message_id(),
                .in_reply_to = message.body.msg_id,
                .extra = extra,
            },
        });
    }
};

const Message = struct {
    id: ?usize = null, // maelstrom includes a top-level "id" field in client messages
    src: []const u8, // e.g. "c1"
    dest: []const u8, // e.g. "n2"
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
        msg_id: usize,
        in_reply_to: ?usize, // only present in replies
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
                topology: std.json.ArrayHashMap([]const []const u8),
            },
            topology_ok: struct {},

            /// Override JSON parsing to account for tagged union nesting.
            ///
            /// By default, Zig's JSON parser expects a tagged union to be represented as a nested
            /// object like `{"tag_name": {...}}`. However, in our message format the union's fields
            /// exist at the top level (within the `"body"` object). We get around this by manually
            /// checking the `"type"` field (i.e. our union's tag) then using the default parsing
            /// for the corresponding type.
            pub fn jsonParseFromValue(
                allocator: std.mem.Allocator,
                value: std.json.Value,
                options: std.json.ParseOptions,
            ) !Extra {
                const kind = value.object.get("type").?.string;

                // FIXME: Figure out how to parse messages without ever enabling this option.
                // // Toggle `ignore_unknown_fields` back to false. See `Body.jsonParse`.
                // var o = options;
                // o.ignore_unknown_fields = false;

                // Parse the object to the type that `kind` corresponds to.
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

            /// Override serialisation for the same reasons parsing was overridden above. The
            /// default nests the union value under the tag. Instead, just serialise the value with
            /// default serialisation.
            pub fn jsonStringify(extra: Extra, writer: anytype) !void {
                // Switch on the tag to get the value and serialise that instead of the whole union.
                switch (extra) {
                    inline else => |value| try writer.write(value),
                }
            }
        };

        /// Override parsing to handle flattened structure. We nest the `Extra` tagged union in
        /// `Body` to store different fields depending on the `Kind`. However, the JSON message
        /// format has all fields at the same level under `"body"`. We do the following to get
        /// around this:
        ///
        /// 1. Parse the common fields (type, msg_id, in_reply_to) manually.
        /// 2. Use the "type" field to determine which `Extra` union variant to parse.
        /// 3. Re-parse the whole `"body"` value as the union variant type using default parsing,
        ///    ignoring unknown fields to skip the common fields we parsed manually.
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
            const msg_id = @as(usize, @intCast(obj.get("msg_id").?.integer));
            const in_reply_to =
                if (obj.get("in_reply_to")) |v| @as(usize, @intCast(v.integer)) else null;

            // Parse extra fields using the entire `"body"` value, ignoring already parsed fields.
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
        pub fn jsonStringify(body: Body, writer: anytype) !void {
            try writer.beginObject();

            try writer.objectField("type");
            try writer.write(@tagName(body.type));

            try writer.objectField("msg_id");
            try writer.write(body.msg_id);

            if (body.in_reply_to) |id| {
                try writer.objectField("in_reply_to");
                try writer.write(id);
            }

            // Write the fields in `Extra`.
            switch (body.extra) { // switch on the tag
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
        .{std.json.fmt(value, .{ .whitespace = .indent_2, .emit_null_optional_fields = false })},
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
