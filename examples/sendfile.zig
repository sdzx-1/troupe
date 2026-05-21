const std = @import("std");
const Io = std.Io;
const polyrole = @import("polyrole");
const net = std.Io.net;
const channel = @import("channel.zig");
const StreamChannel = channel.StreamChannel;
const sendfile = @import("./protocols/sendfile.zig");

pub const AliceContext = struct {
    send_context: sendfile.SendContext,
};

pub const BobContext = struct {
    recv_context: sendfile.RecvContext,
};

pub const Role = enum { alice, bob };

pub const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
};

fn SendFile(Successed: type, Failed: type) type {
    return sendfile.MkSendFile(Role, .alice, .bob, Context{}, 20 * 1024 * 1024, .send_context, .recv_context, Successed, Failed);
}

pub const EnterFsmState = SendFile(polyrole.Exit, polyrole.Exit).Start;

pub const Runner = polyrole.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const cwd = std.Io.Dir.cwd();

    {
        const read_file = try cwd.createFile(io, "/tmp/test_read", .{});
        defer read_file.close(io);
        var xoros: std.Random.Xoroshiro128 = undefined;
        io.random(@ptrCast(&xoros.s));
        var str: [1024 * 1024]u8 = @splat(65);
        var buf: [1024]u8 = undefined;
        var read_file_writer = read_file.writer(io, &buf);
        const writer = &read_file_writer.interface;
        for (0..100) |_| {
            xoros.random().bytes(str[0..20]);
            try writer.writeAll(&str);
        }
    }

    //Server
    const localhost = try net.IpAddress.parse("127.0.0.1", 12345);

    var server = try localhost.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    //

    const S = struct {
        fn run(io_: std.Io, server_address: *const net.IpAddress, dir: std.Io.Dir) !void {
            const socket = try server_address.connect(io_, .{ .mode = .stream });
            defer socket.close(io_);

            var reader_buf: [1024 * 5]u8 = undefined;
            var writer_buf: [1024 * 2]u8 = undefined;

            var stream_reader = socket.reader(io_, &reader_buf);
            var stream_writer = socket.writer(io_, &writer_buf);

            const write_file = try dir.createFile(io_, "/tmp/test_write", .{});
            defer write_file.close(io_);

            var file_writer_buf: [1024 * 2]u8 = undefined;

            var file_writer = write_file.writer(io_, &file_writer_buf);

            var client_context: BobContext = .{
                .recv_context = .{
                    .writer = &file_writer.interface,
                },
            };

            try Runner.runProtocol(
                .bob,
                null,
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

    const t = try std.Thread.spawn(.{}, S.run, .{ io, &localhost, cwd });
    defer t.join();

    //

    var stream = try server.accept(io);
    defer stream.close(io);

    var reader_buf: [1024 * 2]u8 = undefined;
    var writer_buf: [1024 * 2]u8 = undefined;

    var stream_reader = stream.reader(io, &reader_buf);
    var stream_writer = stream.writer(io, &writer_buf);

    var file_reader_buf: [1024 * 2]u8 = undefined;

    const read_file = try cwd.openFile(io, "/tmp/test_read", .{});
    defer read_file.close(io);

    var file_reader = read_file.reader(io, &file_reader_buf);

    var server_context: AliceContext = .{
        .send_context = .{
            .reader = &file_reader.interface,
            .file_size = (try read_file.stat(io)).size,
        },
    };

    var stid = try std.Thread.spawn(.{}, Runner.runProtocol, .{
        .alice,
        null,
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
