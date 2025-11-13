const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;
const pingpong = @import("./protocols/pingpong.zig");
const mk2pc = @import("./protocols/two_phase_commit.zig").mk2pc;
const channel = @import("channel.zig");
const rl = @import("raylib");

const MvarChannelMap = channel.MvarChannelMap(AllRole);

pub fn main() !void {
    var gpa_instance = std.heap.DebugAllocator(.{}).init;
    const gpa = gpa_instance.allocator();

    var counter: std.atomic.Value(usize) = .init(0);

    var log_array: channel.LogArray = .{
        .mutex = .{},
        .log_array = .empty,
        .allocator = gpa,
    };

    var mvar_channel_map: MvarChannelMap = .init(&log_array, &counter);
    try mvar_channel_map.generate_all_MvarChannel(gpa, 10);

    const alice = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var alice_context: AliceContext = .{};
            const fill_ptr: []u8 = @ptrCast(&alice_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(.alice, false, mcm, curr_id, &alice_context);
        }
    };

    const bob = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var bob_context: BobContext = .{};
            const fill_ptr: []u8 = @ptrCast(&bob_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(.bob, false, mcm, curr_id, &bob_context);
        }
    };

    const charlie = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var charlie_context: CharlieContext = .{};
            const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(.charlie, false, mcm, curr_id, &charlie_context);
        }
    };

    const selector = struct {
        fn run(mcm: *MvarChannelMap) !void {
            var charlie_context: SelectorContext = .{};
            const fill_ptr: []u8 = @ptrCast(&charlie_context.xoshiro256.s);
            std.crypto.random.bytes(fill_ptr);

            try Runner.runProtocol(.selector, false, mcm, curr_id, &charlie_context);
        }
    };

    const alice_thread = try std.Thread.spawn(.{}, alice.run, .{&mvar_channel_map});
    const bob_thread = try std.Thread.spawn(.{}, bob.run, .{&mvar_channel_map});
    const charlie_thread = try std.Thread.spawn(.{}, charlie.run, .{&mvar_channel_map});
    const selector_thread = try std.Thread.spawn(.{}, selector.run, .{&mvar_channel_map});

    // Initialization
    //--------------------------------------------------------------------------------------
    const screenWidth = 800;
    const screenHeight = 450;

    rl.initWindow(screenWidth, screenHeight, "random-pingpong-2pc");
    defer rl.closeWindow(); // Close window and OpenGL context
    const font = try rl.loadFontEx("data/FiraMono-Regular.ttf", 32, null);

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    const origin_v: rl.Vector2 = .{ .x = 400, .y = 225 };
    const origin_r: f32 = 200;
    var ms_per_frame: f32 = 0.3;
    const base_timestamp = log_array.log_array.items[0].send_timestamp;
    const role_num = @typeInfo(AllRole).@"enum".fields.len;
    const role_pos: [role_num]rl.Vector2 = blk: {
        var tmp: [role_num]rl.Vector2 = undefined;
        for (0..role_num) |i| {
            const val: f32 = @as(f32, std.math.pi) / 2.0 * @as(f32, @floatFromInt(i));
            const x: f32 = @sin(val) * origin_r;
            const y: f32 = @cos(val) * origin_r;
            tmp[i] = origin_v.add(.{ .x = x, .y = y });
        }
        break :blk tmp;
    };
    //
    var current_time: f32 = 0;
    var start_idx: usize = 0;
    var collect: std.ArrayListUnmanaged(channel.LogArray.Log) = .empty;
    var remove_buff: [10]usize = undefined;

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        if (rl.isKeyDown(rl.KeyboardKey.j)) {
            ms_per_frame *= 0.98;
        }

        if (rl.isKeyDown(rl.KeyboardKey.k)) {
            ms_per_frame *= 1.02;
        }
        //update current_time
        current_time += ms_per_frame;
        //check and delect log form collect
        var remove_arr: std.ArrayListUnmanaged(usize) = .initBuffer(&remove_buff);
        for (collect.items, 0..) |log, i| {
            if (!log.curr_time_in_during(base_timestamp, current_time)) {
                remove_arr.appendAssumeCapacity(i);
            }
        }
        collect.orderedRemoveMany(remove_arr.items);

        //add log to collect
        while (start_idx < log_array.log_array.items.len and
            log_array.log_array.items[start_idx].curr_time_in_during(base_timestamp, current_time)) : (start_idx += 1)
        {
            try collect.append(gpa, log_array.log_array.items[start_idx]);
        }

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.white);

        rl.drawCircleLinesV(origin_v, origin_r, rl.Color.black);

        inline for (role_pos, 0..) |vec, i| {
            rl.drawCircleV(vec, 10, rl.Color.blue);
            const str = std.fmt.comptimePrint("{t}", .{@as(AllRole, @enumFromInt(i))});
            rl.drawTextEx(font, str, vec, 20, 0, rl.Color.black);
        }

        for (collect.items) |log| {
            const st: f32 = @floatFromInt(log.send_timestamp - base_timestamp);
            const rt: f32 = @floatFromInt(log.recv_timestamp - base_timestamp);
            const rval = (current_time - st) / (rt - st);

            const from_vec = role_pos[@as(usize, @intCast(log.sender))];
            const to_vec = role_pos[@as(usize, @intCast(log.receiver))];
            const msg_vec = rl.Vector2.lerp(from_vec, to_vec, rval);
            rl.drawCircleV(msg_vec, 10, rl.Color.red);
            const str = switch (log.msg) {
                .notify => try std.fmt.allocPrintSentinel(gpa, "notify", .{}, 0),
                .msg_tag => |s| try std.fmt.allocPrintSentinel(gpa, "{s}", .{s}, 0),
            };
            defer gpa.free(str);
            rl.drawTextEx(font, str, msg_vec, 20, 0, rl.Color.black);
        }
    }

    //

    alice_thread.join();
    bob_thread.join();
    charlie_thread.join();
    selector_thread.join();
}

