const std = @import("std");
const troupe = @import("troupe");
const Data = troupe.Data;

// ── Context type definitions ──────────────────────────────────────

pub const ClientContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    stdin_reader: *std.Io.Reader,

    line_buf: [4096]u8 = undefined,
    chunk_buf: [4096]u8 = undefined,

    /// File content pre-loaded for upload (allocated with `allocator`)
    upload_data: []const u8 = "",
    upload_offset: usize = 0,
};

pub const ServerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,

    /// The path that the current command operates on
    pending_path: []const u8 = "",

    read_buf: [4096]u8 = undefined,
    /// Internal buffer for the streaming reader (separate from read_buf to avoid aliasing)
    read_stream_buf: [4096]u8 = undefined,
    /// Persistent streaming reader for ReadFile; maintains OS offset + internal buffering across process calls
    reader: ?std.Io.File.Reader = null,

    write_file: ?std.Io.File = null,
    write_writer_buf: [4096]u8 = undefined,
    write_error: bool = false,

    /// Tracks heap-allocated memory from the last response, freed on next command
    pending_free: []const u8 = "",
};

/// Remote File Manager protocol factory.
///
/// == State Graph ==
///
/// Command (client→server)  — user picks an operation
///   ├── list {path}   → ListDir  (server→client: listing text)
///   ├── read {path}   → ReadFile (server→client: chunks *N → done)
///   ├── write{path,sz}→ WriteFile(client→server: chunks *N → done → WriteDone)
///   ├── delete{path}  → Delete   (server→client: result)
///   ├── stat {path}   → Stat     (server→client: metadata)
///   ├── mkdir{path}   → Mkdir    (server→client: result)
///   └── exit          → {Success}
///
/// ReadFile uses self-looping (chunk → @This()) to demonstrate
/// Troupe's streaming pattern via the type system.
pub fn MkRemoteFM(
    comptime Role: type,
    comptime client_role: Role,
    comptime server_role: Role,
    comptime context: anytype,
    comptime Success: type,
    comptime Failure: type,
) type {
    return struct {
        // ── Payload types ──────────────────────────────────────────

        pub const ListReq = struct { path: []const u8 };
        pub const ReadReq = struct { path: []const u8 };
        pub const WriteReq = struct { path: []const u8, size: u64 };
        pub const DeleteReq = struct { path: []const u8 };
        pub const StatReq = struct { path: []const u8 };
        pub const MkdirReq = struct { path: []const u8 };
        pub const OpResult = struct { ok: bool, error_msg: []const u8 };
        pub const FileInfo = struct {
            name: []const u8,
            size: u64,
            is_dir: bool,
            modified: i64,
        };

        // ── Protocol info helper ──────────────────────────────────

        fn pinfo(
            comptime StateName: []const u8,
            comptime sender_: Role,
            comptime receiver_: []const Role,
        ) troupe.ProtocolInfo(
            "remote_fm",
            Role,
            context,
            &.{ client_role, server_role },
            &.{ Success, Failure },
        ) {
            return .{ .name = StateName, .sender = sender_, .receiver = receiver_ };
        }

        // ── Command selection (client → server) ───────────────────

        pub const Command = union(enum) {
            list:   Data(ListReq,   ListDir),
            read:   Data(ReadReq,   ReadFile),
            write:  Data(WriteReq,  WriteFile),
            delete: Data(DeleteReq, Delete),
            stat:   Data(StatReq,   Stat),
            mkdir:  Data(MkdirReq,  Mkdir),
            exit:   Data(void,      Success),

            pub const info = pinfo("Command", client_role, &.{server_role});

            pub fn process(cctx: *info.Ctx(client_role)) !@This() {
                const c = &cctx.*;
                while (true) {
                    try c.stdout_writer.print("fm> ", .{});
                    try c.stdout_writer.flush();

                    const line = (c.stdin_reader.takeDelimiter('\n') catch |err| {
                        try c.stdout_writer.print("stdin error ({}), exiting\n", .{err});
                        try c.stdout_writer.flush();
                        return .{ .exit = .{ .data = {} } };
                    }) orelse return .{ .exit = .{ .data = {} } };

                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    if (trimmed.len == 0) continue;

                    const space = std.mem.indexOfScalar(u8, trimmed, ' ');
                    const cmd = if (space) |s| trimmed[0..s] else trimmed;
                    const arg = if (space) |s| std.mem.trim(u8, trimmed[s + 1 ..], " \t") else "";

                    if (std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "quit")) {
                        return .{ .exit = .{ .data = {} } };
                    } else if (std.mem.eql(u8, cmd, "list") or std.mem.eql(u8, cmd, "ls")) {
                        return .{ .list = .{ .data = .{ .path = if (arg.len > 0) arg else "." } } };
                    } else if (std.mem.eql(u8, cmd, "read") or std.mem.eql(u8, cmd, "cat")) {
                        if (arg.len == 0) { try c.stdout_writer.print("Usage: read <path>\n", .{}); continue; }
                        return .{ .read = .{ .data = .{ .path = arg } } };
                    } else if (std.mem.eql(u8, cmd, "write") or std.mem.eql(u8, cmd, "put")) {
                        const parts = splitTwo(arg, ' ');
                        if (parts[0].len == 0 or parts[1].len == 0) {
                            try c.stdout_writer.print("Usage: write <remote-path> <local-path>\n", .{});
                            continue;
                        }
                        const cwd = std.Io.Dir.cwd();
                        const local_file = cwd.openFile(c.io, parts[1], .{}) catch |err| {
                            try c.stdout_writer.print("Cannot open local file: {}\n", .{err});
                            continue;
                        };
                        defer local_file.close(c.io);
                        _ = local_file.stat(c.io) catch |err| {
                            try c.stdout_writer.print("Cannot stat local file: {}\n", .{err});
                            continue;
                        };
                        var read_buf: [8192]u8 = undefined;
                        var file_reader = local_file.reader(c.io, &read_buf);
                        const content = try file_reader.interface.allocRemaining(c.allocator, .unlimited);
                        c.upload_data = content;
                        c.upload_offset = 0;
                        return .{ .write = .{ .data = .{ .path = parts[0], .size = @intCast(content.len) } } };
                    } else if (std.mem.eql(u8, cmd, "delete") or std.mem.eql(u8, cmd, "rm")) {
                        if (arg.len == 0) { try c.stdout_writer.print("Usage: delete <path>\n", .{}); continue; }
                        return .{ .delete = .{ .data = .{ .path = arg } } };
                    } else if (std.mem.eql(u8, cmd, "stat")) {
                        if (arg.len == 0) { try c.stdout_writer.print("Usage: stat <path>\n", .{}); continue; }
                        return .{ .stat = .{ .data = .{ .path = arg } } };
                    } else if (std.mem.eql(u8, cmd, "mkdir")) {
                        if (arg.len == 0) { try c.stdout_writer.print("Usage: mkdir <path>\n", .{}); continue; }
                        return .{ .mkdir = .{ .data = .{ .path = arg } } };
                    } else if (std.mem.eql(u8, cmd, "help")) {
                        try c.stdout_writer.print(
                            \\Commands:
                            \\  list|ls [<path>]           — List directory
                            \\  read|cat <path>            — Display file
                            \\  write|put <remote> <local> — Upload file
                            \\  delete|rm <path>           — Delete file
                            \\  stat <path>                — File info
                            \\  mkdir <path>               — Create directory
                            \\  exit|quit                  — Disconnect
                            \\  help                       — This message
                            \\
                        , .{});
                        continue;
                    } else {
                        try c.stdout_writer.print("Unknown: {s}. Try 'help'.\n", .{cmd});
                        continue;
                    }
                }
            }

            pub fn preprocess_0(sctx: *info.Ctx(server_role), msg: @This()) !void {
                const s = &sctx.*;

                // Free any pending allocation before processing a new command
                if (s.pending_free.len > 0) {
                    s.allocator.free(s.pending_free);
                    s.pending_free = "";
                }

                switch (msg) {
                    .list   => |v| s.pending_path = v.data.path,
                    .read   => |v| {
                        // Clean up any lingering reader from a previous ReadFile
                        if (s.reader) |*r| {
                            r.file.close(r.io);
                        }
                        s.reader = null;
                        s.pending_path = v.data.path;
                    },
                    .write  => |v| {
                        s.pending_path = v.data.path;
                        s.write_error = false;
                        s.write_file = null;
                    },
                    .delete => |v| s.pending_path = v.data.path,
                    .stat   => |v| s.pending_path = v.data.path,
                    .mkdir  => |v| s.pending_path = v.data.path,
                    .exit   => {},
                }
            }
        };

        // ── ListDir (server → client) ──────────────────────────────

        pub const ListDir = union(enum) {
            resp: Data([]const u8, Command),

            pub const info = pinfo("ListDir", server_role, &.{client_role});

            pub fn process(sctx: *info.Ctx(server_role)) !@This() {
                const s = &sctx.*;
                const gpa = s.allocator;
                const io_ = s.io;

                // Free any previous allocation before allocating new one
                if (s.pending_free.len > 0) {
                    gpa.free(s.pending_free);
                    s.pending_free = "";
                }

                var listing: std.ArrayList(u8) = .empty;
                defer listing.deinit(gpa);

                const dir = s.root_dir.openDir(io_, s.pending_path, .{ .iterate = true }) catch |err| {
                    try listing.appendSlice(gpa, try std.fmt.allocPrint(gpa, "Error: {}\n", .{err}));
                    const owned = try listing.toOwnedSlice(gpa);
                    s.pending_free = owned;
                    return .{ .resp = .{ .data = owned } };
                };
                defer dir.close(io_);

                var iter = dir.iterate();
                while (try iter.next(io_)) |entry| {
                    const kind: u8 = if (entry.kind == .directory) 'd' else '-';
                    const line = try std.fmt.allocPrint(gpa, "{c} {s}\n", .{ kind, entry.name });
                    try listing.appendSlice(gpa, line);
                    gpa.free(line);
                }
                const owned = try listing.toOwnedSlice(gpa);
                s.pending_free = owned;
                return .{ .resp = .{ .data = owned } };
            }

            pub fn preprocess_0(cctx: *info.Ctx(client_role), msg: @This()) !void {
                const c = &cctx.*;
                switch (msg) {
                    .resp => |v| {
                        try c.stdout_writer.print("{s}", .{v.data});
                        try c.stdout_writer.flush();
                        // v.data is a borrow from the codec decoder buffer, not owned by us
                    },
                }
            }
        };

        // ── ReadFile (server → client, self-looping) ───────────────

        pub const ReadFile = union(enum) {
            chunk: Data([]const u8, @This()),
            done:  Data(void,       Command),

            pub const info = pinfo("ReadFile", server_role, &.{client_role});

            pub fn process(sctx: *info.Ctx(server_role)) !@This() {
                const s = &sctx.*;
                const io_ = s.io;

                // Obtain or create the persistent streaming reader.
                // File.Reader tracks its own logical position and buffered data,
                // so we keep it alive across process calls to avoid losing bytes.
                var reader = s.reader orelse blk: {
                    const f = s.root_dir.openFile(io_, s.pending_path, .{}) catch
                        return .{ .done = .{ .data = {} } };
                    break :blk f.readerStreaming(io_, &s.read_stream_buf);
                };

                // Use read_buf as the output buffer — distinct from read_stream_buf
                // which the File.Reader owns. This avoids the aliasing bug where
                // writableVector appends r.buffer as an extra iovec, corrupting data.
                const n = reader.interface.readSliceShort(&s.read_buf) catch {
                    reader.file.close(io_);
                    s.reader = null;
                    return .{ .done = .{ .data = {} } };
                };

                if (n == 0) {
                    reader.file.close(io_);
                    s.reader = null;
                    return .{ .done = .{ .data = {} } };
                }

                s.reader = reader;
                return .{ .chunk = .{ .data = s.read_buf[0..n] } };
            }

            pub fn preprocess_0(cctx: *info.Ctx(client_role), msg: @This()) !void {
                const c = &cctx.*;
                switch (msg) {
                    .chunk => |v| { try c.stdout_writer.writeAll(v.data); try c.stdout_writer.flush(); },
                    .done  => {},
                }
            }
        };

        // ── WriteFile (client → server, streams from memory) ───────

        pub const WriteFile = union(enum) {
            chunk: Data([]const u8, @This()),
            done:  Data(void,       WriteDone),

            pub const info = pinfo("WriteFile", client_role, &.{server_role});

            pub fn process(cctx: *info.Ctx(client_role)) !@This() {
                const c = &cctx.*;
                const remaining = c.upload_data.len - c.upload_offset;

                if (remaining == 0) {
                    c.allocator.free(c.upload_data);
                    c.upload_data = "";
                    return .{ .done = .{ .data = {} } };
                }

                const n = @min(remaining, c.chunk_buf.len);
                const chunk = c.upload_data[c.upload_offset .. c.upload_offset + n];
                c.upload_offset += n;
                return .{ .chunk = .{ .data = chunk } };
            }

            pub fn preprocess_0(sctx: *info.Ctx(server_role), msg: @This()) !void {
                const s = &sctx.*;
                const io_ = s.io;

                switch (msg) {
                    .chunk => |v| {
                        const file = s.write_file orelse blk: {
                            const f = s.root_dir.createFile(io_, s.pending_path, .{}) catch {
                                s.write_error = true;
                                break :blk null;
                            };
                            break :blk f;
                        };
                        if (file) |f| {
                            var file_writer = f.writer(io_, &s.write_writer_buf);
                            file_writer.interface.writeAll(v.data) catch {
                                s.write_error = true;
                            };
                            s.write_file = file;
                        }
                    },
                    .done => {},
                }
            }
        };

        // ── WriteDone (server → client result) ─────────────────────

        pub const WriteDone = union(enum) {
            result: Data(OpResult, Command),

            pub const info = pinfo("WriteDone", server_role, &.{client_role});

            pub fn process(sctx: *info.Ctx(server_role)) !@This() {
                const s = &sctx.*;
                const io_ = s.io;

                if (s.write_file) |f| {
                    f.sync(io_) catch {};
                    f.close(io_);
                    s.write_file = null;
                }

                if (s.write_error) {
                    s.root_dir.deleteFile(io_, s.pending_path) catch {};
                    return .{ .result = .{ .data = .{ .ok = false, .error_msg = "write failed" } } };
                }
                return .{ .result = .{ .data = .{ .ok = true, .error_msg = "" } } };
            }

            pub fn preprocess_0(cctx: *info.Ctx(client_role), msg: @This()) !void {
                const c = &cctx.*;
                switch (msg) {
                    .result => |v| {
                        if (v.data.ok) {
                            try c.stdout_writer.print("Write completed.\n", .{});
                        } else {
                            try c.stdout_writer.print("Write failed: {s}\n", .{v.data.error_msg});
                        }
                        try c.stdout_writer.flush();
                    },
                }
            }
        };

        // ── Delete (server → client) ───────────────────────────────

        pub const Delete = union(enum) {
            result: Data(OpResult, Command),

            pub const info = pinfo("Delete", server_role, &.{client_role});

            pub fn process(sctx: *info.Ctx(server_role)) !@This() {
                const s = &sctx.*;
                const io_ = s.io;

                s.root_dir.deleteFile(io_, s.pending_path) catch |err|
                    return .{ .result = .{ .data = .{ .ok = false, .error_msg = @errorName(err) } } };
                return .{ .result = .{ .data = .{ .ok = true, .error_msg = "" } } };
            }

            pub fn preprocess_0(cctx: *info.Ctx(client_role), msg: @This()) !void {
                const c = &cctx.*;
                switch (msg) {
                    .result => |v| {
                        if (v.data.ok) {
                            try c.stdout_writer.print("Deleted.\n", .{});
                        } else {
                            try c.stdout_writer.print("Delete failed: {s}\n", .{v.data.error_msg});
                        }
                        try c.stdout_writer.flush();
                    },
                }
            }
        };

        // ── Stat (server → client) ─────────────────────────────────

        pub const Stat = union(enum) {
            resp: Data(FileInfo, Command),

            pub const info = pinfo("Stat", server_role, &.{client_role});

            pub fn process(sctx: *info.Ctx(server_role)) !@This() {
                const s = &sctx.*;
                const io_ = s.io;

                const st = s.root_dir.statFile(io_, s.pending_path, .{}) catch
                    return .{ .resp = .{ .data = .{ .name = s.pending_path, .size = 0, .is_dir = false, .modified = 0 } } };

                const is_dir = (st.kind == .directory);

                return .{ .resp = .{ .data = .{ .name = s.pending_path, .size = st.size, .is_dir = is_dir, .modified = @intCast(st.mtime.nanoseconds) } } };
            }

            pub fn preprocess_0(cctx: *info.Ctx(client_role), msg: @This()) !void {
                const c = &cctx.*;
                switch (msg) {
                    .resp => |v| {
                        const kind = if (v.data.is_dir) "directory" else "file";
                        try c.stdout_writer.print("Path: {s}\nSize: {d}\nType: {s}\nModified: {d}\n",
                            .{ v.data.name, v.data.size, kind, v.data.modified });
                        try c.stdout_writer.flush();
                    },
                }
            }
        };

        // ── Mkdir (server → client) ────────────────────────────────

        pub const Mkdir = union(enum) {
            result: Data(OpResult, Command),

            pub const info = pinfo("Mkdir", server_role, &.{client_role});

            pub fn process(sctx: *info.Ctx(server_role)) !@This() {
                const s = &sctx.*;
                const io_ = s.io;

                s.root_dir.createDir(io_, s.pending_path, .default_dir) catch |err|
                    return .{ .result = .{ .data = .{ .ok = false, .error_msg = @errorName(err) } } };
                return .{ .result = .{ .data = .{ .ok = true, .error_msg = "" } } };
            }

            pub fn preprocess_0(cctx: *info.Ctx(client_role), msg: @This()) !void {
                const c = &cctx.*;
                switch (msg) {
                    .result => |v| {
                        if (v.data.ok) {
                            try c.stdout_writer.print("Directory created.\n", .{});
                        } else {
                            try c.stdout_writer.print("Mkdir failed: {s}\n", .{v.data.error_msg});
                        }
                        try c.stdout_writer.flush();
                    },
                }
            }
        };

        fn splitTwo(s: []const u8, delim: u8) [2][]const u8 {
            const idx = std.mem.indexOfScalar(u8, s, delim) orelse return .{ s, "" };
            return .{ s[0..idx], std.mem.trim(u8, s[idx + 1 ..], " \t") };
        }
    };
}
