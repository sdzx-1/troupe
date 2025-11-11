const std = @import("std");
const meta = std.meta;
pub const Graph = @import("Graph.zig");

//The Exit status is unique.
pub const Exit = union(enum) {
    pub const info: Info = .{};

    pub const Info = struct {
        pub const ProtocolName = "polysession_exit";
        pub const Role = void;
        pub const Context = void;
    };
};

//When switching protocols, all roles that were not in the previous protocol are notified and informed of the next status.
pub const Notify = struct { polysession_notify: u8 };

pub fn Data(Data_: type, State_: type) type {
    return struct {
        data: Data_,

        pub const Data = Data_;
        pub const State = State_;
    };
}

pub fn ProtocolInfo(
    comptime ProtocolName_: []const u8,
    comptime Role_: type,
    comptime context_: anytype,
    comptime internal_roles_: []const Role_,
    comptime extern_state_: []const type,
) type {
    comptime {
        switch (@typeInfo(Role_)) {
            .@"enum" => |E| {
                for (E.fields) |field| {
                    if (@hasField(@TypeOf(context_), field.name)) {} else {
                        @compileError(std.fmt.comptimePrint("{any} does not contain field {s}", .{ context_, field.name }));
                    }
                }
            },
            else => @compileError("Role only support enum!"),
        }
    }

    return struct {
        name: []const u8 = "Nameless",
        sender: Role_,
        receiver: []const Role_,

        pub const ProtocolName = ProtocolName_;
        pub const Role = Role_;
        pub const context = context_;
        pub const internal_roles: []const Role_ = internal_roles_;
        pub const extern_state: []const type = extern_state_;

        pub fn Ctx(_: @This(), r: Role_) type {
            return @field(context_, @tagName(r));
        }

        const Info = @This();

        pub fn Cast(
            comptime _: Info,
            comptime name: []const u8,
            comptime sender: Role,
            comptime receiver: Role,
            comptime T: type,
            comptime CastFn: type,
            comptime NextState: type,
        ) type {
            return union(enum) {
                cast: Data(T, NextState),

                pub const info: Info = .{ .name = name, .sender = sender, .receiver = &.{receiver} };

                pub fn process(ctx: *@field(context, @tagName(sender))) !@This() {
                    return .{ .cast = .{ .data = try CastFn.process(ctx) } };
                }

                pub fn preprocess_0(ctx: *@field(context, @tagName(receiver)), msg: @This()) !void {
                    switch (msg) {
                        .cast => |val| try CastFn.preprocess(ctx, val.data),
                    }
                }
            };
        }
    };
}

fn TypeSet(comptime bucket_count: usize) type {
    return struct {
        buckets: [bucket_count][]const type,

        const Self = @This();

        pub const init: Self = .{
            .buckets = @splat(&.{}),
        };

        pub fn insert(comptime self: *Self, comptime Type: type) void {
            comptime {
                const hash = std.hash_map.hashString(@typeName(Type));

                self.buckets[hash % bucket_count] = self.buckets[hash % bucket_count] ++ &[_]type{Type};
            }
        }

        pub fn has(comptime self: Self, comptime Type: type) bool {
            comptime {
                const hash = std.hash_map.hashString(@typeName(Type));

                return std.mem.indexOfScalar(type, self.buckets[hash % bucket_count], Type) != null;
            }
        }

        pub fn items(comptime self: Self) []const type {
            comptime {
                var res: []const type = &.{};

                for (&self.buckets) |bucket| {
                    res = res ++ bucket;
                }

                return res;
            }
        }
    };
}

pub fn reachableStates(comptime State: type) struct { states: []const type, state_machine_names: []const []const u8 } {
    comptime {
        var states: []const type = &.{State};
        var state_machine_names: []const []const u8 = &.{@TypeOf(State.info).ProtocolName};
        var states_stack: []const type = &.{State};
        var states_set: TypeSet(128) = .init;
        const ExpectedContext = @TypeOf(State.info).context;

        states_set.insert(State);

        reachableStatesDepthFirstSearch(&states, &state_machine_names, &states_stack, &states_set, ExpectedContext);

        return .{ .states = states, .state_machine_names = state_machine_names };
    }
}

