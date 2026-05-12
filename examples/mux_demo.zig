const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;
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
    done: Data(void, troupe.Exit),

    pub const info: troupe.ProtocolInfo("counter", Role, Context{}, &.{ .alice, .bob }, &.{}) = .{
        .name = "Counter",
        .sender = .alice,
        .receiver = &.{.bob},
    };

    pub fn process(ctx: *AliceContext) !@This() {
        ctx.counter_round += 1;
        if (ctx.counter_round > 5) return .{ .done = .{ .data = {} } };
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
    done: Data(void, troupe.Exit),

    pub const info: troupe.ProtocolInfo("ping", Role, Context{}, &.{ .alice, .bob }, &.{}) = .{
        .name = "Ping",
        .sender = .alice,
        .receiver = &.{.bob},
    };

    pub fn process(ctx: *AliceContext) !@This() {
        ctx.ping_round += 1;
        if (ctx.ping_round > 3) return .{ .done = .{ .data = {} } };
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

const Runner0 = troupe.Runner(CounterProto);
const Runner1 = troupe.Runner(PingProto);

const id0 = Runner0.idFromState(CounterProto);
const id1 = Runner1.idFromState(PingProto);

// ────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────

fn muxForConn(io: std.Io, stream: std.Io.net.Stream, gpa: std.mem.Allocator) !Mux(Role, 2, 4096) {
    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var writer = stream.writer(io, &wbuf);
    return try Mux(Role, 2, 4096).init(io, &reader.interface, &writer.interface, gpa);
}

const MuxType = Mux(Role, 2, 4096);

// ────────────────────────────────────────────────────────────────────
// main
// ────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Use a fixed port so both threads know where to connect.
    const addr = try net.IpAddress.parse("127.0.0.1", 9876);
    var server = try addr.listen(io, .{ .reuse_address = true });

    // ---- Bob: connect, start reader + both Runners ----
    const bob = try std.Thread.spawn(.{}, struct {
        fn run(io_: std.Io, addr_: net.IpAddress, gpa_: std.mem.Allocator) !void {
            var bob_stream = try addr_.connect(io_, .{ .mode = .stream });
            defer bob_stream.close(io_);

            var mux = try muxForConn(io_, bob_stream, gpa_);
            mux.start();
            defer {
                mux.stop();
                mux.wait();
            }

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
        }
    }.run, .{ io, addr, gpa });

    // ---- Alice: accept, run both protocols (sequentially) ----
    {
        var stream = try server.accept(io);
        defer stream.close(io);

        var mux = try muxForConn(io, stream, gpa);

        var alice_ctx = AliceContext{};

        std.debug.print("=== Running Counter (proto 0) ===\n", .{});
        try Runner0.runProtocol(.alice, null, false, mux.handle(0), id0, &alice_ctx);

        std.debug.print("=== Running Ping (proto 1) ===\n", .{});
        try Runner1.runProtocol(.alice, null, false, mux.handle(1), id1, &alice_ctx);
    }

    bob.join();
}
