# The Art of Projection: Zero-Overhead Derivation from a Single State Machine to Multiple Roles

In the world of distributed systems, we often find ourselves caught in a dilemma: a protocol requires the collaboration of multiple roles, yet the behavioral logic of each role must be implemented separately. As a result, the exact same control flow is repeatedly copied, pasted, and modified, eventually devolving into an unmaintainable maze of code. The emergence of Polyrole breaks this dilemma in an almost magical way—it models the protocol as a **global state machine**, and then "projects" this state machine onto each role at compile time, allowing each role to automatically obtain its own control flow. This process incurs no runtime overhead, yet it fundamentally changes the way distributed programs are written.

## The Pain of Scattered Control Flow

Imagine a simple three-party protocol: Alice sends a request, Bob processes and forwards it to Charlie, and Charlie finally responds. In a traditional implementation, we need to write three separate pieces of code:

* Alice's code contains the logic for "sending a request, waiting for a response, and handling timeouts."
* Bob's code contains the logic for "receiving the request, forwarding it, waiting for Charlie's response, and sending it back."
* Charlie's code contains the logic for "receiving the request, processing it, and sending a response."

Although these three pieces of code represent different perspectives, they essentially describe the same protocol flow. When the protocol evolves (for example, by adding a retry mechanism), all three pieces of code must be modified synchronously. This repetitive labor is not only inefficient but also a breeding ground for bugs—with the slightest carelessness, one role's state machine falls out of sync with the others, plunging the entire system into chaos.

The root of the problem is this: **control flow is scattered**. Each role independently maintains its own understanding of the protocol, and the overall behavior of the protocol can only be pieced together from these fragmented parts.

## State Machines: A Natural Global Description

If we take a step back, a protocol is essentially a **finite state machine**  it has a set of states, transitions between states are triggered by messages, and each state specifies who sends the message, who receives it, and what the next state is. This state machine naturally encompasses the behavior of all roles—it doesn't favor any single party, but rather describes the evolution of the entire protocol from a global perspective.

Polyrole's core insight is exactly this: **use this global state machine as the single source of truth**. Developers only need to describe the overall state graph of the protocol once, rather than writing code for each role separately. For example, a simple ping-pong protocol can be represented as:

* State `Ping`: Alice sends a ping (carrying a number) to Bob, and then transitions to `Pong`.
* State `Pong`: Bob sends a pong (carrying a number) to Alice, and then transitions to `End`.

This description simultaneously captures both Alice's and Bob's perspectives. It contains no redundancy and no repetition; it captures purely the essence of the protocol.

## Projection: The Perfect Mapping from Global to Individual

With a global state machine defined, how do we let each role know what it should do in each state? The answer is **projection**.

Projection is a mathematical concept: mapping a high-dimensional object onto a lower-dimensional subspace . In Polyrole, the global state machine is the high-dimensional object, containing information for all roles. Each role only needs to see the parts relevant to itself—just like observing the same three-dimensional object from different angles to yield different two-dimensional projections.

Polyrole executes this projection at compile time:

* For the role of Alice, the projection extracts all states where Alice is either a sender or a receiver and generates Alice's execution logic: when in a certain state, if she is the sender, call the corresponding handler function and send the message; if she is the receiver, wait for the message and call the pre-processing function; if she is not involved in that state, simply skip it.
* For the role of Bob, the projection does the exact same thing, but tailored to Bob's perspective.

The key here is that this projection process is **completed at compile time**. Zig's compile-time reflection capabilities allow Polyrole to traverse the global state machine and generate dedicated code paths for each role. At runtime, each role simply advances along its pre-calculated path without any additional overhead—no virtual table lookups, no dynamic dispatch, and no runtime type checking.

## The Secret to Zero Runtime Overhead

Traditional object-oriented polymorphism often relies on virtual function tables to decide which method to call at runtime. Polyrole does the exact opposite: all decisions are solidified at compile time. Each role's behavior is unrolled into direct function calls and state transitions. For example, for Alice, her runtime loop is essentially a giant `switch` statement that jumps directly to the corresponding handling code based on the current state ID—and this code was generated entirely by the projection at compile time.

This design means:

* **No runtime overhead**: Projection is computed at compile time; the runtime merely executes pre-determined instructions.
* **Minimal memory footprint**: Each role only needs to maintain its current state ID and context data, without needing to store complete protocol metadata.
* **Predictability**: Since all paths are known at compile time, the system's behavior is entirely deterministic, making it incredibly easy to reason about and test.

## The Paradigm Shift from "Copying" to "Projection"

In the traditional approach, we are forced to **copy** the control flow: the exact same logic is scattered across the code of multiple roles in varying forms. Copying inherently implies redundancy, the risk of inconsistency, and high maintenance costs.

Polyrole replaces copying with **projection**: the control flow is defined only once, and then dedicated views are generated for each role through compile-time projection. Projection is not copying, but rather providing different perspectives derived from the exact same source—just like a holographic projection, where a 3D model can project countless 2D images, yet all images originate from that single model.

The benefits brought by this shift are immense:

* **Single source of truth**: Modifying the protocol only requires a change in one place, and the behavior of all roles is automatically updated.
* **Consistency guarantee**: The projection process is executed by the compiler, completely eliminating the possibility of inconsistencies caused by human error.
* **Dimensionality reduction of complexity**: As the number of roles increases, the volume of code does not grow linearly—because the size of the global state machine is tied only to the protocol itself, not the number of roles involved.

## The Natural Extension of Composability

The projection mechanism also makes protocol composition exceptionally simple. When we nest two state machines together, the global state graphs merge automatically, and the projection mechanism applies equally to the newly combined graph. Developers simply declare "execute protocol A first, then execute protocol B," and the compiler will generate the complete composite state machine, automatically projecting the correct behavior for every single role. This is akin to combining basic shapes to form a complex pattern, where the projector can still accurately cast the proper view from every angle.

## Conclusion: A New Mindset for Distributed System Development

Polyrole redefines the way distributed programs are written using a "global state machine + compile-time projection" approach. It proves that **control flow does not have to be scattered across multiple roles; instead, it can be condensed into a single whole and then precisely distributed to each participant at compile time**. This concept not only eliminates repetitive labor but also allows us to build previously unimaginably complex protocols without worrying about code spiraling out of control.

From copying to projection, from scattered to condensed, Polyrole's core philosophy may well inspire more languages and frameworks, truly ushering the development of distributed systems into the era of "describe once, execute everywhere."

