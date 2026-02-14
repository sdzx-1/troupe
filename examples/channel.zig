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
    queue_a: *std.Io.Queue(u8),
    buff_a: []u8,
    queue_b: *std.Io.Queue(u8),
    buff_b: []u8,
    io: std.Io,
    gpa: std.mem.Allocator,

    pub fn recv(self: @This(), state_id: anytype, T: type) !T {
        _ = try self.queue_b.getOne(self.io);
        var reader = std.Io.Reader.fixed(self.buff_b);
        const val = try Codec.decode(&reader, state_id, T);
        return val;
    }

    pub fn send(self: @This(), state_id: anytype, val: anytype) !void {
        var buff_writer = std.Io.Writer.fixed(self.buff_a);
        try Codec.encode(&buff_writer, state_id, val);
        try self.queue_a.putOne(self.io, 0);
    }
};

pub const MvarChannel = struct {
    mvar_a: *Mvar,
    mvar_b: *Mvar,

    pub fn recv(self: @This(), state_id: anytype, T: type) !T {
        return try self.mvar_a.recv(state_id, T);
    }

    pub fn send(self: @This(), state_id: anytype, val: anytype) !void {
        try self.mvar_b.send(state_id, val);
    }
};

pub const Mvar = struct {
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    state: MvarState,
    buff: []u8,
    size: usize,
    io: std.Io,

    pub const MvarState = enum { full, empty };

    pub fn init(io: std.Io, gpa: std.mem.Allocator, len: usize) !*Mvar {
        const ref = try gpa.create(Mvar);
        const buff = try gpa.alloc(u8, len);
        ref.* = .{
            .mutex = .init,
            .cond = .init,
            .state = .empty,
            .buff = buff,
            .size = 0,
            .io = io,
        };

        return ref;
    }

    pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        gpa.free(self.buff);
        gpa.destroy(self);
    }

    pub fn recv(self: *@This(), state_id: anytype, T: type) !T {
        try self.mutex.lock(self.io);

        while (self.state == .empty) {
            try self.cond.wait(self.io, &self.mutex);
        }

        var reader = std.Io.Reader.fixed(self.buff);
        const val = try Codec.decode(&reader, state_id, T);

        self.state = .empty;

        self.mutex.unlock(self.io);
        self.cond.signal(self.io);

        return val;
    }

    pub fn send(self: *@This(), state_id: anytype, val: anytype) !void {
        try self.mutex.lock(self.io);

        while (self.state == .full) {
            try self.cond.wait(self.io, &self.mutex);
        }

        var writer = std.Io.Writer.fixed(self.buff);
        try Codec.encode(&writer, state_id, val);
        self.size = writer.buffered().len;

        self.state = .full;
        self.mutex.unlock(self.io);
        self.cond.signal(self.io);
    }
};
