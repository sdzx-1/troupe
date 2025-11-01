const std = @import("std");
const Codec = @import("Codec.zig");
const net = std.net;

//stream channel

pub const StreamChannel = struct {
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    log: bool = false,
    master: []const u8 = &.{},
    other: []const u8 = &.{},

    pub fn recv(self: @This(), io: std.Io, state_id: anytype, T: type) !T {
        _ = io;
        const res = try Codec.decode(self.reader, state_id, T);
        if (self.log) std.debug.print("{s} recv form {s}: {any}\n", .{ self.master, self.other, res });
        return res;
    }

    pub fn send(self: @This(), state_id: anytype, val: anytype) !void {
        if (self.log) std.debug.print("{s} send to   {s}: {any}\n", .{ self.master, self.other, val });
        try Codec.encode(self.writer, state_id, val);
    }
};

pub const QueueChannel = struct {
    queue_a: *std.Io.Queue([]const u8),
    queue_b: *std.Io.Queue([]const u8),
    io: std.Io,
    gpa: std.mem.Allocator,

    pub fn recv(self: @This(), state_id: anytype, T: type) !T {
        const str = try self.queue_b.getOne(self.io);
        var reader = std.Io.Reader.fixed(str);
        const val = try Codec.decode(&reader, state_id, T);
        self.gpa.free(str);
        return val;
    }

    pub fn send(self: @This(), state_id: anytype, val: anytype) !void {
        var allocating_writer = std.Io.Writer.Allocating.init(self.gpa);
        try Codec.encode(&allocating_writer.writer, state_id, val);
        try self.queue_a.putOne(self.io, allocating_writer.written());
    }
};

//Mvar channel
pub const MvarChannel = struct {
    queue_a: *std.Io.Queue([]const u8),
    queue_b: *std.Io.Queue([]const u8),

    pub fn recv(self: @This(), io: std.Io, gpa: std.mem.Allocator, state_id: anytype, T: type) !T {
        const str = try self.queue_b.getOne(io);
        var reader = std.Io.Reader.fixed(str);
        const val = try Codec.decode(&reader, state_id, T);
        gpa.free(str);
        return val;
    }

    pub fn send(self: @This(), io: std.Io, gpa: std.mem.Allocator, state_id: anytype, val: anytype) !void {
        var allocating_writer = std.Io.Writer.Allocating.init(gpa);
        try Codec.encode(&allocating_writer.writer, state_id, val);
        try self.queue_a.putOne(io, allocating_writer.written());
    }
};

pub fn MvarChannelMap(Role: type) type {
    return struct {
        hashmap: std.AutoArrayHashMapUnmanaged([2]u8, MvarChannel),
        log: bool = true,
        msg_delay: ?i64 = 10, //ms
        start_timestamp: std.Io.Timestamp,
        gpa: std.mem.Allocator,

        pub fn init(io: std.Io, gpa: std.mem.Allocator) !@This() {
            return .{
                .hashmap = .empty,
                .start_timestamp = std.Io.Clock.now(.awake, io),
                .gpa = gpa,
            };
        }

        //TODO: deinit

        pub fn generate_all_MvarChannel(
            self: *@This(),
            gpa: std.mem.Allocator,
        ) !void {
            const enum_fields = @typeInfo(Role).@"enum".fields;
            var i: usize = 0;
            while (i < enum_fields.len) : (i += 1) {
                var j = i + 1;
                while (j < enum_fields.len) : (j += 1) {
                    const mvar_a = try gpa.create(std.Io.Queue([]const u8));
                    mvar_a.* = .init(try gpa.alloc([]const u8, 2));

                    const mvar_b = try gpa.create(std.Io.Queue([]const u8));
                    mvar_b.* = .init(try gpa.alloc([]const u8, 2));

                    try self.hashmap.put(
                        gpa,
                        .{ @as(u8, @intCast(i)), @as(u8, @intCast(j)) },
                        .{ .queue_a = mvar_a, .queue_b = mvar_b },
                    );

                    try self.hashmap.put(
                        gpa,
                        .{ @as(u8, @intCast(j)), @as(u8, @intCast(i)) },
                        .{ .queue_a = mvar_b, .queue_b = mvar_a },
                    );
                }
            }
        }

        pub fn recv(self: @This(), io: std.Io, curr_role: Role, other: Role, state_id: anytype, T: type) !T {
            const mvar_channel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            const res = try mvar_channel.recv(io, self.gpa, state_id, T);
            if (self.msg_delay) |delay| try io.sleep(.fromMilliseconds(delay), .awake);
            return res;
        }

        pub fn send(self: @This(), io: std.Io, curr_role: Role, other: Role, state_id: anytype, val: anytype) !void {
            if (self.log) std.debug.print("[{d}] statd_id: {d},  {t} send to {t}: {any}\n", .{
                // (try std.time.Instant.now()).since(self.start_timestamp),
                (std.Io.Clock.now(.awake, io)).nanoseconds,
                state_id,
                curr_role,
                other,
                val,
            });
            const mvar_channel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            try mvar_channel.send(io, self.gpa, state_id, val);
        }
    };
}
