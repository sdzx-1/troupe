const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;

pub fn main() !void {
    var ctx: i32 = 0;
    // The meaning of `undefined` here is: the receiver is empty,
    //  therefore the channel will not be used.
    try Runner.runProtocol(.a, undefined, undefined, curr_id, &ctx);
}

pub const EnterFsmState = A;

pub const Runner = troupe.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

const Role = enum { a, b, c, d };
const Context = struct {
    a: type = i32,
    b: type = i32,
    c: type = i32,
    d: type = i32,
};

fn mk_info(
    StateName: []const u8,
) troupe.ProtocolInfo("counter", Role, Context{}, &.{.a}, &.{}) {
    //`internal_roles` is 1, which is equivalent to `polystate`.
    return .{ .name = StateName, .sender = .a, .receiver = &.{} };
}

const A = union(enum) {
    to_b: Data(void, B),
    exit: Data(void, troupe.Exit),

    pub const info = mk_info("A");

    pub fn process(ctx: *i32) !@This() {
        std.debug.print("ctx: {d}\n", .{ctx.*});
        if (ctx.* > 10) return .{ .exit = .{ .data = {} } };
        return .{ .to_b = .{ .data = {} } };
    }
};
const B = union(enum) {
    to_b: Data(void, A),

    pub const info = mk_info("B");

    pub fn process(ctx: *i32) !@This() {
        ctx.* += 1;
        return .{ .to_b = .{ .data = {} } };
    }
};
