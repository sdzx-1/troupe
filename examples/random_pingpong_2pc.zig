const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const pingpong = @import("./protocols/pingpong.zig");
const mk2pc = @import("./protocols/two_phase_commit.zig").mk2pc;

const MvarChannelMap = @import("channel.zig").MvarChannelMap(AllRole);

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}).init;
    const gpa = gpa_instance.allocator();

    var threaded = std.Io.Threaded.init(gpa);
    const io = threaded.io();

    var mvar_channel_map: MvarChannelMap = try .init();
    try mvar_channel_map.generate_all_MvarChannel(gpa, 10);

    const alice = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var alice_context: AliceContext = .{};
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(io_, .alice, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var bob_context: BobContext = .{};
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(io_, .bob, false, mcm, curr_id, &bob_context);
        }
    };

    const charlie = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var charlie_context: CharlieContext = .{};
            const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(io_, .charlie, false, mcm, curr_id, &charlie_context);
        }
    };

    const selector = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var charlie_context: SelectorContext = .{};
            const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(io_, .selector, false, mcm, curr_id, &charlie_context);
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.run, .{ io, &mvar_channel_map });
    const bob_thread = try std.Thread.spawn(.{}, bob.run, .{ io, &mvar_channel_map });
    const charlie_thread = try std.Thread.spawn(.{}, charlie.run, .{ io, &mvar_channel_map });
    const selector_thread = try std.Thread.spawn(.{}, selector.run, .{ io, &mvar_channel_map });

    alice_thread.join();
    bob_thread.join();
    charlie_thread.join();
    selector_thread.join();
}

//
const AllRole = enum { selector, alice, bob, charlie };

const AliceContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const BobContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const CharlieContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const SelectorContext = struct {
    times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
    charlie: type = CharlieContext,
    selector: type = SelectorContext,
};

pub const EnterFsmState = Start;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

fn PingPong(client: AllRole, server: AllRole, Next: type) type {
    return pingpong.MkPingPong(
        AllRole,
        client,
        server,
        Context{},
        .pingpong_client,
        .pingpong_server,
        Next,
    );
}

fn CAB(Next: type) type {
    return mk2pc(AllRole, .charlie, .alice, .bob, Context{}, Next, ps.Exit);
}
fn ABC(Next: type) type {
    return mk2pc(AllRole, .alice, .bob, .charlie, Context{}, Next, ps.Exit);
}
fn BAC(Next: type) type {
    return mk2pc(AllRole, .bob, .alice, .charlie, Context{}, Next, ps.Exit);
}

pub const Start = union(enum) {
    charlie_as_coordinator: Data(void, PingPong(.alice, .bob, PingPong(.bob, .charlie, PingPong(
        .charlie,
        .alice,
        CAB(@This()).Begin,
    ).Ping).Ping).Ping),
    alice_as_coordinator: Data(void, PingPong(.charlie, .bob, ABC(@This()).Begin).Ping),
    bob_as_coordinator: Data(void, PingPong(.alice, .charlie, BAC(@This()).Begin).Ping),
    exit: Data(void, ps.Exit),

    pub const info: ps.ProtocolInfo(
        "random_pingpong_and_2pc",
        AllRole,
        Context{},
        &.{ .selector, .charlie, .alice, .bob },
        &.{},
    ) = .{
        .name = "Start",
        .sender = .selector,
        .receiver = &.{ .charlie, .alice, .bob },
    };

    pub fn process(ctx: *SelectorContext) !@This() {
        ctx.times += 1;
        std.debug.print("times: {d}\n", .{ctx.times});
        if (ctx.times > 300) {
            return .{ .exit = .{ .data = {} } };
        }

        const random: std.Random = ctx.xoshiro256.random();
        const res = random.intRangeAtMost(u8, 0, 2);
        switch (res) {
            0 => return .{ .charlie_as_coordinator = .{ .data = {} } },
            1 => return .{ .alice_as_coordinator = .{ .data = {} } },
            2 => return .{ .bob_as_coordinator = .{ .data = {} } },
            else => unreachable,
        }
    }
};
