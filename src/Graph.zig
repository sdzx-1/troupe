const std = @import("std");
const troupe = @import("root.zig");

const Mode = troupe.Mode;
const Method = troupe.Method;
const Adler32 = std.hash.Adler32;

arena: std.heap.ArenaAllocator,
name: []const u8,
nodes: std.ArrayListUnmanaged(Node),
edges: std.ArrayListUnmanaged(Edge),

const Graph = @This();

const colors: []const []const u8 = &.{
    "red",       "green",    "blue",
    "brown",     "navy",     "teal",
    "cyan",      "magenta",  "darkred",
    "darkgreen", "darkblue", "orange",
    "purple",
};

pub const Node = struct {
    state_description: []const u8,
    id: u32,
    fsm_description: []const u8,
};

pub const Edge = struct {
    from: u32,
    to: u32,
    label: []const u8,
};

pub fn generateDot(
    self: @This(),
    writer: anytype,
) !void {
    try writer.writeAll(
        \\digraph fsm_state_graph {
        \\
    );

    { //state graph
        try writer.writeAll(
            \\  subgraph cluster_transitions {
            \\    label = "State Transitions";
            \\
        );

        // Create subgraphs for each FSM's nodes
        var cluster_idx: u32 = 0;
        var current_fsm_name: ?[]const u8 = null;

        for (self.nodes.items) |node| {
            // Start new FSM subgraph if needed
            if (current_fsm_name == null or !std.mem.eql(u8, current_fsm_name.?, node.fsm_description)) {
                // Close previous subgraph if any
                if (current_fsm_name != null) {
                    try writer.writeAll(
                        \\    }
                        \\
                    );
                    cluster_idx += 1;
                }

                // Start new subgraph
                current_fsm_name = node.fsm_description;
                try writer.print(
                    \\    subgraph cluster_fsm_{d} {{
                    \\      label = "{s}";
                    \\
                , .{ cluster_idx, node.fsm_description });
            }

            // Add node to current FSM subgraph
            try writer.print(
                \\      {d}[shape=rect,  label="[{d}] {s}", color = "{s}"];
                \\
            ,
                .{
                    node.id,
                    node.id,
                    node.state_description,
                    colors[@as(usize, @intCast(node.id)) % colors.len],
                },
            );
        }

        // Close last subgraph
        if (current_fsm_name != null) {
            try writer.writeAll(
                \\    }
                \\
            );
        }

        // Add edges
        for (self.edges.items) |edge| {
            try writer.print(
                \\    {d} -> {d} [label = "{s}", color = "{s}", fontcolor = "{s}"];
                \\
            , .{
                edge.from,
                edge.to,
                edge.label,
                colors[@as(usize, @intCast(edge.from)) % colors.len],
                colors[@as(usize, @intCast(edge.from)) % colors.len],
            });
        }

        try writer.writeAll(
            \\  }
            \\
        );
    }

    try writer.writeAll(
        \\}
        \\
    );

    try writer.flush();
}

pub fn initWithFsm(allocator: std.mem.Allocator, comptime State_: type) !Graph {
    @setEvalBranchQuota(2000000);

    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    var nodes: std.ArrayListUnmanaged(Node) = .empty;
    var edges: std.ArrayListUnmanaged(Edge) = .empty;

    const state_map: troupe.StateMap = comptime .init(State_);

    inline for (state_map.states, state_map.state_machine_names, 0..) |State, fsm_name, state_idx| {
        //node description
        // const description =
        try nodes.append(arena_allocator, .{
            .state_description = if (State == troupe.Exit) "Exit" else try std.fmt.allocPrint(
                arena_allocator,
                "{s} .{t} -> {any}",
                .{ State.info.name, State.info.sender, State.info.receiver },
            ),
            .id = @intCast(state_idx),
            .fsm_description = if (State == troupe.Exit) fsm_name else try std.fmt.allocPrint(
                arena_allocator,
                "{s}: {any}",
                .{ fsm_name, @TypeOf(State.info).internal_roles },
            ),
        });

        switch (@typeInfo(State)) {
            .@"union" => |un| {
                inline for (un.fields) |field| {
                    const NextState = field.type.State;

                    const next_state_idx: u32 = @intFromEnum(state_map.idFromState(NextState));

                    try edges.append(arena_allocator, .{
                        .from = @intCast(state_idx),
                        .to = next_state_idx,
                        .label = field.name,
                    });
                }
            },
            else => @compileError("Only support tagged union!"),
        }
    }

    // Sort nodes by FSM name
    std.mem.sort(Node, nodes.items, {}, struct {
        pub fn lessThan(_: void, lhs: Node, rhs: Node) bool {
            const cmp = std.mem.order(u8, lhs.fsm_description, rhs.fsm_description);
            if (cmp != .eq) return cmp == .lt;
            return lhs.id < rhs.id;
        }
    }.lessThan);

    return .{
        .arena = arena,
        .edges = edges,
        .name = @TypeOf(State_.info).ProtocolName,
        .nodes = nodes,
    };
}

pub fn deinit(self: *Graph) void {
    self.arena.deinit();
}
