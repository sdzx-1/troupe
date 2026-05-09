# learn.md — Troupe remote_fm 调试记录

本文件记录 `examples/protocols/remote_fm.zig` 中 Serial ReadFile 和
WriteFile 状态机实现的三处 bug 及其修复过程。

---

## 目录

1. [ReadFile: 缓冲区别名导致数据丢失和错位](#1-readfile-缓冲区别名导致数据丢失和错位)
2. [WriteFile: Writer 位置错误 + 缓存未刷出](#2-writefile-writer-位置错误--缓存未刷出)
3. [WriteFile: pending_path 借用生命周期](#3-writefile-pending_path-借用生命周期)

---

## 1. ReadFile: 缓冲区别名导致数据丢失和错位

### 症状

大文件通过 `read` 命令读取时，内容大量缺失，且已有的内容位置错乱。

### 根因分析过程

`ReadFile.process` 服务端代码：

```zig
var streaming = file.readerStreaming(io_, &s.read_buf);
const n = streaming.interface.readSliceShort(&s.read_buf);
```

`file.readerStreaming(io_, &s.read_buf)` 创建了一个 `Io.File.Reader`，
其内部 `Io.Reader.buffer` 指向 `s.read_buf`。
然后 `readSliceShort(&s.read_buf)` 把同一块内存作为输出缓冲区传入。

追踪 `readSliceShort` 内部数据流：

1. `readSliceShort` 调用 `readVec` →
   `readVecStreaming` → `r.interface.writableVector`

2. `writableVector` 的职责是把用户提供的输出 buffer 放入 iovec 数组，
   **同时额外追加 `r.buffer`（Streaming Reader 的内部缓冲区）作为第二段 iovec**。
   这是标准库的正常行为：一次 syscall 多读数据，多余的数据留在内部缓冲区以便下次使用。

3. 但由于 `r.buffer` 和用户输出 buffer 指向同一块内存（`s.read_buf`），
   iovec 数组变成 `[s.read_buf, s.read_buf]`——两块完全重叠的区域。

4. `readStreaming`（底层 `readv`）顺序填充：第一批数据写入
   `s.read_buf[0..4096]`，第二批数据写入 `s.read_buf[0..4096]`
   ——直接覆盖第一批。总读取量翻倍（8192 字节而非 4096）。

5. 每轮 `process` 结束，局部的 `streaming` 变量销毁，Streaming Reader
   的内部状态全部丢失。下一轮创建全新的 reader，OS 文件偏移已经跳过了
   8192 字节，中间 4096 字节的数据永远不可达。

**结果**：对于 >4096 字节的文件，每 4096 字节的 chunk 实际包含的是文件中
  偏移 4096-8191 的内容，而非 0-4095。每隔 4096 字节跳过一个块。

### 标准库文档中的线索

`Io.Reader.VTable.readVec` 的 doc comment 明确说明：

```
/// `data` may not contain an alias to `Reader.buffer`.
```

即 `data`（用户输出缓冲区）不得与 `Reader.buffer`（Streaming Reader
内部缓冲区）别名。这个约束在文档中但初始代码未遵守。

### 修复

1. **分离缓冲区**：`ServerContext` 增加 `read_stream_buf` 专用作
   Streaming Reader 内部缓冲，`read_buf` 仅作 `readSliceShort` 输出。

2. **持久化 File.Reader**：替换 `read_file: ?std.Io.File` 为
   `reader: ?std.Io.File.Reader`，跨 `process` 调用保持内部缓冲状态，
   避免 OS 偏移跳数据。

3. **`Command.preprocess_0` 清理**：`.read` 分支关闭残存的 reader，
   防止状态机重入泄漏句柄。

### 学到的东西

- **Buffer aliasing 是隐性契约违规**：标准库函数对参数的内存独立有约束，
  但往往只在 doc comment 中注明，不在类型系统中强制。传相同缓冲区到两个
  预期独立的参数时，必须检查实现是否会在内部混用。
- **writableVector 的额外 iovec 机制**：`Io.Reader` 的 `writableVector`
  会追加 `r.buffer` 作为额外的写入目的地，这是为了在填充用户 buffer 的同时
  利用剩余 syscall 容量多读数据。只有不 aliasing 时这个优化才正确。
- **Streaming Reader 是有状态的**：`File.Reader` 维护 `pos`、`interface.buffer`、
  `interface.seek/end` 等内部状态。每轮重建等于丢弃所有缓冲数据，正确用法是
  持久化（如 `sendfile.zig` 示例所示）。
- **`@fieldParentPtr` 的稳定性**：`File.Reader.readVec` 使用
  `@fieldParentPtr("interface", io_reader)` 从嵌入的 `Io.Reader` 指针恢复
  外层的 `File.Reader`。这要求 `File.Reader` 在内存中的位置固定——对于
  栈变量和结构体字段都是安全的，但跨作用域移动时需要确保指针有效。

---

## 2. WriteFile: Writer 位置错误 + 缓存未刷出

### 症状

`write` 命令执行后，目标文件为空或只有最后一个 chunk 的部分内容。

### 根因分析过程

`WriteFile.preprocess_0` 服务端代码（原始）：

```zig
var file_writer = f.writer(io_, &s.write_writer_buf);
file_writer.interface.writeAll(v.data) catch {
    s.write_error = true;
};
```

追踪 `Io.Writer.writeAll` 和 `File.Writer` 的 `init` 实现：

#### Bug 2a: 位置错误

`f.writer()` 调用 `File.Writer.init`，创建 **positional writer**
（`mode = .positional`），初始 `pos = 0`。

写入时 `drainPositional` 调用 `io.vtable.fileWritePositional(..., w.pos)`，
即 `pwrite(fd, data, ..., pos)`——在指定偏移处写入，不影响 OS 文件偏移。

每轮 `preprocess_0` 创建全新 writer，`pos` 重置为 0。因此**所有 chunk
都在文件偏移 0 处写入**，后一个 chunk 覆盖前一个。最终文件只保留最后一个
chunk（或部分内容，取决于写入顺序和文件大小）。

#### Bug 2b: 缓存未刷出

`Io.Writer.write` 的实现：

```zig
pub fn write(w: *Writer, bytes: []const u8) Error!usize {
    if (w.end + bytes.len <= w.buffer.len) {
        @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
        w.end += bytes.len;
        return bytes.len;   // 仅缓存，不触发 drain
    }
    return w.vtable.drain(w, &.{bytes}, 1);
}
```

chunk 大小（4096 字节） ≤ writer buffer 大小（也是 4096 字节），
`writeAll` → `write` → 条件成立 → 数据仅拷贝到 `w.buffer`（即
`write_writer_buf`），`w.end` 递增，返回成功。**系统调用未发生**。

writer 是局部变量，离开作用域时没有 deinit/destructor 刷新缓存。
`write_writer_buf` 中的数据被静默丢弃。

### 修复

```zig
// ① writerStreaming: 使用 OS 文件偏移，不受 pos 重置影响
var file_writer = f.writerStreaming(io_, &s.write_writer_buf);
file_writer.interface.writeAll(v.data) catch { ... };
// ② 显式 flush: 确保缓存数据落盘
file_writer.interface.flush() catch { ... };
```

`writerStreaming` 调用 `w.file.writeStreaming(io, header, data, splat)`
（底层 `write` 系统调用），使用 OS 文件描述符的当前偏移，不依赖 `w.pos`。
`flush` 触发 `defaultFlush` → `drainStreaming` → `file.writeStreaming`，
将 `write_writer_buf` 中的缓存数据写入文件。

### 学到的东西

- **`f.writer()` 与 `f.writerStreaming()` 的差异**：
  - `writer()` — positional mode，使用 `pwrite(fd, ..., pos)`，
    维护独立偏移 `w.pos`。多线程安全，因为不依赖共享的 OS 文件偏移。
    但如果 writer 被重建，pos 丢失。
  - `writerStreaming()` — streaming mode，使用 `write(fd, ...)`，
    依赖 OS 文件描述符偏移。writer 重建不影响写入位置（因为 OS 偏移持续存在）。
  - 对于跨多次调用的操作（如分 chunk 写入），streaming 更合适。

- **`Io.Writer` 的缓冲机制**：Writer 内部有一个 buffer（通过
  `initInterface` 设置）。`write` 在小数据时仅缓存（memcpy + end 递增），
  大数据或 `flush` 时调用 `drain`。这是性能优化——聚合小写为一次系统调用。
  但 writer 离开作用域时**不会自动 drain**，必须显式 `flush`。
  这是 Zig 标准库的设计选择：不引入隐式开销（deinit/flush 对性能敏感场景
  是负担），由调用者管理。

- **`defaultFlush` 的实现细节**：
  ```zig
  pub fn defaultFlush(w: *Writer) Error!void {
      while (w.end != 0) _ = try drainFn(w, &.{""}, 1);
  }
  ```
  循环调用 `drain`，传入空的 data 数组和 splat=1。drain 会从 `w.buffer`
  中取 `header` 写入，直到 `w.end == 0`。

---

## 3. WriteFile: pending_path 借用生命周期

### 症状

`write` 命令执行后文件未被创建，无报错但返回 "Write completed"。

### 根因分析过程

`Command.preprocess_0` 服务端代码（`.write` 分支）：

```zig
.write => |v| {
    s.pending_path = v.data.path;    // ①
    s.write_error = false;
    s.write_file = null;
},
```

`v.data.path` 是从解码器 buffer **借用的切片**。在
`preprocess_0` 返回后，状态机从 `Command` 转换到 `WriteFile`。

然后 `WriteFile.preprocess_0` 被调用来处理第一个 `.chunk` 消息——但在
此之前，服务端执行了 `mult_channel.recv` 来接收 `.chunk`，这个 `recv`
**复用了解码器的内部 buffer**。因此当 `WriteFile.preprocess_0` 执行时：

```zig
const f = s.root_dir.createFile(io_, s.pending_path, .{}) catch { ... };
```

`s.pending_path` 已经指向 `.chunk` 消息内容（或部分 buffer 元数据），
不再是原始的文件路径。`createFile` 使用垃圾路径，必然失败。
`s.write_error = true`，但没有进一步报错暴露给用户。

**为什么 ReadFile 不受影响？** 对于 `read` 命令，状态转换后
`ReadFile.process` 在服务端作为 **sender** 运行。sender 不调 `recv`，
直接 `process` 并发送结果。`pending_path` 的借用从 `Command.preprocess_0`
到 `ReadFile.process` 之间没有中间 `recv`，因此 buffer 有效。

**为什么 write 命令返回 "Write completed" 而非错误？**
`s.write_error = true` 被设置。在 `WriteDone.process` 中：

```zig
if (s.write_file) |f| {     // write_file 为 null，跳过
    f.sync(io_) catch {};
    f.close(io_);
}
if (s.write_error) {
    s.root_dir.deleteFile(io_, s.pending_path) catch {};
    return .{ .result = .{ .data = .{ .ok = false, ... } } };
}
return .{ .result = .{ .data = .{ .ok = true, ... } } };
```

`createFile` 失败 → `break :blk null` → `file = null` → `if (file) |f|`
跳过 → `s.write_file` 保持 null。`WriteDone.process` 中
`s.write_file` 为 null（跳过 sync/close）。然后检查 `s.write_error`
——但等一下，`write_error` 被设置了，应该返回错误才对！

这里其实有一个连锁问题：第一个 `.chunk` 的 `write_error = true`，
但后续的每个 `.chunk` 都会尝试 `createFile`（因为 `s.write_file` 为
null），每次都失败并设置 `write_error = true`。最后 `WriteDone.process`
检查 `write_error` → true → 返回 error result。

但是……`pending_path` 在 `WriteDone.process` 的 `deleteFile` 调用中
也是垃圾，`deleteFile` 也会静默失败（catch {}）。

既然 write_error 最终被检查并返回了 error，理论上客户端应该看到
"Write failed"。但如果用户看到的是无反馈……可能还有其他因素。
无论如何，根因是 `pending_path` 的借用被 `recv` 破坏。

### 修复

```zig
.write => |v| {
    s.pending_path = try s.allocator.dupe(u8, v.data.path);
    s.pending_free = s.pending_path;
    s.write_error = false;
    s.write_file = null;
},
```

通过 `s.allocator.dupe` 分配一个独立的堆拷贝，`pending_free` 机制在
下一个命令到达时自动释放。这消除了对解码器 buffer 的生命周期依赖。

### 学到的东西

- **Troupe 消息中的 borrow 生命周期受限于 protocol handler 当前调用**：
  `v.data` 中的切片是对接收 buffer 的借用。`preprocess_0` 返回后、
  下一次 `recv` 之前 buffer 有效，但跨 `recv` 调用后会失效。

- **Sender vs Receiver 的时序差异**：在一个状态转换中：
  - Sender：`process` → `send` → 转换到新状态，同一线程内连续执行。
    中间没有 `recv`。`pending_path` 借用仍然有效。
  - Receiver：`recv`（解码消息）→ `preprocess_0` → 转换到新状态 →
    `recv`（下一消息，覆盖 buffer）→ 新状态的 handler。
    任何在第一次 `recv` 中获得的借用，在第二次 `recv` 之后失效。
    需要跨 handler 调用持久化的数据必须拷贝。

- **此模式不限于 write**：任何需要在 `preprocess_0` 中存储数据并在后续
  receiver handler 中使用的借用都需要拷贝。理论上可以做一个通用的
  路径拷贝策略（所有带路径的命令都拷贝），但项目中其他命令（list、stat、
  delete 等）的 `process` 在 sender 侧运行，不受影响。只有 write 的
  receiver handler 需要这个修复。

---

## 4. readLine: 栈上缓冲区导致返回后悬空指针

### 症状

`write` 命令报 `Cannot open local file: error.FileNotFound`，即使文件确实存在。
`read`、`list` 等所有命令也可能出现偶发的路径/参数解析错误。

### 根因分析过程

`readLine` 函数是后期添加的 raw-mode 行编辑器：

```zig
fn readLine(c: *ClientContext) !?[]const u8 {
    const stdin_fd = std.posix.STDIN_FILENO;
    var rt = try RawTerminal.enable(stdin_fd);
    defer rt.disable();

    var line_buf: [4096]u8 = undefined;   // ← 栈上分配
    var pos: usize = 0;

    // ... 收集字符到 line_buf ...

    const line = line_buf[0..pos];
    return line;                           // ← 返回指向栈的切片
}
```

**问题**：`line_buf` 是 `readLine` 的局部变量，在栈上分配。当函数返回时，
栈帧弹出，`line_buf` 占用的内存不再有效。但返回的切片 `line_buf[0..pos]`
仍然指向这块已释放的栈内存。

调用方 `Command.process` 立即使用这个悬空指针：

```zig
const line = readLine(c) catch ...;
const trimmed = std.mem.trim(u8, line, " \t\r\n");
// trimmed 指向已释放的栈内存，此时可能还未被覆写，
// 所以命令解析通常"碰巧正确"。

// ... 随着后续函数调用，栈被反复使用和覆写 ...
const local_file = cwd.openFile(c.io, parts[1], .{}) catch |err| {
    // parts[1] 是从 trimmed 派生的子切片，
    // 此时栈内存已被覆写，内容随机
    // → FileNotFound ✓
};
```

**为什么错误表现为 FileNotFound 而非崩溃？**

C 和 Zig 的栈内存被释放后不会立即清零或被保护。在 `readLine` 返回后
`Command.process` 的 `while` 循环体中的其他函数调用会复用这片栈空间。
随着代码逐步深入到 `openFile` 调用链，栈被多轮函数调用覆写，
`parts[1]` 指向的内容随时间推移逐渐变成垃圾。最终 `openFile` 收到的
路径是无效字符串，操作系统返回 `ENOENT`。

这种 bug 的特征：
- 在简单/短路径下可能"碰巧正确"（栈覆写得慢或未触及那片区域）
- 在复杂操作（如 write 需要多步处理）时稳定复现
- 调试困难，因为打印日志本身也会改变栈布局（Heisenbug）

**和原始代码的对比**：

原始代码使用 `c.stdin_reader.takeDelimiter('\n')`，返回的切片指向
reader 的内部 buffer（即 `c.line_buf`，ClientContext 的字段），
位于堆/全局内存中，不会因函数返回而失效。

引入 `readLine` 时保留了局部 buffer 的写法，未注意到返回值的生命周期
从"借用 reader 内部 buffer"变成了"借用栈内存"。

### 修复

```zig
fn readLine(c: *ClientContext) !?[]const u8 {
    // ...
    var pos: usize = 0;
    var line_buf = &c.line_buf;   // 指向上下文字段，而非栈局部变量
    // ...
}
```

使用 `c.line_buf`（`ClientContext` 的字段，生命周期与上下文相同）
替代局部 `[4096]u8`。返回的切片指向持久内存，调用方可以安全使用。

### 学到的东西

- **Zig 不阻止返回栈切片**：Zig 没有借用检查器（如 Rust 的 lifetime），
  返回局部变量的切片是合法语法，编译器不会报错。这需要开发者自己追踪
  返回值的生命周期。

- **栈覆写的时间窗口**：悬空指针不一定立即崩溃。从函数返回到悬空内存被
  覆写之间存在时间窗口。简单操作（如比较字符串）可能碰巧正确，复杂操作
  （如系统调用、多层函数调用）更容易触发覆写。

- **区分"借用返回"和"拥有返回"**：
  - 借用返回（如 `reader.takeDelimiter`）：数据在调用者的 buffer 中，
    返回的切片受调用者生命周期约束
  - 拥有返回（如 `allocator.dupe`）：数据在堆上，调用者负责释放
  - 当把借用返回替换为自定义实现时，必须确保新实现的生命周期兼容

---

## 5. ReadFile: 静默失败，无错误信息

### 症状

`read` 不存在的文件时，客户端没有任何输出，安静地回到 `fm>` 提示符。

### 根因分析过程

`ReadFile.process` 服务端代码在 `openFile` 失败时：

```zig
const f = s.root_dir.openFile(io_, s.pending_path, .{}) catch
    return .{ .done = .{ .data = {} } };   // void，无法传错误
```

`ReadFile` 的 `done` 变体使用 `Data(void, Command)`，只能表示"完成"，
无法区分成功和失败。客户端 `preprocess_0(.done)` 为空操作 `{}`，
即使收到 done 也不会产生任何输出。

### 修复

将 `ReadFile.done` 从 `Data(void, Command)` 改为 `Data([]const u8, Command)`：

```zig
pub const ReadFile = union(enum) {
    chunk: Data([]const u8, @This()),
    /// done.data == "" → success; non‑empty → error message
    done:  Data([]const u8, Command),
};
```

服务端：
- 成功 → `return .{ .done = .{ .data = "" } };`
- 失败 → `return .{ .done = .{ .data = @errorName(err) } };`

客户端：
```zig
.done => |v| {
    if (v.data.len > 0) {
        try c.stdout_writer.print("\nRead error: {s}\n", .{v.data});
        try c.stdout_writer.flush();
    }
},
```

### 学到的东西

- **协议设计中的错误通道**：流式协议（chunk → done）必须在设计之初就
  考虑错误路径。使用 `void` 作为终止信号意味着"成功"，但错误无法传达。
  简单的改进是让终止信号携带结果信息（空串=成功，非空=错误），或者
  显式添加 `error` 变体。

- **状态机状态与业务语义的映射**：Troupe 的每个状态是一个 union，
  每个变体是一次状态转换。当某个变体只能表达"发生"而不能表达"结果"时，
  考虑用丰富的数据类型（`[]const u8`、`OpResult` 等）携带结果信息。

---

## 6. pending_path 统一复制与 ?[]const u8

### 症状

服务端首次 `preprocess_0` 时 `s.pending_resp` free 野指针 → segfault。

### 根因分析

最初设计是混合的：部分命令（list/read/delete/stat/mkdir）从 recv buffer
借用 `pending_path`，只有 write 用 `dupe` 复制。借用的生命周期依赖于
 sender/receiver 时序——sender 侧的 `process` 在 `preprocess_0` 之后
立即执行，中间没有 `recv`，buffer 有效。receiver 侧（write）跨 `recv`
所以必须复制。

这种"看情况"的设计隐藏着一条隐式规则：**sender 侧可借用，receiver 侧必须拥有**。
每次加新命令都得判断自己是 sender 还是 receiver。

后来改为**统一复制**——所有命令都用 `dupe`，并引入 `pending_free` 跟踪。
再后来将 `pending_path` 改为 `?[]const u8 = null`，在 `preprocess_0` 入口
统一释放旧值。

但引入了 `pending_resp` 字段来跟踪 ListDir 的响应分配，它的默认值 `null`
在 struct 初始化时**未被正确施加**，导致首次 `preprocess_0` 中
`free(pending_resp)` 释放野指针 → segfault。

### 修复

移除 `pending_resp`，将 ListDir 的响应数据存入 `ServerContext.listing`
（`ArrayListUnmanaged(u8)`，Context 字段），`resp.data = s.listing.items`
是对 Context 的借用，不需要跨函数释放。下一个 `ListDir.process` 开头
`clearRetainingCapacity()` 复用容量。

### 学到的东西

- **?T 的默认值可能不会被正确施加**： struct 字段级默认值在某些上下文中
  可能不生效。特别是 `?[]const u8 = null` —— 如果初始化路径不完整，
  字段中的 `Optional` 的 tag 位可能随机。显式初始化为 `null` 永远安全。

- **避免跨函数所有权**： 如果数据只要存活到被序列化发送，且序列化发生在
  `process` 返回之后，那么数据必须在 `process` 返回后继续存活。
  这导致"process 分配、下个 preprocess_0 释放"的跨函数链。
  更好的做法：数据存在 Context 字段中，`process` 返回它的借用。
  Context 的生命周期 ≡ 连接生命周期，无需额外管理。

- **`ArrayListUnmanaged.deinit` 设置 `self.* = undefined`**：
  Zig 的 `ArrayListUnmanaged.deinit` 释放 backing buffer 后不会将
  `items` 置空，而是设为 `undefined`。这意味着 deinit 后读取 `items` 是
  **未定义行为**，可能导致 GPF。如果需要 deinit 后安全使用，必须手动
  重新赋值 `.empty`。

---

## 7. 协议内的 Cleanup 状态

### 症状

清理代码散落在 `fm_client.zig`、`fm_server.zig` 和 `Command.process` 中，
且 exit 路径和 error 路径各有不同的清理覆盖范围——exit 路径清理了但
error 路径没有，导致内存泄漏或双释放。

### 根因分析

资源清理（history、upload_data、pending_path、listing、reader、write_file）
本应统一在协议结束时执行，但被分布在三个位置：

1. `Command.process` 的 exit/error 分支 — 清理 history
2. `fm_client.zig` 的 `runProtocol` 之后 — 清理 history + upload_data
3. `fm_server.zig` 的 `runProtocol` 之后 — 清理 pending_path + listing

这种分布式的清理难以验证完整性。当 `runProtocol` 通过 error 退出时（如
socket 断开），`Command.process` 内部的清理代码根本没有机会执行，
泄漏检测器就会报告 `dupe` 分配的泄漏。

### 修复

添加 `Cleanup` 状态，作为 `exit` 后的必经状态：

```zig
pub const Cleanup = union(enum) {
    done: Data(void, Success),
    pub fn process(cctx) !@This() {
        // free history, upload_data
    }
    pub fn preprocess_0(sctx, msg) !void {
        // free pending_path, listing, close reader/write_file
    }
};
```

Cleanup 是协议的一部分——无论干净 exit 还是 stdin error 导致的 exit，
都会经过它。手动清理代码从 `fm_client.zig` 和 `fm_server.zig` 中移除。

### 学到的东西

- **Troupe 状态机是天然的"finally"块**： 每个协议退出必经 Cleanup 状态。
  与其在协议外靠 caller 手动清理，不如在协议内加一个清理状态。
- **框架不承诺异常安全**： `runProtocol` 内部的 error 传播会跳过中间
  状态的清理代码。Cleanup 是状态机的一部分，即使从中间状态 error 退出，
  只要 runner 能走到 Cleanup 状态，清理就会执行。

---

## 8. 聊天协议：并发双协议 vs 轮询交替

### 问题

聊天需要 client 和 server 互不等待地发消息——client 随时打字，server
随时推送。Troupe 的每状态单一 sender 模型无法直接描述这种双向异步通信。

### 尝试过的方案

1. **交替轮询**（ChatSend → ChatRecv → ChatSend → ...）：
   client 如需发消息，必须等待 ChatSend→ChatRecv→ChatSend 一次来回。
   每条消息最少 2 次网络往返，延迟大，且接收消息需要主动 poll。

2. **方向反转状态**（WriteDone 模式）：
   对单次操作有效（上传→确认），但对持续的双向流无效——每次反转只有
   one message。

3. **并发双协议 + Mux**（最终方案）：
   两个独立的 Troupe 协议在同一个 TCP 连接上并行运行，由 `MuxStream`
   层做消息分路：

   ```
   TCP Reader → Demux Fiber ─→ Mvar[tag=1] → ClientPush.recv
                             ─→ Mvar[tag=2] → ServerPush.recv

   ClientPush.send → [tag:4][len:4][codec_data] → TCP Writer
   ServerPush.send → [tag:4][len:4][codec_data] → TCP Writer
   ```

   每个协议是纯单向的（client→server 或 server→client），互不阻塞。

### 学到的东西

- **Troupe 不适合直接描述双向异步流**： 单一 sender 模型要求每次通信
  明确指定谁发谁收。双方可随时发消息的场景需要一个**通道复用层**
  来模拟并发。
- **协议拆分为单向子协议**： 将"双向随时通信"拆成两个"单向恒通信"，
  各管各的方向，通过底层多路复用共享连接。Mux 层处理 tag 分路，
  双方各跑两个 Runner 实例。
- **`@fieldParentPtr` 不可复制**： `Io.Reader` 和 `Io.Writer` 是
  通过 `@fieldParentPtr` 从嵌入的 `Io.Reader` 指针恢复外层 struct 的。
  复制 `Io.Reader` 值（`var r = mux.reader.*`）会破坏这个指针关系，
  导致访问非法内存。必须始终使用原始指针。

---

## 9. 设计模式总结

### pending_path 生命周期演化

| 阶段 | pending_path 类型 | 分配策略 | 释放机制 | 评价 |
|------|------------------|----------|----------|------|
| 原始 | `[]const u8 = ""` | 借用 | 不释放 | 依赖时序，脆弱 |
| 混合 | `[]const u8 = ""` | write dupe，其余借用 | pending_free | 规则隐晦 |
| 统一复制 | `[]const u8 = ""` | 全部 dupe | pending_free | pending_free 双字段冗余 |
| 最终 | `?[]const u8 = null` | 全部 dupe | preprocess_0 入口 free | 单一表达，显式 null |

### 资源清理演化

| 阶段 | 清理方式 | 问题 |
|------|----------|------|
| 外部清理 | `fm_*.zig` 手动 free | 散落三处，error 路径遗漏 |
| 分散清理 | Command.process + fm_*.zig | 双释放（deinit → undefined） |
| 协议内清理 | Cleanup 状态 | 统一，自动，不论 exit 还是 error |

### 跨函数所有权

| 方案 | 数据存储 | process 返回 | 释放 | 示例 |
|------|----------|-------------|------|------|
| process 分配，下个 handler 释放 | 堆 | `return .{ .data = owned }` | 下个 preprocess_0 | 初期 pending_free |
| Context 字段 | Context | `return .{ .data = &ctx.field }` | 无需释放 | listing |
| 避免 | 堆，process 末尾释放 | 空借用 | 无 | 无 |

核心原则：**数据应活在生命周期最接近其使用范围的地方**。跨函数的所有权
传递是最难验证正确的模式。

---

## 总结

| Bug | 症状 | 根因分类 | 修复策略 |
|-----|------|----------|----------|
| ReadFile aliasing | 文件内容缺失+错位 | Buffer 别名违规 | 分离缓冲区，持久化 reader |
| WriteFile position | 文件仅最后 chunk | writer 模式选择错误 + 缓存未刷 | writerStreaming + 显式 flush |
| WriteFile lifetime | 文件未创建 | 借用生命周期 | dupe 路径 |
| readLine use-after-return | FileNotFound 误报 | 栈切片生命周期 | 使用上下文字段替代局部 buffer |
| ReadFile silent fail | read 失败无输出 | 协议缺少错误通道 | done 携带 `[]const u8` 错误消息 |
| pending_resp segfault | 服务端首次 preprocess_0 崩溃 | `?T` 默认值未正确施加 + 跨函数所有权 | Context 字段替代堆分配，统一 `?[]const u8 null` |
| 分布式清理 | exit 后双释放/泄漏 | Cleanup 散落三处 + ArrayListUnmanaged.deinit = undefined | 协议内 Cleanup 状态 |
| 聊天双向通信 | 无法用单一 sender 模型描述 | Troupe 每状态单 sender | 并发双协议 + MuxStream 分路 |

**八条教训**：

1. **Buffer aliasing** — 标准库函数对参数独立性的隐含约束需要在文档中
   特别留意。传同一块内存到两个参数时检查实现是否会内部混用。

2. **Writer 不是 RAII** — Zig 结构体没有析构函数。Writer 的缓存数据不会
   在离开作用域时自动刷出。必须显式管理 `flush`/`deinit`。

3. **借用生命周期跨 handler 无效** — Troupe 的消息数据借用在同一个
   protocol handler 调用内有效，跨 `recv` 后会失效。
   需要跨 `preprocess_0` → 后续 `recv` → 后续 handler 的数据必须提前拷贝。

4. **Zig 不阻止返回栈切片** — 返回局部变量的切片是有效语法，编译器不报错。
   开发者需要对返回值的生命周期负责。替换一个"借用返回"函数时，新实现
   的生命周期必须与原实现兼容。

5. **协议的错误通道必须显式设计** — 流式协议使用 `void` 终止信号意味着
   "成功"，错误⽆法传达。终止信号应携带结果信息（空串/非空串），或显式
   添加错误变体。

6. **`?T` 默认值可能不被施加** — struct 字段的 `?[]const u8 = null` 默认值
   在某些初始化路径下可能未生效。依赖默认值的 Optional 类型字段应显式赋
   值 `null`，特别是在分离编译的模块边界。

7. **`ArrayListUnmanaged.deinit` 遗留 `undefined`** — deinit 不会将
   `items` 置空，读取 deinit 后的 items 是 UB。
   如需 deinit 后安全读取，手动赋值 `= .empty`。

8. **跨函数所有权是最脆弱的模式** — process 分配、下个 handler 释放隐藏着
   生命周期假设，容易遗忘或弄错。数据存在 Context 字段中返回借用更安全。
   Troupe 状态机可以充当"finally 块"——Cleanup 状态确保协议退出时资源
   统一清理。

---

*记录于 2026-05-08，基于 Troupe project（Zig 0.17.0-dev）的调试过程。*
