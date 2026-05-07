const std = @import("std");
const Notify = @import("troupe").Notify;
const builtin = @import("builtin");
const native_endian = builtin.target.cpu.arch.endian();

pub fn encode(writer: *std.Io.Writer, state_id: anytype, val: anytype) !void {
    const id: u32 = @intFromEnum(state_id);
    try writer.writeInt(u32, id, native_endian);
    if (@TypeOf(val) == Notify) {
        try writer.writeInt(u32, val.troupe_notify, native_endian);
    } else {
        switch (val) {
            inline else => |msg, tag| {
                try writer.writeByte(@intFromEnum(tag));
                const data = msg.data;
                try encode_anytype(writer, data);
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
    const id: u32 = @intFromEnum(state_id);
    const rid = try reader.takeInt(u32, native_endian);
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
                return @unionInit(T, @tagName(t), .{ .data = try decode_type(reader, Data) });
            },
        }
    }
}

pub fn encode_anytype(writer: *std.Io.Writer, data: anytype) !void {
    switch (@typeInfo(@TypeOf(data))) {
        .void => {},
        .bool => {
            const v: u8 = if (data) 1 else 0;
            try writer.writeByte(v);
        },
        .int => {
            try writer.writeInt(@TypeOf(data), data, native_endian);
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
        .@"struct" => |stru| {
            inline for (stru.fields) |struct_field| {
                try encode_anytype(writer, @field(data, struct_field.name));
            }
        },
        else => @compileError("Not impl!"),
    }
}

pub fn decode_type(reader: *std.Io.Reader, Data: type) !Data {
    switch (@typeInfo(Data)) {
        .void => return {},
        .bool => {
            const data = try reader.takeByte();
            const bv: bool = switch (data) {
                0 => false,
                1 => true,
                else => unreachable,
            };
            return bv;
        },
        .int => {
            const data = try reader.takeInt(Data, native_endian);
            return data;
        },
        .pointer => |p| {
            if (p.is_const == true and p.child == u8) {
                const len = try reader.takeInt(usize, native_endian);
                const str = try reader.take(len);
                return str;
            } else {
                @compileError("Not impl!");
            }
        },
        .@"struct" => |stru| {
            var data: Data = undefined;
            inline for (stru.fields) |struct_field| {
                @field(data, struct_field.name) = try decode_type(reader, struct_field.type);
            }
            return data;
        },
        else => @compileError("Not impl!"),
    }
}
