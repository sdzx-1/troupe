const std = @import("std");
const ps = @import("polysession");
const channel = @import("channel.zig");
const StreamChannel = channel.StreamChannel;
const pingpong = @import("./protocols/pingpong.zig");
const sendfile = @import("./protocols/sendfile.zig");
const net = std.Io.net;

pub const AliceContext = struct {
    pingpong: pingpong.ClientContext,
    send_context: sendfile.SendContext,
};

pub const BobContext = struct {
    pingpong: pingpong.ServerContext,
    recv_context: sendfile.RecvContext,
};

pub const Role = enum { alice, bob };

pub const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
};

fn PingPong(NextFsmState: type) type {
    return pingpong.MkPingPong(Role, .alice, .bob, Context{}, .pingpong, .pingpong, NextFsmState);
}
fn SendFile(Successed: type, Failed: type) type {
    return sendfile.MkSendFile(Role, .alice, .bob, Context{}, 20 * 1024 * 1024, .send_context, .recv_context, Successed, Failed);
}

pub const EnterFsmState = PingPong(SendFile(PingPong(ps.Exit).Ping, ps.Exit).Start).Ping;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}).init;
    const gpa = gpa_instance.allocator();

    var threaded = std.Io.Threaded.init(gpa);
    const io = threaded.io();

    //create tmp dir
    var tmp_dir_instance = std.testing.tmpDir(.{});
    defer tmp_dir_instance.cleanup();
    const tmp_dir = tmp_dir_instance.dir;

    {
        const read_file = try tmp_dir.createFile("test_read", .{});
        defer read_file.close();
        const str: [1024 * 1024]u8 = @splat(65);
        for (0..100) |_| {
            try read_file.writeAll(&str);
        }
    }

    //Server
    const localhost = try net.IpAddress.parse("127.0.0.1", 6000);

    var server = try localhost.listen(io, .{});
    defer server.deinit(io);
    //

    const S = struct {
        fn run(io_: std.Io, server_address: net.IpAddress, dir: std.fs.Dir) !void {
            const socket = try net.IpAddress.connect(server_address, io_, .{ .mode = .stream });
            defer socket.close(io_);

            var reader_buf: [1024 * 1024 * 2]u8 = undefined;
            var writer_buf: [1024 * 1024 * 2]u8 = undefined;

            var stream_reader = socket.reader(io_, &reader_buf);
            var stream_writer = socket.writer(io_, &writer_buf);

            const write_file = try dir.createFile("test_write", .{});
            defer write_file.close();

            var file_writer_buf: [1024 * 1024 * 2]u8 = undefined;

            var file_writer = write_file.writer(&file_writer_buf);

            var client_context: BobContext = .{
                .pingpong = .{ .server_counter = 0 },
                .recv_context = .{
                    .writer = &file_writer.interface,
                },
            };

            try Runner.runProtocol(
                io_,
                .bob,
                true,
                .{
                    .alice = StreamChannel{
                        .reader = &stream_reader.interface,
                        .writer = &stream_writer.interface,
                        .log = false,
                    },
                },
                curr_id,
                &client_context,
            );
        }
    };

    const t = try std.Thread.spawn(.{}, S.run, .{ io, localhost, tmp_dir });
    defer t.join();

    //

    var client = try server.accept(io);
    defer client.close(io);

    var reader_buf: [1024 * 1024 * 2]u8 = undefined;
    var writer_buf: [1024 * 1024 * 2]u8 = undefined;

    var stream_reader = client.reader(io, &reader_buf);
    var stream_writer = client.writer(io, &writer_buf);

    var file_reader_buf: [1024 * 1024 * 2]u8 = undefined;

    const read_file = try tmp_dir.openFile("test_read", .{});
    defer read_file.close();

    var file_reader = read_file.reader(io, &file_reader_buf);

    var server_context: AliceContext = .{
        .pingpong = .{ .client_counter = 0 },
        .send_context = .{
            .reader = &file_reader.interface,
            .file_size = (try read_file.stat()).size,
        },
    };

    const stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{
        io,
        .alice,
        true,
        .{
            .bob = StreamChannel{
                .reader = &stream_reader.interface,
                .writer = &stream_writer.interface,
                .log = false,
            },
        },
        curr_id,
        &server_context,
    });

    defer stid.join();
}
