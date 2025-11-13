const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;

pub fn mk2pc(
    Role: type,
    coordinator: Role,
    alice: Role,
    bob: Role,
    context: anytype,
    Successed: type,
    Failed: type,
) type {
    return struct {
        fn two_pc(
            StateName: []const u8,
            sender: Role,
            receiver: []const Role,
        ) troupe.ProtocolInfo(
            "2pc_generic",
            Role,
            context,
            &.{ coordinator, alice, bob },
            &.{ Successed, Failed },
        ) {
            return .{ .name = StateName, .sender = sender, .receiver = receiver };
        }

        pub const Begin = union(enum) {
            begin: Data(void, AliceResp),

            pub const info = two_pc("Begin", coordinator, &.{ alice, bob });

            pub fn process(ctx: *info.Ctx(coordinator)) !@This() {
                ctx.counter = 0;
                return .{ .begin = .{ .data = {} } };
            }
        };

        pub const AliceResp = union(enum) {
            resp: Data(bool, BobResp),

            pub const info = two_pc("AliceResp", alice, &.{coordinator});

            pub fn process(ctx: *info.Ctx(alice)) !@This() {
                const random: std.Random = ctx.xoshiro256.random();
                const res: bool = random.intRangeAtMost(u32, 0, 100) < 80;
                return .{ .resp = .{ .data = res } };
            }

            pub fn preprocess_0(ctx: *info.Ctx(coordinator), msg: @This()) !void {
                switch (msg) {
                    .resp => |val| {
                        if (val.data) ctx.counter += 1;
                    },
                }
            }
        };

        pub const BobResp =
            union(enum) {
                resp: Data(bool, Check),

                pub const info = two_pc("BobResp", bob, &.{coordinator});

                pub fn process(ctx: *info.Ctx(bob)) !@This() {
                    const random: std.Random = ctx.xoshiro256.random();
                    const res: bool = random.intRangeAtMost(u32, 0, 100) < 80;
                    return .{ .resp = .{ .data = res } };
                }

                pub fn preprocess_0(ctx: *info.Ctx(coordinator), msg: @This()) !void {
                    switch (msg) {
                        .resp => |val| {
                            if (val.data) ctx.counter += 1;
                        },
                    }
                }
            };

        pub const Check = union(enum) {
            succcessed: Data(void, Successed),
            failed: Data(void, Failed),
            failed_retry: Data(void, Begin),

            pub const info = two_pc("Check", coordinator, &.{ alice, bob });

            pub fn process(ctx: *info.Ctx(coordinator)) !@This() {
                if (ctx.counter == 2) {
                    ctx.retry_times = 0;
                    return .{ .succcessed = .{ .data = {} } };
                } else if (ctx.retry_times < 4) {
                    ctx.retry_times += 1;
                    std.debug.print("2pc failed retry: {d}\n", .{ctx.retry_times});
                    return .{ .failed_retry = .{ .data = {} } };
                } else {
                    ctx.retry_times = 0;
                    return .{ .failed = .{ .data = {} } };
                }
            }
        };
    };
}
