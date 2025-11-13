const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;

pub const SendContext = struct {
    send_buff: [1024 * 1024]u8 = @splat(0),
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
        fn sendfile_info(
            StateName: []const u8,
            sender_: Role,
            receiver_: []const Role,
        ) troupe.ProtocolInfo(
            "sendfile",
            Role,
            context,
            &.{ sender, receiver },
            &.{ Successed, Failed },
        ) {
            return .{ .name = StateName, .sender = sender_, .receiver = receiver_ };
        }

        const SendFileSize = struct {
            pub fn process(parent_ctx: *@field(context, @tagName(sender))) !u64 {
                const ctx = sender_ctxFromParent(parent_ctx);
                return ctx.file_size;
            }

            pub fn preprocess(parent_ctx: *@field(context, @tagName(receiver)), msg: u64) !void {
                const ctx = recver_ctxFromParent(parent_ctx);
                ctx.total = msg;
            }
        };

        //Here, a temporary `info` is built to use `Cast`
        pub const Start = sendfile_info("", sender, &.{}).Cast("SendFileSize", sender, receiver, u64, SendFileSize, Send);

        pub const Send = union(enum) {
            // zig fmt: off
            check     : Data(u64       , CheckHash(@This(), Failed)),
            send      : Data([]const u8, @This()),
            final     : Data([]const u8, info.Cast("SendFinalHash", sender, receiver, u64, SendFinalHash, CheckHash(Successed, Failed))),
            // zig fmt: on

            pub const info = sendfile_info("Send", sender, &.{receiver});

            const SendFinalHash = struct {
                pub fn process(parent_ctx: *@field(context, @tagName(sender))) !u64 {
                    const ctx = sender_ctxFromParent(parent_ctx);
                    return ctx.hasher.final();
                }

                pub fn preprocess(parent_ctx: *@field(context, @tagName(receiver)), msg: u64) !void {
                    const ctx = recver_ctxFromParent(parent_ctx);
                    ctx.recved_hash = msg;
                }
            };

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
                    ctx.send_size += ctx.send_buff.len;
                    return .{ .final = .{ .data = ctx.send_buff[0..n] } };
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

                        std.debug.print("recv: send {Bi}, {d:.4}\n", .{
                            size,
                            @as(f32, @floatFromInt(ctx.recved)) / @as(f32, @floatFromInt(ctx.total)),
                        });
                    },
                    .final => |val| {
                        size = val.data.len;
                        ctx.recved += val.data.len;
                        ctx.hasher.update(val.data);
                        try ctx.writer.writeAll(val.data);
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
                Successed: Data(void, A),
                Failed: Data(void, B),

                pub const info = sendfile_info("CheckHash", receiver, &.{sender});

                pub fn process(parent_ctx: *@field(context, @tagName(receiver))) !@This() {
                    const ctx = recver_ctxFromParent(parent_ctx);
                    const curr_hash = ctx.hasher.final();
                    ctx.hasher = std.hash.XxHash3.init(0);
                    if (curr_hash == ctx.recved_hash) {
                        std.debug.print("check successed \n", .{});
                        return .{ .Successed = .{ .data = {} } };
                    } else {
                        std.debug.print("check failed \n", .{});
                        return .{ .Failed = .{ .data = {} } };
                    }
                }
                pub fn preprocess_0(parent_ctx: *@field(context, @tagName(sender)), msg: @This()) !void {
                    const ctx = sender_ctxFromParent(parent_ctx);
                    _ = ctx;
                    switch (msg) {
                        .Failed => {},
                        .Successed => {},
                    }
                }
            };
        }
        fn sender_ctxFromParent(parent_ctx: *@field(context, @tagName(sender))) *SendContext {
            return &@field(parent_ctx, @tagName(sender_ctx_field));
        }

        fn recver_ctxFromParent(parent_ctx: *@field(context, @tagName(receiver))) *RecvContext {
            return &@field(parent_ctx, @tagName(recver_ctx_field));
        }
    };
}
