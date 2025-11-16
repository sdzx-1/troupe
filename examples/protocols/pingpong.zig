const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;

pub const ServerContext = struct {
    server_counter: i32,
};

pub const ClientContext = struct {
    client_counter: i32,
};

pub fn MkPingPong(
    comptime Role: type,
    comptime client: Role,
    comptime server: Role,
    comptime context: anytype,
    comptime client_ctx_field: std.meta.FieldEnum(@field(context, @tagName(client))),
    comptime server_ctx_field: std.meta.FieldEnum(@field(context, @tagName(server))),
    comptime NextFsmState: type,
) type {
    return struct {
        fn pingpogn_info(
            StateName: []const u8,
            sender: Role,
            receiver: []const Role,
        ) troupe.ProtocolInfo("pingpong", Role, context, &.{ client, server }, &.{NextFsmState}) {
            return .{ .name = StateName, .sender = sender, .receiver = receiver };
        }

        pub const Ping = union(enum) {
            ping: Data(i32, info.Cast("Pong", server, client, i32, PongFn, @This())),
            next: Data(void, NextFsmState),

            pub const info = pingpogn_info("Ping", client, &.{server});

            pub fn process(parent_ctx: *info.Ctx(client)) !@This() {
                const ctx = client_ctxFromParent(parent_ctx);
                if (ctx.client_counter == 2) {
                    ctx.client_counter = 0;
                    return .{ .next = .{ .data = {} } };
                }
                return .{ .ping = .{ .data = ctx.client_counter } };
            }

            pub fn preprocess_0(parent_ctx: *info.Ctx(server), msg: @This()) !void {
                const ctx = server_ctxFromParent(parent_ctx);
                switch (msg) {
                    .ping => |val| ctx.server_counter = val.data,
                    .next => {
                        ctx.server_counter = 0;
                    },
                }
            }
        };

        const PongFn = struct {
            pub fn process(parent_ctx: *@field(context, @tagName(server))) !i32 {
                const ctx = server_ctxFromParent(parent_ctx);
                ctx.server_counter += 1;
                return ctx.server_counter;
            }

            pub fn preprocess(parent_ctx: *@field(context, @tagName(client)), val: i32) !void {
                const ctx = client_ctxFromParent(parent_ctx);
                ctx.client_counter = val;
            }
        };
        fn client_ctxFromParent(parent_ctx: *@field(context, @tagName(client))) *ClientContext {
            return &@field(parent_ctx, @tagName(client_ctx_field));
        }

        fn server_ctxFromParent(parent_ctx: *@field(context, @tagName(server))) *ServerContext {
            return &@field(parent_ctx, @tagName(server_ctx_field));
        }
    };
}
