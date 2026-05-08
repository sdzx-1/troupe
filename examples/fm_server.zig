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

    // ── Parse command-line arguments ───────────────────────────
    var ip: []const u8 = "0.0.0.0";
    var port: u16 = 12345;
    var root_dir = std.Io.Dir.cwd();

    {
        var args_iter = std.process.Args.Iterator.init(init.minimal.args);
        defer args_iter.deinit();
        _ = args_iter.next(); // program name
        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--ip")) {
                ip = args_iter.next() orelse {
                    std.debug.print("error: --ip requires an argument\n", .{});
                    return;
                };
            } else if (std.mem.eql(u8, arg, "--port")) {
                const port_str = args_iter.next() orelse {
                    std.debug.print("error: --port requires an argument\n", .{});
                    return;
                };
                port = std.fmt.parseInt(u16, port_str, 10) catch {
                    std.debug.print("error: invalid port '{s}'\n", .{port_str});
                    return;
                };
            } else if (std.mem.eql(u8, arg, "--dir")) {
                const dir_str = args_iter.next() orelse {
                    std.debug.print("error: --dir requires an argument\n", .{});
                    return;
                };
                root_dir = try root_dir.openDir(io, dir_str, .{});
            } else {
                std.debug.print("error: unknown argument '{s}'\n", .{arg});
                std.debug.print("usage: fm_server [--ip <ip>] [--port <port>] [--dir <path>]\n", .{});
                return;
            }
        }
    }

    const address = try net.IpAddress.parse(ip, port);

    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("Remote FM server listening on {s}:{d}\n", .{ ip, port });

    const stream = try server.accept(io);
    defer stream.close(io);

    var sock_rbuf: [8192]u8 = undefined;
    var sock_wbuf: [8192]u8 = undefined;
    var sock_reader = stream.reader(io, &sock_rbuf);
    var sock_writer = stream.writer(io, &sock_wbuf);

    var server_ctx: remote_fm.ServerContext = .{
        .allocator = gpa,
        .io = io,
        .root_dir = root_dir,
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
