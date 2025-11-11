const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("root", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe_infos: []const struct {
        name: []const u8,
        path: []const u8,
    } = &.{
        .{ .name = "counter", .path = "examples/counter.zig" },
        .{ .name = "2pc", .path = "examples/2pc.zig" },
        .{ .name = "pingpong", .path = "examples/pingpong.zig" },
        .{ .name = "sendfile", .path = "examples/sendfile.zig" },
        .{ .name = "pingpong-sendfile", .path = "examples/pingpong_sendfile.zig" },
        .{ .name = "random-pingpong-2pc", .path = "examples/random_pingpong_2pc.zig" },
    };

    inline for (exe_infos) |info| {
        const exe = b.addExecutable(.{
            .name = info.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(info.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "polysession", .module = mod },
                },
            }),
        });

        const run_step = b.step(info.name, "Run the " ++ info.name);

        const install_artifact = b.addInstallArtifact(exe, .{});
        run_step.dependOn(&install_artifact.step);

        //install state graph
        const install_file = addInstallGraphFile(
            b,
            info.name,
            exe.root_module,
            mod,
            target,
            .{ .custom = "graph" },
        );
        run_step.dependOn(&install_file.step);

        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

pub fn addGraphFile(
    b: *std.Build,
    module_name: []const u8,
    module: *std.Build.Module,
    polysession: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) std.Build.LazyPath {
    const options = b.addOptions();

    const writer = options.contents.writer(b.allocator);

    const stdio_writer_setup =
        \\var stdout_buffer: [1024]u8 = undefined;
        \\var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        \\const writer = &stdout_writer.interface;
        \\defer writer.flush() catch @panic("Failed to flush");
    ;

    writer.print(
        \\const std = @import("std");
        \\const ps = @import("polysession");
        \\const Target = @import("{s}");
        \\pub fn main() !void {{
        \\  var gpa_instance = std.heap.GeneralPurposeAllocator(.{{}}){{}};
        \\  const gpa = gpa_instance.allocator();
        \\  var graph = try ps.Graph.initWithFsm(gpa, Target.EnterFsmState);
        \\  defer graph.deinit();
        \\
    ++ stdio_writer_setup ++
        \\
        \\  try graph.{s}(writer);
        \\}}
    , .{ module_name, "generateDot" }) catch @panic("OOM");

    const opt_mod = b.createModule(.{
        .root_source_file = options.getOutput(),
        .target = target,
        .imports = &.{
            .{ .name = "polysession", .module = polysession },
            .{ .name = b.allocator.dupe(u8, module_name) catch @panic("OOM"), .module = module },
        },
    });

    const gen_exe_name = std.mem.concat(b.allocator, u8, &.{ "_generate_graph_for_", module_name }) catch @panic("OOM");
    const opt_exe = b.addExecutable(.{
        .name = gen_exe_name,
        .root_module = opt_mod,
    });
    const run = b.addRunArtifact(opt_exe);
    return run.captureStdOut();
}

pub fn addInstallGraphFile(
    b: *std.Build,
    module_name: []const u8,
    module: *std.Build.Module,
    polysession: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    install_dir: std.Build.InstallDir,
) *std.Build.Step.InstallFile {
    const dot_file = addGraphFile(b, module_name, module, polysession, target);

    const output_name = std.mem.concat(b.allocator, u8, &.{ module_name, ".dot" }) catch @panic("OOM");
    return b.addInstallFileWithDir(dot_file, install_dir, output_name);
}
