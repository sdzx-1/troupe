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
        .{ .name = "random-pingpong-2pc", .path = "examples/random_pingpong_2pc.zig" },
    };

    const gen_graph = b.step("gen-graphs", "Generate SVG graph for the examples");

    inline for (exe_infos) |info| {
        const exe = b.addExecutable(.{
            .name = info.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(info.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "polyrole", .module = mod }},
            }),
        });

        const run_step = b.step(info.name, "Run the " ++ info.name);

        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        addGraphToStep(
            b,
            gen_graph,
            exe.root_module,
            target,
            mod,
            .{ .custom = "../data" },
            info.name,
        );
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

fn addGraphToStep(
    b: *std.Build,
    step: *std.Build.Step,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    polyrole: *std.Build.Module,
    install_dir: std.Build.InstallDir,
    dst_rel_path: []const u8,
) void {
    const graph_file = addGraphFile(b, "graph", mod, polyrole, target);

    const dot_cmd = b.addSystemCommand(&.{"dot"});

    dot_cmd.addArg("-Tsvg");

    dot_cmd.addFileArg(graph_file);

    const graph_svg = dot_cmd.captureStdOut(.{});

    const install_graph_svg = b.addInstallFileWithDir(graph_svg, install_dir, b.fmt("{s}.svg", .{dst_rel_path}));

    step.dependOn(&install_graph_svg.step);
}

pub fn addGraphFile(
    b: *std.Build,
    module_name: []const u8,
    module: *std.Build.Module,
    polyrole: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) std.Build.LazyPath {
    var allocating: std.Io.Writer.Allocating = .init(b.graph.arena);
    const writer = &allocating.writer;

    writer.print(
        \\const std = @import("std");
        \\const polyrole = @import("polyrole");
        \\const Target = @import("{s}");
        \\pub fn main(init: std.process.Init) !void {{
        \\  const io = init.io;
        \\  var gpa_instance = std.heap.DebugAllocator(.{{}}){{}};
        \\  const gpa = gpa_instance.allocator();
        \\  var graph = try polyrole.Graph.initWithFsm(gpa, Target.EnterFsmState);
        \\  defer graph.deinit();
        \\  var stdout_buffer: [1024]u8 = undefined;
        \\  var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
        \\  const writer = &stdout_writer.interface;
        \\  defer writer.flush() catch @panic("Failed to flush");
        \\
        \\  try graph.{s}(null, writer);
        \\}}
    , .{ module_name, "generateDot" }) catch @panic("OOM");

    const options = b.addOptions();
    options.contents = writer.toArrayList();

    const opt_mod = b.createModule(.{
        .root_source_file = options.getOutput(),
        .target = target,
        .imports = &.{
            .{ .name = "polyrole", .module = polyrole },
            .{ .name = b.allocator.dupe(u8, module_name) catch @panic("OOM"), .module = module },
        },
    });

    const gen_exe_name = std.mem.concat(b.allocator, u8, &.{ "_generate_graph_for_", module_name }) catch @panic("OOM");
    const opt_exe = b.addExecutable(.{
        .name = gen_exe_name,
        .root_module = opt_mod,
    });
    const run = b.addRunArtifact(opt_exe);
    return run.captureStdOut(.{});
}

pub fn addInstallGraphFile(
    b: *std.Build,
    module_name: []const u8,
    module: *std.Build.Module,
    polyrole: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    install_dir: std.Build.InstallDir,
) *std.Build.Step.InstallFile {
    const dot_file = addGraphFile(b, module_name, module, polyrole, target);

    const output_name = std.mem.concat(b.allocator, u8, &.{ module_name, ".dot" }) catch @panic("OOM");
    return b.addInstallFileWithDir(dot_file, install_dir, output_name);
}
