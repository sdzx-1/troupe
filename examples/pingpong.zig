const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const pingpong = @import("./protocols/pingpong.zig");

const Role = enum { alice, bob };

const AliceContext = struct {
    pingpong: pingpong.ClientContext = .{
        .client_counter = 0,
        .counter = undefined,
    },
};

const BobContext = struct {
    pingpong: pingpong.ServerContext = .{ .server_counter = 0 },
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
};

pub const EnterFsmState = pingpong.MkPingPong(Role, .alice, .bob, Context{}, .pingpong, .pingpong, ps.Exit).Ping;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

const channel = @import("channel.zig");
const MvarChannel = channel.MvarChannel;

const total: usize = 2_00_000;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const threaded_io = init.io;

    var evented: std.Io.Uring = undefined;
    defer evented.deinit();

    try evented.init(gpa, .{
        // .thread_limit = 0,
        // .log2_ring_entries = 3,
        // .backing_allocator_needs_mutex = true,
    });
    const io = evented.io();

    var atomic_val: std.atomic.Value(u32) = .init(0);

    var check_future = threaded_io.async(check_atomic, .{ threaded_io, &atomic_val });

    var mvar_list: std.ArrayList(*channel.Mvar) = .empty;
    defer mvar_list.deinit(gpa);

    var group: std.Io.Group = .init;

    for (0..total) |i| {
        const mvar_a = try channel.Mvar.init(io, gpa, 20);
        const mvar_b = try channel.Mvar.init(io, gpa, 20);
        try mvar_list.append(gpa, mvar_a);
        try mvar_list.append(gpa, mvar_b);

        const mvar_channel_a: channel.MvarChannel = .{ .mvar_a = mvar_a, .mvar_b = mvar_b };
        const mvar_channel_b: channel.MvarChannel = .{ .mvar_a = mvar_b, .mvar_b = mvar_a };

        group.async(io, wrapper_alice, .{ io, mvar_channel_a, &atomic_val });
        group.async(io, wrapper_bob, .{ io, mvar_channel_b });

        if (@mod(i, 1_0000) == 0) {
            std.debug.print("async: {d}\n", .{i});
        }
    }

    try group.await(io);
    check_future.await(threaded_io);

    for (mvar_list.items) |mvar| {
        mvar.deinit(gpa);
    }
}

fn check_atomic(io: std.Io, atomic_val: *std.atomic.Value(u32)) void {
    while (true) {
        const val = atomic_val.load(.seq_cst);
        io.sleep(.fromSeconds(1), .awake) catch unreachable;
        std.debug.print("finish: {d}\n", .{val});
        if (val == total) break;
    }
}

const alice = struct {
    fn run(io_: std.Io, qc: channel.MvarChannel, atomic_val: *std.atomic.Value(u32)) !void {
        var alice_context: AliceContext = .{};
        alice_context.pingpong.counter = atomic_val;
        io_.sleep(.fromSeconds(1), .awake) catch unreachable;
        try Runner.runProtocol(io_, .alice, true, .{ .bob = qc }, curr_id, &alice_context);
    }
};

const bob = struct {
    fn run(io_: std.Io, qc: channel.MvarChannel) !void {
        var bob_context: BobContext = .{};
        try Runner.runProtocol(io_, .bob, true, .{ .alice = qc }, curr_id, &bob_context);
    }
};

fn wrapper_alice(io: std.Io, qc: channel.MvarChannel, atomic_val: *std.atomic.Value(u32)) void {
    alice.run(io, qc, atomic_val) catch unreachable;
}

fn wrapper_bob(io: std.Io, qc: channel.MvarChannel) void {
    bob.run(io, qc) catch unreachable;
}