fn reachableStatesDepthFirstSearch(
    comptime states: *[]const type,
    comptime state_machine_names: *[]const []const u8,
    comptime states_stack: *[]const type,
    comptime states_set: *TypeSet(128),
    comptime ExpectedContext: anytype, //Context type
) void {
    @setEvalBranchQuota(20_000_000);

    comptime {
        if (states_stack.len == 0) {
            return;
        }

        const CurrentState = states_stack.*[states_stack.len - 1];
        states_stack.* = states_stack.*[0 .. states_stack.len - 1];

        if (CurrentState != Exit) {
            const info = CurrentState.info;
            const Info = @TypeOf(CurrentState.info);
            const Role = Info.Role;
            const internal_roles = Info.internal_roles;

            //The sender must belong to internal_roles
            if (std.mem.indexOfScalar(Role, internal_roles, info.sender) == null) {
                @compileError(std.fmt.comptimePrint(
                    "{any}\nsender .{t} does not belog to internal_roles {any}",
                    .{ CurrentState, info.sender, internal_roles },
                ));
            }

            //The receivers must belong to internal_roles
            for (info.receiver) |role| {
                if (std.mem.indexOfScalar(Role, internal_roles, role) == null) {
                    @compileError(std.fmt.comptimePrint(
                        "{any}\nreceiver .{t} does not belog to internal_roles {any}",
                        .{ CurrentState, role, internal_roles },
                    ));
                }
            }

            //The receivers cannot contain the sender
            if (std.mem.indexOfScalar(Role, info.receiver, info.sender) != null) {
                @compileError(std.fmt.comptimePrint(
                    "{any}\nreceivers {any} contain sender .{t}",
                    .{ CurrentState, info.receiver, info.sender },
                ));
            }

            //The receivers cannot be empty
            // If the internal_roles len is 1, then the receiver can be empty;
            // this is for compatibility with polystate.
            if (Info.internal_roles.len > 1 and info.receiver.len == 0) {
                @compileError(std.fmt.comptimePrint(
                    "{any}\nreceivers is empty",
                    .{CurrentState},
                ));
            }

            //There cannot be duplicate roles in the receivers
            // this is for compatibility with polystate.
            if (Info.internal_roles.len > 1) {
                for (0..info.receiver.len - 1) |i| {
                    if (std.mem.indexOfScalar(Role, info.receiver[i + 1 ..], info.receiver[i]) != null) {
                        @compileError(std.fmt.comptimePrint(
                            "{any}\nthere are repeated characters in receivers {any}",
                            .{ CurrentState, info.receiver },
                        ));
                    }
                }
            }
            //If the state has a branch, then the conditions must be met: 1 + receivers.len = internal_roles.len
            if (@typeInfo(CurrentState).@"union".fields.len > 1) {
                if (info.receiver.len + 1 != internal_roles.len) {
                    @compileError(std.fmt.comptimePrint(
                        "{any}\nIn branch State, {d} roles have not been notified",
                        .{ CurrentState, internal_roles.len - (info.receiver.len + 1) },
                    ));
                }
            }
        }

        switch (@typeInfo(CurrentState)) {
            .@"union" => |un| {
                for (un.fields) |field| {
                    const NextState = field.type.State;

                    if (!states_set.has(NextState)) {
                        // Validate that the handler context type matches (skip for special states like Exit)
                        if (NextState != Exit) {
                            const Info = @TypeOf(NextState.info);
                            const NextContext = Info.context;
                            const Role = Info.Role;
                            const is_equal: bool = blk: {
                                for (@typeInfo(Role).@"enum".fields) |F| {
                                    if (@field(NextContext, F.name) != @field(ExpectedContext, F.name)) {
                                        break :blk false;
                                    }
                                }
                                break :blk true;
                            };
                            if (!is_equal) {
                                @compileError(std.fmt.comptimePrint(
                                    "Context type mismatch: State {any}\nhas context type {any}\nbut expected {any}",
                                    .{ NextState, NextContext, ExpectedContext },
                                ));
                            }
                        }

                        states.* = states.* ++ &[_]type{NextState};
                        state_machine_names.* = state_machine_names.* ++ &[_][]const u8{@TypeOf(NextState.info).ProtocolName};
                        states_stack.* = states_stack.* ++ &[_]type{NextState};
                        states_set.insert(NextState);

                        reachableStatesDepthFirstSearch(states, state_machine_names, states_stack, states_set, ExpectedContext);
                    }
                }
            },
            else => @compileError("Only support tagged union!"),
        }
    }
}

