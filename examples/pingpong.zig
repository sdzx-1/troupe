const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;
const pingpong = @import("./protocols/pingpong.zig");
const gui = @import("gui.zig");

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

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}).init;
    const gpa = gpa_instance.allocator();

    var counter: std.atomic.Value(usize) = .init(0);
    var log_array: channel.LogArray = .{
        .mutex = .{},
        .log_array = .empty,
        .allocator = gpa,
    };

    var mvar_channel_map: MvarChannelMap = .init(&log_array, &counter);
    try mvar_channel_map.generate_all_MvarChannel(gpa, 10);

    const alice = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var alice_context: AliceContext = .{};
            try Runner.runProtocol(.alice, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var bob_context: BobContext = .{};
            try Runner.runProtocol(.bob, false, mcm, curr_id, &bob_context);
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.run, .{&mvar_channel_map});
    const bob_thread = try std.Thread.spawn(.{}, bob.run, .{&mvar_channel_map});

    try gui.start(Role, gpa, &log_array);

    alice_thread.join();
    bob_thread.join();
}
