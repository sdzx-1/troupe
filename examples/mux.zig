const std = @import("std");
const Codec = @import("Codec.zig");
const native_endian = @import("builtin").target.cpu.arch.endian();

/// A blocking single-slot queue for raw bytes.
/// Thread-safe: one producer (reader thread), one consumer (Runner thread).
pub fn Slot(comptime buf_size: usize) type {
    return struct {
        io: std.Io,

        mutex: std.Io.Mutex = .init,
        cond: std.Io.Condition = .init,
        state: enum { empty, full } = .empty,
        buf: [buf_size]u8 = undefined,
        size: usize = 0,

        pub fn init(io: std.Io) @This() {
            return .{ .io = io };
        }

        pub fn put(self: *@This(), data: []const u8) void {
            std.debug.assert(data.len <= buf_size);
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.state == .full) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
            @memcpy(self.buf[0..data.len], data);
            self.size = data.len;
            self.state = .full;
            self.cond.signal(self.io);
        }

        pub fn get(self: *@This(), dest: []u8) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            while (self.state == .empty) {
                self.cond.waitUncancelable(self.io, &self.mutex);
            }
            const n = self.size;
            @memcpy(dest[0..n], self.buf[0..n]);
            self.size = 0;
            self.state = .empty;
            self.cond.signal(self.io);
            return n;
        }
    };
}

/// Multiplexed session over a single TCP connection.
///
/// Wire format of each frame:
///   [proto_id: u16][sender: u8][receiver: u8][payload_len: u32][payload: ...]
///   where payload is Codec-encoded data (state_id + tag + serialized fields).
pub fn Mux(comptime Role: type, comptime max_protos: usize, comptime slot_size: usize) type {
    const role_count = std.meta.fields(Role).len;

    return struct {
        const Self = @This();

        io: std.Io,

        tcp_writer: *std.Io.Writer,
        tcp_reader: *std.Io.Reader,
        send_mutex: std.Io.Mutex = .init,

        // queues[proto_id][receiver_role_index]
        queues: [max_protos][role_count]*Slot(slot_size),

        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        reader_thread: ?std.Thread = null,

        pub fn init(
            io: std.Io,
            tcp_reader: *std.Io.Reader,
            tcp_writer: *std.Io.Writer,
            gpa: std.mem.Allocator,
        ) !Self {
            var queues: [max_protos][role_count]*Slot(slot_size) = undefined;
            for (&queues) |*proto_queues| {
                for (proto_queues) |*slot_ptr| {
                    const slot = try gpa.create(Slot(slot_size));
                    slot.* = Slot(slot_size).init(io);
                    slot_ptr.* = slot;
                }
            }
            return .{
                .io = io,
                .tcp_writer = tcp_writer,
                .tcp_reader = tcp_reader,
                .queues = queues,
            };
        }

        /// Start the reader thread in the background.
        pub fn start(self: *Self) void {
            self.running.store(true, .monotonic);
            self.reader_thread = std.Thread.spawn(.{}, readerLoop, .{self}) catch @panic("failed to spawn reader thread");
        }

        /// Signal the reader thread to stop and wait for it.
        pub fn stop(self: *Self) void {
            self.running.store(false, .monotonic);
        }

        pub fn wait(self: *Self) void {
            if (self.reader_thread) |t| t.join();
        }

        fn readerLoop(self: *Self) void {
            while (self.running.load(.monotonic)) {
                const proto_id = self.tcp_reader.takeInt(u16, native_endian) catch break;
                const _sender = self.tcp_reader.takeByte() catch break; // sender — not needed for routing
                _ = _sender;
                const receiver_byte = self.tcp_reader.takeByte() catch break;
                const payload_len = self.tcp_reader.takeInt(u32, native_endian) catch break;

                if (payload_len > slot_size) {
                    std.debug.panic("mux: payload too large ({d} > {d})", .{ payload_len, slot_size });
                }

                // take() may reference the reader's internal buffer; copy into Slot immediately.
                const data = self.tcp_reader.take(payload_len) catch break;
                var buf: [slot_size]u8 = undefined;
                @memcpy(buf[0..payload_len], data);

                const receiver: Role = @enumFromInt(receiver_byte);
                const role_idx = @intFromEnum(receiver);
                self.queues[proto_id][role_idx].put(buf[0..payload_len]);
            }
        }

        /// Send a message frame.  Encodes the value to a temporary buffer first,
        /// then writes the frame header + encoded payload to the TCP writer.
        pub fn send(self: *Self, proto_id: u16, sender: Role, receiver: Role, state_id: anytype, val: anytype) !void {
            var temp_buf: [slot_size]u8 = undefined;
            var temp_writer = std.Io.Writer.fixed(&temp_buf);
            try Codec.encode(&temp_writer, state_id, val);
            const encoded = temp_writer.buffered();

            self.send_mutex.lockUncancelable(self.io);
            defer self.send_mutex.unlock(self.io);
            try self.tcp_writer.writeInt(u16, proto_id, native_endian);
            try self.tcp_writer.writeByte(@intFromEnum(sender));
            try self.tcp_writer.writeByte(@intFromEnum(receiver));
            try self.tcp_writer.writeInt(u32, @intCast(encoded.len), native_endian);
            try self.tcp_writer.writeAll(encoded);
            try self.tcp_writer.flush();
        }

        /// Receive a message.  Blocks on the per-(proto, role) Slot.
        pub fn recv(self: *Self, proto_id: u16, role: Role, state_id: anytype, T: type) !T {
            const role_idx = @intFromEnum(role);
            var buf: [slot_size]u8 = undefined;
            const n = self.queues[proto_id][role_idx].get(&buf);
            var reader = std.Io.Reader.fixed(buf[0..n]);
            return try Codec.decode(&reader, state_id, T);
        }

        /// Create a ProtocolHandle bound to `proto_id` for use with Runner.runProtocol.
        pub fn handle(self: *Self, proto_id: u16) ProtocolHandle(Role, Self) {
            return .{ .mux = self, .proto_id = proto_id };
        }
    };
}

/// Thin wrapper that implements the `send`/`recv` interface expected by Runner.runProtocol
/// (the same shape as MvarChannelMap), binding a specific proto_id into the Mux calls.
pub fn ProtocolHandle(comptime Role: type, comptime MuxType: type) type {
    return struct {
        mux: *MuxType,
        proto_id: u16,

        pub fn send(self: @This(), curr_role: Role, other: Role, state_id: anytype, val: anytype) !void {
            try self.mux.send(self.proto_id, curr_role, other, state_id, val);
        }

        pub fn recv(self: @This(), curr_role: Role, sender: Role, state_id: anytype, T: type) !T {
            _ = sender;
            return try self.mux.recv(self.proto_id, curr_role, state_id, T);
        }
    };
}