pub const StateMap = struct {
    states: []const type,
    state_machine_names: []const []const u8,
    StateId: type,

    pub fn init(comptime State_: type) StateMap {
        @setEvalBranchQuota(200_000_000);

        comptime {
            const result = reachableStates(State_);
            return .{
                .states = result.states,
                .state_machine_names = result.state_machine_names,
                .StateId = @Type(.{
                    .@"enum" = .{
                        .tag_type = std.math.IntFittingRange(0, result.states.len - 1),
                        .fields = inner: {
                            var fields: [result.states.len]std.builtin.Type.EnumField = undefined;

                            for (&fields, result.states, 0..) |*field, State, state_int| {
                                field.* = .{
                                    .name = @typeName(State),
                                    .value = state_int,
                                };
                            }

                            const fields_const = fields;
                            break :inner &fields_const;
                        },
                        .decls = &.{},
                        .is_exhaustive = true,
                    },
                }),
            };
        }
    }

    pub fn StateFromId(comptime self: StateMap, comptime state_id: self.StateId) type {
        return self.states[@intFromEnum(state_id)];
    }

    pub fn idFromState(comptime self: StateMap, comptime State: type) self.StateId {
        if (!@hasField(self.StateId, @typeName(State))) @compileError(std.fmt.comptimePrint(
            "Can't find State {s}",
            .{@typeName(State)},
        ));
        return @field(self.StateId, @typeName(State));
    }
};

