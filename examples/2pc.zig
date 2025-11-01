const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
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

pub const EnterFsmState = mk2pc(Role, .charlie, .alice, .bob, Context{}, ps.Exit, ps.Exit).Begin;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

//
const MvarChannelMap = @import("channel.zig").MvarChannelMap(Role);

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}).init;
    const gpa = gpa_instance.allocator();

    var threaded = std.Io.Threaded.init(gpa);
    const io = threaded.io();

    var mvar_channel_map: MvarChannelMap = try .init();
    try mvar_channel_map.generate_all_MvarChannel(gpa, 10);

    const alice = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var alice_context: AliceContext = undefined;
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(io_, .alice, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var bob_context: BobContext = undefined;
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(io_, .bob, false, mcm, curr_id, &bob_context);
        }
    };

    const charlie = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap) !void {
            var charlie_context: CharlieContext = .{};
            try Runner.runProtocol(io_, .charlie, false, mcm, curr_id, &charlie_context);
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.run, .{ io, &mvar_channel_map });
    const bob_thread = try std.Thread.spawn(.{}, bob.run, .{ io, &mvar_channel_map });
    const charlie_thread = try std.Thread.spawn(.{}, charlie.run, .{ io, &mvar_channel_map });

    alice_thread.join();
    bob_thread.join();
    charlie_thread.join();
}
