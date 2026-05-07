const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;
const pingpong = @import("./protocols/pingpong.zig");

const Role = enum { alice, bob };

const AliceContext = struct {
    pingpong: pingpong.ClientContext = .{ .client_counter = 0 },
};

const BobContext = struct {
    pingpong: pingpong.ServerContext = .{ .server_counter = 0 },
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
};

pub const EnterFsmState = pingpong.MkPingPong(Role, .alice, .bob, Context{}, .pingpong, .pingpong, troupe.Exit).Ping;

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
        fn run(mcm: *MvarChannelMap) !void {
            var alice_context: AliceContext = .{};
            try Runner.runProtocol(.alice, null, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var bob_context: BobContext = .{};
            try Runner.runProtocol(.bob, null, false, mcm, curr_id, &bob_context);
        }
    };

    var alice_future = try io.concurrent(alice.run, .{&mvar_channel_map});
    var bob_future = try io.concurrent(bob.run, .{&mvar_channel_map});

    try alice_future.await(io);
    try bob_future.await(io);
}
