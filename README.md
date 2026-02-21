# Troupe – A Deterministic Distributed Protocol Composition Framework

Troupe is a distributed protocol construction library built on Zig's type system. Its core philosophy is **using type determinism to counter communication uncertainty**: protocols are modeled as fully deterministic state machines, correctness is guaranteed through compile-time verification, and all communication unreliability (latency, loss, reordering) is isolated behind replaceable channel layers. Ultimately, developers can construct complex multi-role protocols as if writing single-threaded programs, confident that they will execute as intended in any environment.

[youtube](https://youtu.be/s4WASXIHB_s?si=xKq0E56VFddwet8U), [bilibili](https://www.bilibili.com/video/BV1wgfEBvEHu/?share_source=copy_web&vd_source=06f3616867de4f0c8ec011af7da3e868)

## Core Idea: Protocol as State Graph

In Troupe, a protocol consists of a set of **states**, each represented as a tagged union. Each field of the union represents a possible message, and the message's "next state" is explicitly specified through a type parameter. For example:

```zig
const Ping = union(enum) {
    ping: Data(u32, Pong),
    // ...
};
```

`Data(Payload, NextState)` is a simple wrapper that carries the actual payload and specifies the next state the protocol should enter after this message is sent or received.

Each state also carries compile-time metadata `info` describing the role relationships in this state:

- `sender`: who sends the message in this state.
- `receiver`: who will receive this message (can be multiple).
- `internal_roles`: the set of all roles participating in this protocol.
- `extern_state`: list of "external states" that may be entered after this protocol ends (typically entry or exit points of other protocols).

This information is not just documentation—it is used by the library for compile-time validation and runtime dispatching.

## State Execution Model: Behavior Determined by Role

At runtime, each role (e.g., `alice`, `bob`) independently runs the `Runner.runProtocol` function, which decides how to act based on the current state and its own role:

- **If the role is the sender**: It calls the state's `process` function to generate a message, then sends this message through the channel to all roles in the `receiver` list. It then transitions to the next state specified by the message's `NextState`.
- **If the role is a receiver**: It receives a message from the channel (from the sender), calls the corresponding preprocess function `preprocess_N` (where N is the role's position in the `receiver` list), and then transitions to the next state specified by the message.
- **If the role does not participate in this round**: The state is irrelevant to it—it simply skips this round, but may receive a "notification" from other roles (see below) to synchronize to a new state.

This design ensures that the execution path for each role is **unique and deterministic**: each state explicitly defines who sends, who receives, what is sent, and where to go next.

## Branch States and Full Internal Notification

When a state's union has multiple fields (i.e., multiple branch choices), it means the protocol faces a decision point. For example, in a two-phase commit coordinator state, the coordinator may choose "commit" or "abort" based on participant feedback. In this case, only the sender (coordinator) knows which branch was chosen.

To ensure all internal roles (other roles in `internal_roles`) learn of this choice, **the generated message must be sent to all internal roles except the sender**. This is why the library enforces: when a state's union has more than one field, the receiver list must cover all other internal roles, satisfying `1 + receiver.len == internal_roles.len`.

If any internal role is missing, it would never learn the new state, leading to system-wide inconsistency. This rule fundamentally prevents "partial role ignorance" and is a cornerstone of Troupe's global determinism guarantee.

## Protocol Composition: Nested State Graphs

Troupe's most powerful feature is the ability to seamlessly compose multiple protocols into a larger one. Composition is straightforward: pass one protocol's entry state as the `NextState` type parameter of another protocol's message.

For example, in the `random-pingpong-2pc` demo:

```zig
charlie_as_coordinator: Data(void, PingPong(.alice, .bob, 
    PingPong(.bob, .charlie, 
        PingPong(.charlie, .alice, 
            CAB(@This()).Begin
        ).Ping
    ).Ping
).Ping),
```

Here `PingPong` is a function that generates ping-pong protocol states, accepting role parameters and a next state type, returning a struct containing `Ping`, `Pong`, and other states. Through nested calls, we can make ping-pong automatically enter the `Begin` state of two-phase commit, forming a composite protocol.

At compile time, the `reachableStates` function recursively expands all nested states, building a complete global state graph and generating unique integer IDs for each state. Simultaneously, it performs comprehensive validation:

- Do each state's sender and receiver belong to internal roles?
- Does the receiver list contain the sender? (Not allowed)
- Are there duplicate receivers?
- For branch states, is the number of unnotified roles correct?
- Do all states' context types match (comparing per-role fields)?

These checks ensure the composed protocol remains a valid deterministic state machine.

## Cross-Protocol Synchronization: External Role Notification

When protocol execution reaches a state marked as "external" (appearing in the `extern_state` list), it means the current protocol ends and another begins. To ensure all roles—including those not participating in the current protocol—know about this transition, Troupe mandates that `internal_roles[0]` (the first internal role) sends a special `Notify` message to all **external roles** (roles not in `internal_roles`), containing the new state's ID.

External roles, in their next loop iteration, first receive this notification and jump directly to the corresponding state, synchronizing with internal roles. This "push-style" synchronization avoids blind polling or guessing, ensuring consistent state migration across the entire system.

## Context Aggregation: A Bridge for Data Sharing

Different protocols may need to access the same role's data (e.g., counters, random seeds). Troupe solves this through an **aggregated context structure**: developers define a top-level `Context` where each role has a corresponding field containing all data that role might need (including sub-context fields for various protocols).

For example:

```zig
const Context = struct {
    alice: AliceContext,
    bob: BobContext,
    charlie: CharlieContext,
    selector: SelectorContext,
};
```

In state handler functions (`process`/`preprocess`), the role-specific context type is obtained via `info.Ctx(role)`, and a pointer to that role's field is passed at runtime. This allows different protocols to share data through the same role's context while maintaining isolation between roles.

## Compile-Time Graph Traversal: The Last Line of Defense

Troupe performs a depth-first traversal of all reachable states at compile time via `reachableStates`, generating a complete state list and state ID enumeration. This process not only builds the runtime dispatch table but, more importantly, executes extensive **consistency checks**:

- Verifies that all states' context types match (ensuring each role's field type is consistent across the aggregated context).
- Validates the receiver count rule for branch states.
- Ensures senders and receivers are within internal roles.
- Confirms no role is both sender and receiver.
- Checks that external state lists don't contain internal states (avoiding circular dependencies).

Any rule violation results in a compile error with a clear message. This means that once a program compiles successfully, the protocol composition is guaranteed legal—runtime will never encounter role mismatches or lost states.

## Summary

Troupe's design embodies a profound philosophy: **transform the complexity of distributed protocols into verifiable deterministic models through the type system**. It pushes uncertainty to the communication layer while keeping the protocol core as precise as a script. Developers need only define states, transitions, and role behaviors—the framework handles dispatching, synchronization, and validation automatically.

Whether implementing a simple ping-pong, a multi-role multi-stage two-phase commit, or even dynamic compositions of these protocols, Troupe enables you to build with **type safety, composability, and compile-time verification**, ultimately running reliable, efficient distributed systems.

> **The Troupe Metaphor**: Each role is an actor, protocols are scripts, states are scenes, messages are lines. Actors perform strictly according to the script; even if stage surprises occur (communication latency), backstage crew (channel layer) ensure lines are delivered accurately. The audience always witnesses a deterministic, brilliant performance.


## Adding troupe to your project
Requires zig version greater than 0.15.0.


Download and add troupe as a dependency by running the following command in your project root:
```shell
zig fetch --save git+https://github.com/sdzx-1/troupe.git
```

Then, retrieve the dependency in your build.zig:
```zig
const troupe = b.dependency("troupe", .{
    .target = target,
    .optimize = optimize,
});
```

Finally, add the dependency's module to your module's imports:
```zig
exe_mod.addImport("troupe", troupe.module("root"));
```

You should now be able to import troupe in your module's code:
```zig
const troupe = @import("troupe");
```

## Core idea
### 0. troupe assumes that communication between roles is sequential
troupe ensures that the behavior of each role is completely determined by the state machine.
If the communication itself can guarantee the order (such as TCP), then the protocol described by troupe is deterministic and the behavior of all roles is consistent.

### 1. Compositionality of State

Through [polystate](https://github.com/sdzx-1/polystate), we know that state can be used as a function and parameter, which we call high-order state.

### 2. Viewing the Communication Process as State Machines
Through the introduction [here](https://discourse.haskell.org/t/introduction-to-typed-session/10100), we know that communication can be modeled using a state machine.

### 3. How to handle branch status in multi-role communication
Multi-role communication differs from client-server communication in that troupe requires that messages generated during branching must be notified to all other parties.
This ensures that all roles are synchronized.

### 4. How to Combine Protocols with Different Participants
If two protocol participants are exactly the same, then the states are directly combined.
If the participants of the two protocols are different, then we need to notify all other roles except the roles of the previous protocol.
This [issue](https://github.com/sdzx-1/troupe/issues/15) describes the situation.

## Examples
### pingpong
```shell
zig build pingpong
```
Alice and Bob have multiple ping-pong communications back and forth.

![pingpong](./data/pingpong.svg)
### sendfile

```shell
zig build sendfile
```
Alice sends a file to Bob, and every time she sends a chunk of data, she checks whether the hash values of the sent and received data match.

![sendfile](./data/sendfile.svg)
### pingpong-sendfile

```shell
zig build pingpong-sendfile
```
Combining the pingpong protocol and the sendfile protocol

![pingpong-sendfile](./data/pingpong-sendfile.svg)
### 2pc

```shell
zig build 2pc
```
A two-phase protocol demo with Charlie as the coordinator and Alice and Bob as participants.
Alice and Bob have no actual transactions; they simply randomly return true or false.

![2pc](./data/2pc.svg)
### random-pingpong-2pc

```shell
zig build random-pingpong-2pc
```
A complex protocol involving four actors has an additional selector to select the combined protocol to run.
Here, we arbitrarily combine the pingpong protocol and the 2pc protocol.
Note that the communication actors in pingpong and 2pc are different.
troupe supports this combination of different protocols, even if the protocols have different numbers of participants.


![random-pingpong-2pc](./data/random-pingpong-2cp.svg)
