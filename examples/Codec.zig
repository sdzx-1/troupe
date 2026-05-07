const std = @import("std");
const Notify = @import("troupe").Notify;
const builtin = @import("builtin");
const native_endian = builtin.target.cpu.arch.endian();

pub fn encode(writer: *std.Io.Writer, state_id: anytype, val: anytype) !void {
    const id: u8 = @intFromEnum(state_id);
    try writer.writeByte(id);
    if (@TypeOf(val) == Notify) {
        try writer.writeInt(u32, val.troupe_notify, native_endian);
    } else {
        switch (val) {
            inline else => |msg, tag| {
                try writer.writeByte(@intFromEnum(tag));
                const data = msg.data;
                switch (@typeInfo(@TypeOf(data))) {
                    .void => {},
                    .bool => {
                        const v: u8 = if (data) 1 else 0;
                        try writer.writeInt(u8, v, native_endian);
                    },
                    .int => {
                        try writer.writeInt(@TypeOf(data), data, native_endian);
                    },
                    .@"struct" => {
                        try data.encode(writer);
                    },
                    .pointer => |p| {
                        if (p.is_const == true and p.child == u8) {
                            const len: usize = data.len;
                            try writer.writeInt(usize, len, native_endian);
                            try writer.writeAll(data);
                        } else {
                            @compileError("Not impl!");
                        }
                    },
                    else => @compileError("Not impl!"),
                }
            },
        }
    }
    try writer.flush();
}

pub fn TagPayloadByName(comptime U: type, comptime tag_name: []const u8) type {
    const info = @typeInfo(U).@"union";

    inline for (info.fields) |field_info| {
        if (comptime std.mem.eql(u8, field_info.name, tag_name))
            return field_info.type;
    }

    @compileError("no field '" ++ tag_name ++ "' in union '" ++ @typeName(U) ++ "'");
}

pub fn decode(reader: *std.Io.Reader, state_id: anytype, T: type) !T {
    const id: u8 = @intFromEnum(state_id);
    const rid = try reader.takeByte();
    if (id != rid and T != Notify) {
        std.debug.print("id: {d}, rid: {d}\n", .{ id, rid });
        return error.IncorrectStatusReceived;
    }
    if (T == Notify) {
        const next_id = try reader.takeInt(u32, native_endian);
        return .{ .troupe_notify = next_id };
    } else {
        const recv_tag_num = try reader.takeByte();
        const tag: std.meta.Tag(T) = @enumFromInt(recv_tag_num);
        switch (tag) {
            inline else => |t| {
                const Data = @FieldType(TagPayloadByName(T, @tagName(t)), "data");
                switch (@typeInfo(Data)) {
                    .void => {
                        return @unionInit(T, @tagName(t), .{ .data = {} });
                    },
                    .bool => {
                        const data = try reader.takeInt(u8, native_endian);
                        const bv: bool = switch (data) {
                            0 => false,
                            1 => true,
                            else => unreachable,
                        };
                        return @unionInit(T, @tagName(t), .{ .data = bv });
                    },
                    .int => {
                        const data = try reader.takeInt(Data, native_endian);
                        return @unionInit(T, @tagName(t), .{ .data = data });
                    },

                    .pointer => |p| {
                        if (p.is_const == true and p.child == u8) {
                            const len = try reader.takeInt(usize, native_endian);
                            const str = try reader.take(len);
                            return @unionInit(T, @tagName(t), .{ .data = str });
                        } else {
                            @compileError("Not impl!");
                        }
                    },

                    .@"struct" => {
                        const data = try Data.decode(reader);
                        return @unionInit(T, @tagName(t), .{ .data = data });
                    },
                    else => @compileError("Not impl!"),
                }
            },
        }
    }
}
