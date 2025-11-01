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

const QueueChannel = @import("channel.zig").QueueChannel;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var evented: std.Io.IoUring = undefined;
    try evented.init(gpa, .{ .environ = init.minimal.environ });
    const io = evented.io();

    var atomic_val: std.atomic.Value(u32) = .init(0);

    var group: std.Io.Group = .init;

    _ = group.async(io, check_atomic, .{ io, &atomic_val });

    for (0..1_000_000) |i| {
        const queue_a = try gpa.create(std.Io.Queue([]const u8));
        queue_a.* = .init(try gpa.alloc([]const u8, 2));

        const queue_b = try gpa.create(std.Io.Queue([]const u8));
        queue_b.* = .init(try gpa.alloc([]const u8, 2));

        const qc_a: QueueChannel = .{ .queue_a = queue_a, .queue_b = queue_b, .gpa = gpa, .io = io };
        const qc_b: QueueChannel = .{ .queue_a = queue_b, .queue_b = queue_a, .gpa = gpa, .io = io };

        _ = group.async(io, wrapper_alice, .{ io, qc_a, &atomic_val });
        _ = group.async(io, wrapper_bob, .{ io, qc_b });

        if (@mod(i, 10_000) == 0) {
            std.debug.print("async: {d}\n", .{i});
        }
    }

    try group.await(io);
}

fn check_atomic(io: std.Io, atomic_val: *std.atomic.Value(u32)) void {
    while (true) {
        const val = atomic_val.load(.seq_cst);
        io.sleep(.fromSeconds(1), .awake) catch unreachable;
        std.debug.print("finish: {d}\n", .{val});
        if (val == 1_000_000) break;
    }
}

const alice = struct {
    fn run(io_: std.Io, qc: QueueChannel, atomic_val: *std.atomic.Value(u32)) !void {
        var alice_context: AliceContext = .{};
        alice_context.pingpong.counter = atomic_val;
        try Runner.runProtocol(io_, .alice, true, .{ .bob = qc }, curr_id, &alice_context);
    }
};

const bob = struct {
    fn run(io_: std.Io, qc: QueueChannel) !void {
        var bob_context: BobContext = .{};
        try Runner.runProtocol(io_, .bob, true, .{ .alice = qc }, curr_id, &bob_context);
    }
};

fn wrapper_alice(io: std.Io, qc: QueueChannel, atomic_val: *std.atomic.Value(u32)) void {
    alice.run(io, qc, atomic_val) catch unreachable;
}

fn wrapper_bob(io: std.Io, qc: QueueChannel) void {
    bob.run(io, qc) catch unreachable;
}
