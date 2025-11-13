const std = @import("std");
const Notify = @import("troupe").Notify;

pub fn encode(writer: *std.Io.Writer, state_id: anytype, val: anytype) !void {
    const id: u8 = @intFromEnum(state_id);
    try writer.writeByte(id);
    if (@TypeOf(val) == Notify) {
        try writer.writeByte(val.troupe_notify);
    } else {
        switch (val) {
            inline else => |msg, tag| {
                try writer.writeByte(@intFromEnum(tag));
                const data = msg.data;
                switch (@typeInfo(@TypeOf(data))) {
                    .void => {},
                    .bool => {
                        const v: u8 = if (data) 1 else 0;
                        try writer.writeInt(u8, v, .little);
                    },
                    .int => {
                        try writer.writeInt(@TypeOf(data), data, .little);
                    },
                    .@"struct" => {
                        try data.encode(writer);
                    },
                    .pointer => |p| {
                        if (p.is_const == true and p.child == u8) {
                            const len: usize = data.len;
                            try writer.writeInt(usize, len, .little);
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

pub fn decode(reader: *std.Io.Reader, state_id: anytype, T: type) !T {
    const id: u8 = @intFromEnum(state_id);
    const rid = try reader.takeByte();
    if (id != rid and T != Notify) {
        std.debug.print("id: {d}, rid: {d}\n", .{ id, rid });
        return error.IncorrectStatusReceived;
    }
    if (T == Notify) {
        const next_id = try reader.takeByte();
        return .{ .troupe_notify = next_id };
    } else {
        const recv_tag_num = try reader.takeByte();
        const tag: std.meta.Tag(T) = @enumFromInt(recv_tag_num);
        switch (tag) {
            inline else => |t| {
                const Data = @FieldType(std.meta.TagPayload(T, t), "data");
                switch (@typeInfo(Data)) {
                    .void => {
                        return @unionInit(T, @tagName(t), .{ .data = {} });
                    },
                    .bool => {
                        const data = try reader.takeInt(u8, .little);
                        const bv: bool = switch (data) {
                            0 => false,
                            1 => true,
                            else => unreachable,
                        };
                        return @unionInit(T, @tagName(t), .{ .data = bv });
                    },
                    .int => {
                        const data = try reader.takeInt(Data, .little);
                        return @unionInit(T, @tagName(t), .{ .data = data });
                    },

                    .pointer => |p| {
                        if (p.is_const == true and p.child == u8) {
                            const len = try reader.takeInt(usize, .little);
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
