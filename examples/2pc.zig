const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;
const mk2pc = @import("./protocols/two_phase_commit.zig").mk2pc;

const Role = enum { alice, bob, charlie };

const AliceContext = struct {
    xoshiro256: std.Random.Xoshiro256 = undefined,
};

const BobContext = struct {
    xoshiro256: std.Random.Xoshiro256 = undefined,
};

const CharlieContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
    charlie: type = CharlieContext,
};

pub const EnterFsmState = mk2pc(Role, .charlie, .alice, .bob, Context{}, troupe.Exit, troupe.Exit).Begin;

pub const Runner = troupe.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);
const channel = @import("channel.zig");

const MvarChannelMap = channel.MvarChannelMap(Role);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var counter: std.atomic.Value(usize) = .init(0);

    var mvar_channel_map: MvarChannelMap = .init(io, true, &counter);
    defer mvar_channel_map.deinit(gpa);

    try mvar_channel_map.generate_all_MvarChannel(gpa, 10);

    const alice = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var alice_context: AliceContext = undefined;
            io_.random(@ptrCast(&alice_context.xoshiro256.s));

            try Runner.runProtocol(.alice, null, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var bob_context: BobContext = undefined;
            io_.random(@ptrCast(&bob_context.xoshiro256.s));

            try Runner.runProtocol(.bob, null, false, mcm, curr_id, &bob_context);
        }
    };

    const charlie = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var charlie_context: CharlieContext = .{};
            try Runner.runProtocol(.charlie, null, false, mcm, curr_id, &charlie_context);
        }
    };

    var alice_future = try io.concurrent(alice.run, .{ io, &mvar_channel_map });
    var bob_future = try io.concurrent(bob.run, .{ io, &mvar_channel_map });
    var charlie_future = try io.concurrent(charlie.run, .{&mvar_channel_map});

    try alice_future.await(io);
    try bob_future.await(io);
    try charlie_future.await(io);
}
