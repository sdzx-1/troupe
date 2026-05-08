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

    const address = try net.IpAddress.parse("0.0.0.0", 12345);

    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("Remote FM server listening on 0.0.0.0:12345\n", .{});

    const stream = try server.accept(io);
    defer stream.close(io);

    var sock_rbuf: [8192]u8 = undefined;
    var sock_wbuf: [8192]u8 = undefined;
    var sock_reader = stream.reader(io, &sock_rbuf);
    var sock_writer = stream.writer(io, &sock_wbuf);

    var server_ctx: remote_fm.ServerContext = .{
        .allocator = gpa,
        .io = io,
        .root_dir = std.Io.Dir.cwd(),
    };

    Runner.runProtocol(
        .server,
        null,
        true,
        .{
            .client = StreamChannel{
                .reader = &sock_reader.interface,
                .writer = &sock_writer.interface,
            },
        },
        curr_id,
        &server_ctx,
    ) catch |err| {
        std.debug.print("Connection closed: {}\n", .{err});
    };

    // Final cleanup: free any pending allocation
    if (server_ctx.pending_free.len > 0) {
        gpa.free(server_ctx.pending_free);
    }
}
