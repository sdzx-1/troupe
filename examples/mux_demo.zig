const std = @import("std");
const Io = std.Io;
const polyrole = @import("polyrole");
const Data = polyrole.Data;
const mux_mod = @import("mux.zig");
const Mux = mux_mod.Mux;
const net = std.Io.net;

/// All roles participating in this demo.
const Role = enum { alice, bob };

// ────────────────────────────────────────────────────────────────────
// Context structures — shared by both protocols
// ────────────────────────────────────────────────────────────────────

const AliceContext = struct {
    counter_round: u32 = 0,
    ping_round: u32 = 0,
    io: Io,
    xors: std.Random.Xoshiro256,
    random: std.Random,
    min: i64 = 10,
    max: i64 = 50,
};
const BobContext = struct {};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
};

// ────────────────────────────────────────────────────────────────────
// Protocol 0 — Counter: alice sends 5 numbers, bob receives them
// ────────────────────────────────────────────────────────────────────

const CounterProto = union(enum) {
    num: Data(i32, @This()),
    done: Data(void, polyrole.Exit),

    pub const info: polyrole.ProtocolInfo("counter", Role, Context{}, &.{ .alice, .bob }, &.{}) = .{
        .name = "Counter",
        .sender = .alice,
        .receiver = &.{.bob},
    };

    pub fn process(ctx: *AliceContext) !@This() {
        ctx.counter_round += 1;
        try ctx.io.sleep(.fromMilliseconds(ctx.random.intRangeAtMost(i64, ctx.min, ctx.max)), .awake);
        if (ctx.counter_round > 30) return .{ .done = .{ .data = {} } };
        return .{ .num = .{ .data = @as(i32, @intCast(ctx.counter_round)) } };
    }

    pub fn preprocess_0(ctx: *BobContext, msg: @This()) !void {
        _ = ctx;
        switch (msg) {
            .num => |v| std.debug.print("  counter: {d}\n", .{v.data}),
            .done => std.debug.print("  counter: done\n", .{}),
        }
    }
};

// ────────────────────────────────────────────────────────────────────
// Protocol 1 — Ping: alice sends 3 ping values, bob receives them
// ────────────────────────────────────────────────────────────────────

const PingProto = union(enum) {
    ping: Data(i32, @This()),
    done: Data(void, polyrole.Exit),

    pub const info: polyrole.ProtocolInfo("ping", Role, Context{}, &.{ .alice, .bob }, &.{}) = .{
        .name = "Ping",
        .sender = .alice,
        .receiver = &.{.bob},
    };

    pub fn process(ctx: *AliceContext) !@This() {
        ctx.ping_round += 1;
        try ctx.io.sleep(.fromMilliseconds(ctx.random.intRangeAtMost(i64, ctx.min, ctx.max)), .awake);
        if (ctx.ping_round > 30) return .{ .done = .{ .data = {} } };
        return .{ .ping = .{ .data = @as(i32, @intCast(ctx.ping_round)) } };
    }

    pub fn preprocess_0(ctx: *BobContext, msg: @This()) !void {
        _ = ctx;
        switch (msg) {
            .ping => |v| std.debug.print("  ping: {d}\n", .{v.data}),
            .done => std.debug.print("  ping: done\n", .{}),
        }
    }
};

// ────────────────────────────────────────────────────────────────────
// Runners and initial state IDs
// ────────────────────────────────────────────────────────────────────

const Runner0 = polyrole.Runner(CounterProto);
const Runner1 = polyrole.Runner(PingProto);

const id0 = Runner0.idFromState(CounterProto);
const id1 = Runner1.idFromState(PingProto);

// ────────────────────────────────────────────────────────────────────
// Type alias for convenience
// ────────────────────────────────────────────────────────────────────

const MuxType = Mux(Role, 2, 4096, 8192);

// ────────────────────────────────────────────────────────────────────
// main
// ────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Use a fixed port so both threads know where to connect.
    const addr = try net.IpAddress.parse("127.0.0.1", 9876);
    var server = try addr.listen(io, .{ .reuse_address = true });

    // ---- Bob: connect, start reader + both Runners ----
    const bob = try std.Thread.spawn(.{}, struct {
        fn run(io_: std.Io, addr_: net.IpAddress) !void {
            var bob_stream = try addr_.connect(io_, .{ .mode = .stream });
            defer bob_stream.close(io_);

            var mux = MuxType.init(io_, bob_stream);
            mux.start();

            const h0 = try std.Thread.spawn(.{}, struct {
                fn run(m: *MuxType) !void {
                    var ctx = BobContext{};
                    try Runner0.runProtocol(.bob, null, false, m.handle(0), id0, &ctx);
                }
            }.run, .{&mux});

            const h1 = try std.Thread.spawn(.{}, struct {
                fn run(m: *MuxType) !void {
                    var ctx = BobContext{};
                    try Runner1.runProtocol(.bob, null, false, m.handle(1), id1, &ctx);
                }
            }.run, .{&mux});

            h0.join();
            h1.join();

            mux.stop();
            mux.wait();
        }
    }.run, .{ io, addr });

    // ---- Alice: accept, run both protocols (sequentially) ----
    {
        var stream = try server.accept(io);
        defer stream.close(io);

        var mux = MuxType.init(io, stream);

        var alice_ctx1 = AliceContext{
            .io = io,
            .xors = undefined,
            .random = undefined,
        };

        io.random(@ptrCast(&alice_ctx1.xors));
        alice_ctx1.random = alice_ctx1.xors.random();

        std.debug.print("=== Running Counter (proto 0) ===\n", .{});

        const t1 = try std.Thread.spawn(.{}, Runner0.runProtocol, .{ .alice, null, false, mux.handle(0), id0, &alice_ctx1 });
        defer t1.join();

        var alice_ctx2 = AliceContext{
            .io = io,
            .xors = undefined,
            .random = undefined,
        };

        io.random(@ptrCast(&alice_ctx2.xors));
        alice_ctx2.random = alice_ctx2.xors.random();

        std.debug.print("=== Running Ping (proto 1) ===\n", .{});

        const t2 = try std.Thread.spawn(.{}, Runner1.runProtocol, .{ .alice, null, false, mux.handle(1), id1, &alice_ctx2 });
        defer t2.join();
    }

    bob.join();
}
