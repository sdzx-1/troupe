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

## 总结

| Bug | 症状 | 根因分类 | 修复策略 |
|-----|------|----------|----------|
| ReadFile aliasing | 文件内容缺失+错位 | Buffer 别名违规 | 分离缓冲区，持久化 reader |
| WriteFile position | 文件仅最后 chunk | writer 模式选择错误 + 缓存未刷 | writerStreaming + 显式 flush |
| WriteFile lifetime | 文件未创建 | 借用生命周期 | dupe 路径 |

**三条教训**：

1. **Buffer aliasing** — 标准库函数对参数独立性的隐含约束需要在文档中
   特别留意。传同一块内存到两个参数时检查实现是否会内部混用。
2. **Writer 不是 RAII** — Zig 结构体没有析构函数。Writer 的缓存数据不会
   在离开作用域时自动刷出。必须显式管理 `flush`/`deinit`。
3. **借用生命周期跨 handler 无效** — Troupe 的消息数据借用在同一个
   protocol handler 调用内有效，跨 `recv` 后会失效。
   需要跨 `preprocess_0` → 后续 `recv` → 后续 handler 的数据必须提前拷贝。

---

*记录于 2026-05-08，基于 Troupe project（Zig 0.17.0-dev）的调试过程。*
