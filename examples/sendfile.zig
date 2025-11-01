const std = @import("std");
const ps = @import("polysession");
const Data = ps.Data;
const sendfile = @import("./protocols/sendfile.zig");

const Role = enum { alice, bob };

const AliceContext = struct {
    sendfile: sendfile.SendContext,
};

const BobContext = struct {
    sendfile: sendfile.RecvContext,
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
};

pub const EnterFsmState = sendfile.MkSendFile(
    Role,
    .alice,
    .bob,
    Context{},
    1024,
    .sendfile,
    .sendfile,
    ps.Exit,
    ps.Exit,
).Start;

pub const Runner = ps.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

const MvarChannelMap = @import("channel.zig").MvarChannelMap(Role);

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
        const str: [36]u8 = @splat(65);
        for (0..20) |_| {
            try read_file.writeAll(&str);
        }
    }

    var mvar_channel_map: MvarChannelMap = try .init();
    try mvar_channel_map.generate_all_MvarChannel(gpa, 2 * 1024 * 1024);

    const alice = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap, tmp_dir_: std.fs.Dir) !void {
            var file_reader_buf: [1024 * 2]u8 = undefined;

            const read_file = try tmp_dir_.openFile("test_read", .{});
            defer read_file.close();

            var file_reader = read_file.reader(io_, &file_reader_buf);

            var alice_context: AliceContext = .{
                .sendfile = .{
                    .reader = &file_reader.interface,
                    .file_size = (try read_file.stat()).size,
                },
            };
            try Runner.runProtocol(io_, .alice, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn run(io_: std.Io, mcm: *MvarChannelMap, tmp_dir_: std.fs.Dir) !void {
            const write_file = try tmp_dir_.createFile("test_write", .{});
            defer write_file.close();

            var file_writer_buf: [1024 * 2]u8 = undefined;

            var file_writer = write_file.writer(&file_writer_buf);

            var bob_context: BobContext = .{ .sendfile = .{ .writer = &file_writer.interface } };
            try Runner.runProtocol(io_, .bob, false, mcm, curr_id, &bob_context);
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.run, .{ io, &mvar_channel_map, tmp_dir });
    const bob_thread = try std.Thread.spawn(.{}, bob.run, .{ io, &mvar_channel_map, tmp_dir });

    alice_thread.join();
    bob_thread.join();
}
