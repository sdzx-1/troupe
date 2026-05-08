const std = @import("std");
const troupe = @import("troupe");
const net = std.Io.net;
const channel = @import("channel.zig");
const StreamChannel = channel.StreamChannel;
const remote_fm = @import("./protocols/remote_fm.zig");

const Role = enum { client, server };

const Context = struct {
    client: type = remote_fm.ClientContext,
    server: type = remote_fm.ServerContext,
};

const FM = remote_fm.MkRemoteFM(Role, .client, .server, Context{}, troupe.Exit, troupe.Exit);

pub const EnterFsmState = FM.Command;
pub const Runner = troupe.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    const address = try net.IpAddress.parse("127.0.0.1", 12345);

    const socket = try address.connect(io, .{ .mode = .stream });
    defer socket.close(io);

    var sock_rbuf: [8192]u8 = undefined;
    var sock_wbuf: [8192]u8 = undefined;
    var sock_reader = socket.reader(io, &sock_rbuf);
    var sock_writer = socket.writer(io, &sock_wbuf);

    const std_in = std.Io.File.stdin();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std_in.reader(io, &stdin_buf);

    const std_out = std.Io.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std_out.writer(io, &stdout_buf);

    var client_ctx: remote_fm.ClientContext = .{
        .io = io,
        .allocator = gpa,
        .stdout_writer = &stdout_writer.interface,
        .stdin_reader = &stdin_reader.interface,
    };

    Runner.runProtocol(
        .client,
        null,
        true,
        .{
            .server = StreamChannel{
                .reader = &sock_reader.interface,
                .writer = &sock_writer.interface,
            },
        },
        curr_id,
        &client_ctx,
    ) catch |err| {
        std.debug.print("Disconnected: {}\n", .{err});
    };

    // Free any leftover upload data
    if (client_ctx.upload_data.len > 0) {
        gpa.free(client_ctx.upload_data);
    }
}