pub fn Runner(
    comptime State_: type,
) type {
    return struct {
        pub const Role = @TypeOf(State_.info).Role;
        pub const state_map: StateMap = .init(State_);
        pub const StateId = state_map.StateId;

        pub fn idFromState(comptime State: type) StateId {
            return state_map.idFromState(State);
        }

        pub fn StateFromId(comptime state_id: StateId) type {
            return state_map.StateFromId(state_id);
        }

        fn check_then_notify_extern_roles(
            comptime curr_role: Role,
            comptime mult_channel_static_index_role: bool,
            comptime state_id: StateId,
            comptime NewState: type,
            comptime internal_roles: []const Role,
            comptime extern_state: []const type,
            mult_channel: anytype,
        ) !void {
            //Checks if the new state is an external state and the current role is `internal_roles[0]`.
            if (comptime std.mem.indexOfScalar(type, extern_state, NewState) != null and
                curr_role == internal_roles[0])
            {
                //It turns out that all roles that do not belong to internal_roles must be notified.
                //This is equivalent to synchronizing the status once each protocol ends.
                inline for (0..@typeInfo(Role).@"enum".fields.len) |i| {
                    const role: Role = @enumFromInt(i);
                    if (comptime std.mem.indexOfScalar(Role, internal_roles, role) == null) {
                        if (mult_channel_static_index_role)
                            try @field(mult_channel, @tagName(role)).send(state_id, Notify{ .polysession_notify = @intFromEnum(idFromState(NewState)) })
                        else
                            try mult_channel.send(curr_role, role, state_id, Notify{ .polysession_notify = @intFromEnum(idFromState(NewState)) });
                    }
                }
            }
        }
        pub fn runProtocol(
            comptime curr_role: Role,
            comptime mult_channel_static_index_role: bool,
            mult_channel: anytype,
            curr_id: StateId,
            ctx: *State_.info.Ctx(curr_role),
        ) !void {
            @setEvalBranchQuota(10_000_000);
            sw: switch (curr_id) {
                inline else => |state_id| {
                    const State = StateFromId(state_id);
                    if (comptime State == Exit) return;

                    const info = comptime State.info;
                    const sender: Role = comptime info.sender;
                    const receiver: []const Role = comptime info.receiver;
                    const internal_roles = comptime @TypeOf(info).internal_roles;
                    const extern_state = comptime @TypeOf(info).extern_state;

                    if (comptime std.mem.indexOfScalar(Role, internal_roles, curr_role) == null) {
                        //curr_role does not participate in the current protocol, so it waits for notification directly.
                        //The person who notifies it is determined to be `internal_role[0]`.
                        //The determinism here is very important.
                        //It ensures that the sender and receiver of the notification can be determined by the state machine.
                        const notify: Notify =
                            if (mult_channel_static_index_role)
                                try @field(mult_channel, @tagName(internal_roles[0])).recv(state_id, Notify)
                            else
                                try mult_channel.recv(curr_role, internal_roles[0], state_id, Notify);

                        const next_state_id: StateId = @enumFromInt(notify.polysession_notify);
                        continue :sw next_state_id;
                    } else if (comptime curr_role == sender) {
                        //The current role is the sender, which sends messages to all receivers.
                        const result = try State.process(ctx);
                        inline for (receiver) |rvr| {
                            if (mult_channel_static_index_role)
                                try @field(mult_channel, @tagName(rvr)).send(state_id, result)
                            else
                                try mult_channel.send(curr_role, rvr, state_id, result);
                        }
                        switch (result) {
                            inline else => |new_fsm_state_wit| {
                                const NewState = @TypeOf(new_fsm_state_wit).State;
                                try check_then_notify_extern_roles(
                                    curr_role,
                                    mult_channel_static_index_role,
                                    state_id,
                                    NewState,
                                    internal_roles,
                                    extern_state,
                                    mult_channel,
                                );
                                continue :sw comptime idFromState(NewState);
                            },
                        }
                    } else {
                        if (comptime std.mem.indexOfScalar(Role, receiver, curr_role)) |idx| {
                            //curr_role is the receiver
                            const result =
                                if (mult_channel_static_index_role)
                                    try @field(mult_channel, @tagName(sender)).recv(state_id, State)
                                else
                                    try mult_channel.recv(curr_role, sender, state_id, State);

                            //If the receiver needs to notify an external actor,
                            // it should do so as soon as possible,
                            // so that the external actor is notified before it executes its own handler function.
                            switch (result) {
                                inline else => |new_fsm_state_wit| {
                                    const NewState = @TypeOf(new_fsm_state_wit).State;
                                    try check_then_notify_extern_roles(
                                        curr_role,
                                        mult_channel_static_index_role,
                                        state_id,
                                        NewState,
                                        internal_roles,
                                        extern_state,
                                        mult_channel,
                                    );
                                },
                            }

                            //The receiver's handler function is called based on the receiver's position in `receiver`.
                            // This is a convention that needs to be met when writing code and provides type safety.
                            const fn_name = std.fmt.comptimePrint("preprocess_{d}", .{idx});
                            if (@hasDecl(State, fn_name)) {
                                try @field(State, fn_name)(ctx, result);
                            }

                            switch (result) {
                                inline else => |new_fsm_state_wit| {
                                    const NewState = @TypeOf(new_fsm_state_wit).State;
                                    continue :sw comptime idFromState(NewState);
                                },
                            }
                        } else {
                            switch (@typeInfo(State)) {
                                .@"union" => |U| {
                                    //The current round of communication for this protocol does not involve curr_role.
                                    // However, it still needs to check whether to notify external roles.
                                    comptime std.debug.assert(U.fields.len == 1);
                                    const NewState = U.fields[0].type.State;
                                    try check_then_notify_extern_roles(
                                        curr_role,
                                        mult_channel_static_index_role,
                                        state_id,
                                        NewState,
                                        internal_roles,
                                        extern_state,
                                        mult_channel,
                                    );
                                    continue :sw comptime idFromState(NewState);
                                },
                                else => unreachable,
                            }
                        }
                    }
                },
            }
        }
    };
}
