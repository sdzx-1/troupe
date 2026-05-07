const std = @import("std");
const Io = std.Io;
const troupe = @import("troupe");
const Data = troupe.Data;
const pingpong = @import("./protocols/pingpong.zig");
const mk2pc = @import("./protocols/two_phase_commit.zig").mk2pc;
const channel = @import("channel.zig");

const MvarChannelMap = channel.MvarChannelMap(AllRole);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var counter: std.atomic.Value(usize) = .init(0);

    var mvar_channel_map: MvarChannelMap = .init(io, true, &counter);
    defer mvar_channel_map.deinit(gpa);

    try mvar_channel_map.generate_all_MvarChannel(gpa, 10);

    const alice = struct {
        fn run(io_: Io, mcm: *MvarChannelMap) !void {
            var alice_context: AliceContext = .{};
            io_.random(@ptrCast(&alice_context.xoshiro256.s));
            try Runner.runProtocol(.alice, null, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn run(io_: Io, mcm: *MvarChannelMap) !void {
            var bob_context: BobContext = .{};
            io_.random(@ptrCast(&bob_context.xoshiro256.s));

            try Runner.runProtocol(.bob, null, false, mcm, curr_id, &bob_context);
        }
    };

    const charlie = struct {
        fn run(io_: Io, mcm: *MvarChannelMap) !void {
            var charlie_context: CharlieContext = .{};
            io_.random(@ptrCast(&charlie_context.xoshiro256.s));

            try Runner.runProtocol(.charlie, null, false, mcm, curr_id, &charlie_context);
        }
    };

    const selector = struct {
        fn run(io_: Io, mcm: *MvarChannelMap) !void {
            var select_context: SelectorContext = .{};
            io_.random(@ptrCast(&select_context.xoshiro256.s));

            try Runner.runProtocol(.selector, null, false, mcm, curr_id, &select_context);
        }
    };

    var alice_future = try io.concurrent(alice.run, .{ io, &mvar_channel_map });
    var bob_future = try io.concurrent(bob.run, .{ io, &mvar_channel_map });
    var charlie_future = try io.concurrent(charlie.run, .{ io, &mvar_channel_map });
    var selector_future = try io.concurrent(selector.run, .{ io, &mvar_channel_map });

    try alice_future.await(io);
    try bob_future.await(io);
    try charlie_future.await(io);
    try selector_future.await(io);
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

pub const Runner = troupe.Runner(EnterFsmState);
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
    return mk2pc(AllRole, .charlie, .alice, .bob, Context{}, Next, troupe.Exit);
}
fn ABC(Next: type) type {
    return mk2pc(AllRole, .alice, .bob, .charlie, Context{}, Next, troupe.Exit);
}
fn BAC(Next: type) type {
    return mk2pc(AllRole, .bob, .alice, .charlie, Context{}, Next, troupe.Exit);
}

pub const Start = union(enum) {
    charlie_as_coordinator: Data(void, PingPong(.alice, .bob, PingPong(.bob, .charlie, PingPong(
        .charlie,
        .alice,
        CAB(@This()).Begin,
    ).Ping).Ping).Ping),
    alice_as_coordinator: Data(void, PingPong(.charlie, .bob, ABC(@This()).Begin).Ping),
    bob_as_coordinator: Data(void, PingPong(.alice, .charlie, BAC(@This()).Begin).Ping),
    exit: Data(void, troupe.Exit),

    pub const info: troupe.ProtocolInfo(
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
