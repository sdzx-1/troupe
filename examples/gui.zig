const std = @import("std");
const channel = @import("channel.zig");
const rl = @import("raylib");
const rg = @import("raygui");

pub fn start(Role: type, gpa: std.mem.Allocator, log_array: *channel.LogArray) !void {

    // Initialization
    //--------------------------------------------------------------------------------------
    const screenWidth = 800;
    const screenHeight = 450;

    rl.initWindow(screenWidth, screenHeight, "animation");
    defer rl.closeWindow(); // Close window and OpenGL context
    const font = try rl.loadFontEx("data/FiraMono-Regular.ttf", 32, null);

    rl.setTargetFPS(60); // Set our game to run at 60 frames-per-second
    //--------------------------------------------------------------------------------------

    const origin_v: rl.Vector2 = .{ .x = 400, .y = 225 };
    const origin_r: f32 = 200;
    var ms_per_frame_slider: f32 = 4;
    var ms_per_frame: f32 = std.math.pow(f32, std.math.e, ms_per_frame_slider - 5);

    const base_timestamp = log_array.log_array.items[0].send_timestamp;
    const role_num = @typeInfo(Role).@"enum".fields.len;
    const role_pos: [role_num]rl.Vector2 = blk: {
        var tmp: [role_num]rl.Vector2 = undefined;
        for (0..role_num) |i| {
            const val: f32 = @as(f32, std.math.pi * 2) / @as(f32, @floatFromInt(role_num)) * @as(f32, @floatFromInt(i));
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
        if (rl.isKeyPressed(rl.KeyboardKey.space)) {
            start_idx = 0;
            current_time = 0;
            collect.clearAndFree(gpa);
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

        // std.debug.print("collect: {any}\n", .{collect.items});

        // Draw
        //----------------------------------------------------------------------------------
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.white);

        rl.drawCircleLinesV(origin_v, origin_r, rl.Color.black);

        inline for (role_pos, 0..) |vec, i| {
            rl.drawCircleV(vec, 10, rl.Color.blue);
            const str = std.fmt.comptimePrint("{t}", .{@as(Role, @enumFromInt(i))});
            rl.drawTextEx(font, str, vec, 20, 0, rl.Color.black);
        }

        for (collect.items) |log| {
            const st: f32 = @floatFromInt(log.send_timestamp - base_timestamp);
            const rt: f32 = @floatFromInt(log.recv_timestamp - base_timestamp);
            const rval = (current_time - st) / (rt - st);

            const from_vec = role_pos[@as(usize, @intCast(log.sender))];
            const to_vec = role_pos[@as(usize, @intCast(log.receiver))];
            const msg_vec = rl.Vector2.lerp(from_vec, to_vec, rval);
            rl.drawLineV(from_vec, to_vec, .black);
            rl.drawCircleV(msg_vec, 7, rl.Color.red);
            const str = switch (log.msg) {
                .notify => try std.fmt.allocPrintSentinel(gpa, "notify", .{}, 0),
                .msg_tag => |s| try std.fmt.allocPrintSentinel(gpa, "{s}", .{s}, 0),
            };
            defer gpa.free(str);
            rl.drawTextEx(font, str, msg_vec, 20, 0, rl.Color.black);
        }
        if (rg.slider(.{ .x = 30, .y = 0, .width = 200, .height = 20 }, "0", "5", &ms_per_frame_slider, 0, 6.6) == 1) {
            ms_per_frame =
                if (ms_per_frame_slider == 0) 0 else std.math.pow(f32, std.math.e, ms_per_frame_slider - 5);
        }
        if (rg.button(.{ .x = 30, .y = 30, .width = 50, .height = 20 }, "reset")) {
            start_idx = 0;
            current_time = 0;
            collect.clearAndFree(gpa);
        }
        const str = try std.fmt.allocPrintSentinel(gpa, "Now: {d:.0}", .{current_time}, 0);
        defer gpa.free(str);
        _ = rg.label(.{ .x = 100, .y = 30, .width = 150, .height = 20 }, str);

        const str1 = try std.fmt.allocPrintSentinel(
            gpa,
            "Total: {d}",
            .{log_array.log_array.items[log_array.log_array.items.len - 1].send_timestamp - base_timestamp},
            0,
        );
        defer gpa.free(str1);
        _ = rg.label(.{ .x = 180, .y = 30, .width = 150, .height = 20 }, str1);
    }
}
