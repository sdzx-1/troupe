const std = @import("std");
const Codec = @import("Codec.zig");
const Notify = @import("troupe").Notify;
const net = std.net;

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
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    state: MvarState = .empty,
    buff: []u8,
    msg_id: usize = 0,
    size: usize = 0,

    pub const MvarState = enum { full, empty };

    pub fn init(gpa: std.mem.Allocator, len: usize) !*Mvar {
        const ref = try gpa.create(Mvar);
        const buff = try gpa.alloc(u8, len);
        ref.* = .{ .buff = buff };
        return ref;
    }

    pub fn recv(self: *@This(), state_id: anytype, T: type) !struct { usize, T } {
        self.mutex.lock();

        while (self.state == .empty) {
            self.cond.wait(&self.mutex);
        }

        var reader = std.Io.Reader.fixed(self.buff);
        const msg_id = self.msg_id;
        const val = try Codec.decode(&reader, state_id, T);

        self.state = .empty;
        self.mutex.unlock();
        self.cond.signal();

        return .{ msg_id, val };
    }

    pub fn send(self: *@This(), msg_id: usize, state_id: anytype, val: anytype) !void {
        self.mutex.lock();

        while (self.state == .full) {
            self.cond.wait(&self.mutex);
        }

        var writer = std.Io.Writer.fixed(self.buff);
        try Codec.encode(&writer, state_id, val);
        self.size = writer.buffered().len;

        self.state = .full;
        self.msg_id = msg_id;
        self.mutex.unlock();
        self.cond.signal();
    }
};

pub const Msg = union(enum) {
    notify: void,
    msg_tag: []const u8,
};

pub const LogArray = struct {
    mutex: std.Thread.Mutex,
    log_array: std.ArrayListUnmanaged(Log),
    allocator: std.mem.Allocator,

    pub const Log = struct {
        sender: u32,
        receiver: u32,
        msg_id: usize,
        send_timestamp: i64,
        recv_timestamp: i64,
        msg: Msg,

        pub fn curr_time_in_during(self: *const @This(), base_timestamp: i64, curr_time: f32) bool {
            const st: f32 = @floatFromInt(self.send_timestamp - base_timestamp);
            const rt: f32 = @floatFromInt(self.recv_timestamp - base_timestamp);

            // std.debug.print("{d}, <{d}>  {d}\n", .{ st, curr_time, rt });
            // std.debug.print("recv: {d}\n", .{self.recv_timestamp});

            return curr_time < rt and curr_time >= st;
        }
    };

    pub const SendLog = struct {
        curr_role: u32,
        other: u32,
        msg_id: usize,
        send_timestamp: i64,
        msg: Msg,
    };

    pub const RecvLog = struct {
        curr_role: u32,
        other: u32,
        msg_id: usize,
        recv_timestamp: i64,
    };

    fn lastIndexOfScalar(slice: []const Log, recv_log: RecvLog) ?usize {
        var i: usize = slice.len;
        while (i != 0) {
            i -= 1;
            if (slice[i].msg_id == recv_log.msg_id) return i;
        }
        return null;
    }

    pub fn append(self: *@This(), log: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (@TypeOf(log) == SendLog) {
            try self.log_array.append(self.allocator, .{
                .sender = log.curr_role,
                .receiver = log.other,
                .msg_id = log.msg_id,
                .send_timestamp = log.send_timestamp,
                .recv_timestamp = 0,
                .msg = log.msg,
            });
        } else if (@TypeOf(log) == RecvLog) {
            const idx = lastIndexOfScalar(self.log_array.items, log).?;
            self.log_array.items[idx].recv_timestamp = log.recv_timestamp;
        } else unreachable;
    }
};

pub fn MvarChannelMap(Role: type) type {
    return struct {
        hashmap: std.AutoArrayHashMapUnmanaged([2]u8, MvarChannel),
        log: bool = true,
        log_array: *LogArray,
        msg_delay: bool = true, //ms
        counter: *std.atomic.Value(usize),

        pub fn init(log_array: *LogArray, counter: *std.atomic.Value(usize)) @This() {
            return .{
                .hashmap = .empty,
                .log_array = log_array,
                .counter = counter,
            };
        }

        //TODO: deinit

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
                    const mvar_a = try Mvar.init(gpa, buff_size);
                    const mvar_b = try Mvar.init(gpa, buff_size);
                    const tmp_buff = try gpa.create(std.Random.Xoshiro256);
                    std.crypto.random.bytes(@ptrCast(&tmp_buff.s));

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
            if (self.msg_delay) {
                const random = mvar_channel.xoshiro256.random();
                std.Thread.sleep(std.time.ns_per_ms * random.intRangeAtMost(u64, 10, 30));
            }
            if (self.log) {
                const recv_log: LogArray.RecvLog = .{
                    .curr_role = @intFromEnum(curr_role),
                    .other = @intFromEnum(other),
                    .msg_id = res[0],
                    .recv_timestamp = std.time.milliTimestamp(),
                };
                try self.log_array.append(recv_log);
            }
            return res[1];
        }

        pub fn send(self: @This(), curr_role: Role, other: Role, state_id: anytype, val: anytype) !void {
            const mvar_channel = self.hashmap.get(.{ @intFromEnum(curr_role), @intFromEnum(other) }).?;
            const msg_id = self.counter.fetchAdd(1, .seq_cst);

            const msg: Msg = if (@TypeOf(val) == Notify) .notify else .{ .msg_tag = @tagName(val) };

            if (self.log) {
                const send_log: LogArray.SendLog = .{
                    .curr_role = @intFromEnum(curr_role),
                    .other = @intFromEnum(other),
                    .msg_id = msg_id,
                    .send_timestamp = std.time.milliTimestamp(),
                    .msg = msg,
                };
                try self.log_array.append(send_log);
            }
            try mvar_channel.send(msg_id, state_id, val);
        }
    };
}
