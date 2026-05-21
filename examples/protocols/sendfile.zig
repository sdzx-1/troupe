const std = @import("std");
const polyrole = @import("polyrole");
const Data = polyrole.Data;

pub const SendContext = struct {
    send_buff: [1024 * 4]u8 = @splat(0),
    reader: *std.Io.Reader,
    file_size: u64,

    send_size: usize = 0,
    hasher: std.hash.XxHash3 = std.hash.XxHash3.init(0),
};

pub const RecvContext = struct {
    writer: *std.Io.Writer,
    total: u64 = 0,
    recved: u64 = 0,

    recved_hash: ?u64 = null,
    hasher: std.hash.XxHash3 = std.hash.XxHash3.init(0),
};

pub fn MkSendFile(
    comptime Role: type,
    comptime sender: Role,
    comptime receiver: Role,
    comptime context: anytype,
    comptime batch_size: usize,
    comptime sender_ctx_field: std.meta.FieldEnum(@field(context, @tagName(sender))),
    comptime recver_ctx_field: std.meta.FieldEnum(@field(context, @tagName(receiver))),
    comptime Successed: type,
    comptime Failed: type,
) type {
    return struct {
        pub const Start = union(enum) {
            file_size: Data(u64, Send),

            pub const info = sendfile_info("Start", sender, &.{receiver});

            pub fn process(parent_ctx: *@field(context, @tagName(sender))) !@This() {
                const ctx = sender_ctxFromParent(parent_ctx);
                return .{ .file_size = .{ .data = ctx.file_size } };
            }

            pub fn preprocess_0(parent_ctx: *@field(context, @tagName(receiver)), msg: @This()) !void {
                const ctx = recver_ctxFromParent(parent_ctx);
                switch (msg) {
                    .file_size => |val| {
                        ctx.total = val.data;
                    },
                }
            }
        };

        pub const Send = union(enum) {
            // zig fmt: off
            send  : Data([]const u8                          , @This()),
            check : Data(u64                                 , CheckHash(@This(), Failed)),
            final : Data(struct {str: []const u8, hash: u64,}, CheckHash(Successed, Failed)),
            // zig fmt: on

            pub const info = sendfile_info("Send", sender, &.{receiver});

            pub fn process(parent_ctx: *@field(context, @tagName(sender))) !@This() {
                const ctx = sender_ctxFromParent(parent_ctx);
                if (ctx.send_size >= batch_size) {
                    ctx.send_size = 0;
                    const curr_hash = ctx.hasher.final();
                    ctx.hasher = std.hash.XxHash3.init(0);
                    return .{ .check = .{ .data = curr_hash } };
                }

                const n = try ctx.reader.readSliceShort(&ctx.send_buff);

                if (n < ctx.send_buff.len) {
                    ctx.hasher.update(ctx.send_buff[0..n]);
                    ctx.send_size += n;
                    return .{ .final = .{ .data = .{ .str = ctx.send_buff[0..n], .hash = ctx.hasher.final() } } };
                } else {
                    ctx.hasher.update(&ctx.send_buff);
                    ctx.send_size += ctx.send_buff.len;
                    return .{ .send = .{ .data = &ctx.send_buff } };
                }
            }

            pub fn preprocess_0(parent_ctx: *@field(context, @tagName(receiver)), msg: @This()) !void {
                const ctx = recver_ctxFromParent(parent_ctx);
                var size: usize = 0;
                switch (msg) {
                    .send => |val| {
                        size = val.data.len;
                        ctx.recved += val.data.len;
                        ctx.hasher.update(val.data);
                        try ctx.writer.writeAll(val.data);
                    },
                    .final => |val| {
                        ctx.recved_hash = val.data.hash;
                        const str = val.data.str;
                        size = str.len;
                        ctx.recved += str.len;
                        ctx.hasher.update(str);
                        try ctx.writer.writeAll(str);
                        try ctx.writer.flush();

                        std.debug.print("recv: final {Bi}, {d:.4}\n", .{
                            size,
                            @as(f32, @floatFromInt(ctx.recved)) / @as(f32, @floatFromInt(ctx.total)),
                        });
                    },
                    .check => |val| {
                        ctx.recved_hash = val.data;
                        std.debug.print("recv: check, hash: {d}\n", .{val.data});
                    },
                }
            }
        };

        pub fn CheckHash(A: type, B: type) type {
            return union(enum) {
                succeeded: Data(void, A),
                failed: Data(void, B),

                pub const info = sendfile_info("CheckHash", receiver, &.{sender});

                pub fn process(parent_ctx: *@field(context, @tagName(receiver))) !@This() {
                    const ctx = recver_ctxFromParent(parent_ctx);
                    const curr_hash = ctx.hasher.final();
                    ctx.hasher = std.hash.XxHash3.init(0);
                    if (curr_hash == ctx.recved_hash) {
                        std.debug.print("check succeeded \n", .{});
                        return .{ .succeeded = .{ .data = {} } };
                    } else {
                        std.debug.print("check failed \n", .{});
                        return .{ .failed = .{ .data = {} } };
                    }
                }
                pub fn preprocess_0(parent_ctx: *@field(context, @tagName(sender)), msg: @This()) !void {
                    const ctx = sender_ctxFromParent(parent_ctx);
                    _ = ctx;
                    switch (msg) {
                        .failed => {},
                        .succeeded => {},
                    }
                }
            };
        }

        fn sendfile_info(
            StateName: []const u8,
            sender_: Role,
            receiver_: []const Role,
        ) polyrole.ProtocolInfo(
            "sendfile",
            Role,
            context,
            &.{ sender, receiver },
            &.{ Successed, Failed },
        ) {
            return .{ .name = StateName, .sender = sender_, .receiver = receiver_ };
        }

        fn sender_ctxFromParent(parent_ctx: *@field(context, @tagName(sender))) *SendContext {
            return &@field(parent_ctx, @tagName(sender_ctx_field));
        }

        fn recver_ctxFromParent(parent_ctx: *@field(context, @tagName(receiver))) *RecvContext {
            return &@field(parent_ctx, @tagName(recver_ctx_field));
        }
    };
}