//
const AllRole = enum { selector, alice, bob, charlie };

const AliceContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const BobContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const CharlieContext = struct {
    counter: u32 = 0,
    retry_times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
    pingpong_client: pingpong.ClientContext = .{ .client_counter = 0 },
    pingpong_server: pingpong.ServerContext = .{ .server_counter = 0 },
};

const SelectorContext = struct {
    times: u32 = 0,
    xoshiro256: std.Random.Xoshiro256 = undefined,
};

const Context = struct {
    alice: type = AliceContext,
    bob: type = BobContext,
    charlie: type = CharlieContext,
    selector: type = SelectorContext,
};

pub const EnterFsmState = Start;

pub const Runner = troupe.Runner(EnterFsmState);
pub const curr_id = Runner.idFromState(EnterFsmState);

fn PingPong(client: AllRole, server: AllRole, Next: type) type {
    return pingpong.MkPingPong(
        AllRole,
        client,
        server,
        Context{},
        .pingpong_client,
        .pingpong_server,
        Next,
    );
}

fn CAB(Next: type) type {
    return mk2pc(AllRole, .charlie, .alice, .bob, Context{}, Next, troupe.Exit);
}
fn ABC(Next: type) type {
    return mk2pc(AllRole, .alice, .bob, .charlie, Context{}, Next, troupe.Exit);
}
fn BAC(Next: type) type {
    return mk2pc(AllRole, .bob, .alice, .charlie, Context{}, Next, troupe.Exit);
}

pub const Start = union(enum) {
    charlie_as_coordinator: Data(void, PingPong(.alice, .bob, PingPong(.bob, .charlie, PingPong(
        .charlie,
        .alice,
        CAB(@This()).Begin,
    ).Ping).Ping).Ping),
    alice_as_coordinator: Data(void, PingPong(.charlie, .bob, ABC(@This()).Begin).Ping),
    bob_as_coordinator: Data(void, PingPong(.alice, .charlie, BAC(@This()).Begin).Ping),
    exit: Data(void, troupe.Exit),

    pub const info: troupe.ProtocolInfo(
        "random_pingpong_and_2pc",
        AllRole,
        Context{},
        &.{ .selector, .charlie, .alice, .bob },
        &.{},
    ) = .{
        .name = "Start",
        .sender = .selector,
        .receiver = &.{ .charlie, .alice, .bob },
    };

    pub fn process(ctx: *SelectorContext) !@This() {
        ctx.times += 1;
        std.debug.print("times: {d}\n", .{ctx.times});
        if (ctx.times > 300) {
            return .{ .exit = .{ .data = {} } };
        }

        const random: std.Random = ctx.xoshiro256.random();
        const res = random.intRangeAtMost(u8, 0, 2);
        switch (res) {
            0 => return .{ .charlie_as_coordinator = .{ .data = {} } },
            1 => return .{ .alice_as_coordinator = .{ .data = {} } },
            2 => return .{ .bob_as_coordinator = .{ .data = {} } },
            else => unreachable,
        }
    }
};
