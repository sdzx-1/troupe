const std = @import("std");
const Codec = @import("Codec.zig");
const Notify = @import("polyrole").Notify;
const net = std.net;
const Io = std.Io;

//stream channel

pub const StreamChannel = struct {
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    log: bool = false,
    master: []const u8 = &.{},
    other: []const u8 = &.{},

    pub fn recv(self: @This(), state_id: anytype, T: type) !T {
        const res = try Codec.decode(self.reader, state_id, T);
        if (self.log) std.debug.print("{s} recv form {s}: {any}\n", .{ self.master, self.other, res });
        return res;
    }

    pub fn send(self: @This(), state_id: anytype, val: anytype) !void {
        if (self.log) std.debug.print("{s} send to   {s}: {any}\n", .{ self.master, self.other, val });
        try Codec.encode(self.writer, state_id, val);
    }
};

//Mvar channel
pub const MvarChannel = struct {
    mvar_a: *Mvar,
    mvar_b: *Mvar,
    xoshiro256: *std.Random.Xoshiro256,

    pub fn recv(self: @This(), state_id: anytype, T: type) !struct { usize, T } {
        return try self.mvar_a.recv(state_id, T);
    }

    pub fn send(self: @This(), msg_id: usize, state_id: anytype, val: anytype) !void {
        try self.mvar_b.send(msg_id, state_id, val);
    }
};

pub const Mvar = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,

    state: MvarState = .empty,
    buff: []u8,
    msg_id: usize = 0,
    size: usize = 0,

    pub const MvarState = enum { full, empty };

    pub fn init(io: Io, gpa: std.mem.Allocator, len: usize) !*Mvar {
        const ref = try gpa.create(Mvar);
        const buff = try gpa.alloc(u8, len);
        ref.* = .{ .io = io, .buff = buff };
        return ref;
    }

    pub fn recv(self: *@This(), state_id: anytype, T: type) !struct { usize, T } {
        try self.mutex.lock(self.io);

        while (self.state == .empty) {
            try self.cond.wait(self.io, &self.mutex);
        }

        var reader = std.Io.Reader.fixed(self.buff);
        const msg_id = self.msg_id;
        const val = try Codec.decode(&reader, state_id, T);

        self.state = .empty;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);

        return .{ msg_id, val };
    }

    pub fn send(self: *@This(), msg_id: usize, state_id: anytype, val: anytype) !void {
        try self.mutex.lock(self.io);

        while (self.state == .full) {
            try self.cond.wait(self.io, &self.mutex);
        }

        var writer = std.Io.Writer.fixed(self.buff);
        try Codec.encode(&writer, state_id, val);
        self.size = writer.buffered().len;

        self.state = .full;
        self.msg_id = msg_id;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
    }
};

pub fn MvarChannelMap(Role: type) type {
    return struct {
        io: Io,
        log: bool,
        allocted: std.ArrayList(struct { *Mvar, *Mvar, *std.Random.Xoshiro256 }),
        hashmap: std.AutoArrayHashMapUnmanaged([2]u8, MvarChannel),
        counter: *std.atomic.Value(usize),

        pub fn init(io: Io, log: bool, counter: *std.atomic.Value(usize)) @This() {
            return .{ .allocted = .empty, .log = log, .io = io, .hashmap = .empty, .counter = counter };
        }

        pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
            for (self.allocted.items) |val| {
                gpa.free(val.@"0".buff);
                gpa.free(val.@"1".buff);
                gpa.destroy(val.@"0");
                gpa.destroy(val.@"1");

                gpa.destroy(val.@"2");
            }
            self.allocted.deinit(gpa);

            self.hashmap.deinit(gpa);
        }

        pub fn generate_all_MvarChannel(
            self: *@This(),
            gpa: std.mem.Allocator,
            comptime buff_size: usize,
        ) !void {
            const enum_fields = @typeInfo(Role).@"enum".fields;
            var i: usize = 0;
            while (i < enum_fields.len) : (i += 1) {
                var j = i + 1;
                while (j < enum_fields.len) : (j += 1) {
                    const mvar_a = try Mvar.init(self.io, gpa, buff_size);
                    const mvar_b = try Mvar.init(self.io, gpa, buff_size);
                    const tmp_buff = try gpa.create(std.Random.Xoshiro256);
                    self.io.random(@ptrCast(&tmp_buff.s));
                    try self.allocted.append(gpa, .{ mvar_a, mvar_b, tmp_buff });

                    try self.hashmap.put(
                        gpa,
                        .{ @as(u8, @intCast(i)), @as(u8, @intCast(j)) },
                        .{ .mvar_a = mvar_a, .mvar_b = mvar_b, .xoshiro256 = tmp_buff },
                    );

                    try self.hashmap.put(
                        gpa,
                        .{ @as(u8, @intCast(j)), @as(u8, @intCast(i)) },
                        .{ .mvar_a = mvar_b, .mvar_b = mvar_a, .xoshiro256 = tmp_buff },
                    );
                }
            }
        }

        pub fn recv(self: @This(), curr_role: Role, other: Role, state_id: anytype, T: type) !T {
            const mvar_channel: MvarChannel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            const res = try mvar_channel.recv(state_id, T);
            if (self.log) {
                std.debug.print("{t} recv: {any}\n", .{ curr_role, res[1] });
            }
            return res[1];
        }

        pub fn send(self: @This(), curr_role: Role, other: Role, state_id: anytype, val: anytype) !void {
            const mvar_channel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            const msg_id = self.counter.fetchAdd(1, .seq_cst);
            if (self.log) {
                std.debug.print("{t} send: {any}\n", .{ curr_role, val });
            }
            try mvar_channel.send(msg_id, state_id, val);
        }
    };
}
