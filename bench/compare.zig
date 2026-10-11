const std = @import("std");
const justinhj = @import("zig_msgpack");
const zigcc = @import("zigcc_msgpack");

// zigcc types and aliases
const zigcc_compat = zigcc.compat;
const zigcc_Payload = zigcc.Payload;
const zigcc_bufferType = zigcc_compat.BufferStream;
const zigcc_fixedBufferStream = zigcc_compat.fixedBufferStream;

const zigcc_pack = zigcc.Pack(
    *zigcc_bufferType,
    *zigcc_bufferType,
    zigcc_bufferType.WriteError,
    zigcc_bufferType.ReadError,
    zigcc_bufferType.write,
    zigcc_bufferType.read,
);

// justinhj helper writer for stack/fixed buffers
pub const FixedBufferWriter = struct {
    buffer: []u8,
    pos: usize = 0,

    pub fn init(buffer: []u8) FixedBufferWriter {
        return .{ .buffer = buffer, .pos = 0 };
    }

    pub fn writeByte(self: *FixedBufferWriter, byte: u8) !void {
        if (self.pos >= self.buffer.len) return error.NoSpaceLeft;
        self.buffer[self.pos] = byte;
        std.mem.doNotOptimizeAway(&self.buffer[self.pos]);
        self.pos += 1;
    }

    pub fn writeAll(self: *FixedBufferWriter, bytes: []const u8) !void {
        if (self.pos + bytes.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
        std.mem.doNotOptimizeAway(self.buffer[self.pos .. self.pos + bytes.len].ptr);
        self.pos += bytes.len;
    }

    pub fn reset(self: *FixedBufferWriter) void {
        self.pos = 0;
    }

    pub fn finish(self: *FixedBufferWriter) void {
        std.mem.doNotOptimizeAway(self.buffer[0..self.pos]);
    }

    pub fn getWritten(self: *const FixedBufferWriter) []const u8 {
        return self.buffer[0..self.pos];
    }
};

const BenchRuntime = struct {
    var io: ?std.Io = null;
};

fn getTimeNs() u64 {
    const io = BenchRuntime.io orelse @panic("BenchRuntime.io is not initialized");
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn timedRun(
    comptime iterations: usize,
    comptime func: fn (allocator: std.mem.Allocator) anyerror!void,
) !f64 {
    const allocator = std.heap.smp_allocator;

    // 10 warmup iterations
    for (0..10) |_| {
        try func(allocator);
    }

    const start_ns = getTimeNs();
    for (0..iterations) |_| {
        try func(allocator);
    }
    const elapsed_ns = getTimeNs() - start_ns;
    return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
}

fn compareBenchmark(
    comptime name: []const u8,
    comptime iterations: usize,
    comptime zigcc_fn: fn (allocator: std.mem.Allocator) anyerror!void,
    comptime justin_fn: fn (allocator: std.mem.Allocator) anyerror!void,
) !void {
    const zigcc_ns = try timedRun(iterations, zigcc_fn);
    const justin_ns = try timedRun(iterations, justin_fn);

    var diff_buf: [32]u8 = undefined;
    const diff_str = if (@abs(zigcc_ns - justin_ns) < 0.2)
        "equal"
    else if (justin_ns < zigcc_ns)
        std.fmt.bufPrint(&diff_buf, "{d:.2}x faster", .{zigcc_ns / @max(justin_ns, 0.001)}) catch "faster"
    else
        std.fmt.bufPrint(&diff_buf, "{d:.2}x slower", .{justin_ns / @max(zigcc_ns, 0.001)}) catch "slower";

    std.debug.print(
        "{s:35} | {d:7} | {d:7.2} ns/op | {d:7.2} ns/op | {s:13}\n",
        .{ name, iterations, zigcc_ns, justin_ns, diff_str },
    );
}

// ============================================================================
// 1. Basic Types: Nil, Bool, Small Int, Large Int, Float
// ============================================================================

// Nil
fn zigcc_NilWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    try p.write(zigcc_Payload.nilToPayload());
}

fn justin_NilWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packNil(&w);
}

fn zigcc_NilRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        try p.write(zigcc_Payload.nilToPayload());
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_NilRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packNil(&w);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// Bool
fn zigcc_BoolWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    try p.write(zigcc_Payload.boolToPayload(true));
}

fn justin_BoolWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packBool(&w, true);
}

fn zigcc_BoolRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        try p.write(zigcc_Payload.boolToPayload(true));
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_BoolRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packBool(&w, true);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// Small Int
fn zigcc_SmallIntWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    try p.write(zigcc_Payload.intToPayload(42));
}

fn justin_SmallIntWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packInt(&w, @as(i64, 42));
}

fn zigcc_SmallIntRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        try p.write(zigcc_Payload.intToPayload(42));
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_SmallIntRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packInt(&w, @as(i64, 42));
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// Large Int
fn zigcc_LargeIntWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    try p.write(zigcc_Payload.intToPayload(1234567890123456789));
}

fn justin_LargeIntWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packInt(&w, @as(i64, 1234567890123456789));
}

fn zigcc_LargeIntRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        try p.write(zigcc_Payload.intToPayload(1234567890123456789));
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_LargeIntRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packInt(&w, @as(i64, 1234567890123456789));
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// Float
fn zigcc_FloatWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    try p.write(zigcc_Payload.floatToPayload(3.14159265359));
}

fn justin_FloatWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packFloat64(&w, 3.14159265359);
}

fn zigcc_FloatRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        try p.write(zigcc_Payload.floatToPayload(3.14159265359));
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_FloatRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packFloat64(&w, 3.14159265359);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// ============================================================================
// 2. Strings: Short (5B), Medium (~300B)
// ============================================================================

fn zigcc_ShortStrWrite(allocator: std.mem.Allocator) !void {
    var arr: [100]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    const s = try zigcc_Payload.strToPayload("hello", allocator);
    defer s.free(allocator);
    try p.write(s);
}

fn justin_ShortStrWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packString(&w, "hello");
}

fn zigcc_ShortStrRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        const s = try zigcc_Payload.strToPayload("hello", allocator);
        defer s.free(allocator);
        try p.write(s);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_ShortStrRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packString(&w, "hello");
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

const medium_str_sample: [300]u8 = @splat('a');

fn zigcc_MediumStrWrite(allocator: std.mem.Allocator) !void {
    var arr: [1000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    const s = try zigcc_Payload.strToPayload(&medium_str_sample, allocator);
    defer s.free(allocator);
    try p.write(s);
}

fn justin_MediumStrWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packString(&w, &medium_str_sample);
}

fn zigcc_MediumStrRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        const s = try zigcc_Payload.strToPayload(&medium_str_sample, allocator);
        defer s.free(allocator);
        try p.write(s);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_MediumStrRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packString(&w, &medium_str_sample);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// ============================================================================
// 3. Binary Data: Small (32B), Large (1KB)
// ============================================================================

const bin32_sample: [32]u8 = @splat(42);
const bin1k_sample: [1024]u8 = @splat(42);

fn zigcc_SmallBinWrite(allocator: std.mem.Allocator) !void {
    var arr: [100]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    const b = try zigcc_Payload.binToPayload(&bin32_sample, allocator);
    defer b.free(allocator);
    try p.write(b);
}

fn justin_SmallBinWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [100]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packBinary(&w, &bin32_sample);
}

fn zigcc_SmallBinRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        const b = try zigcc_Payload.binToPayload(&bin32_sample, allocator);
        defer b.free(allocator);
        try p.write(b);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_SmallBinRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [100]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packBinary(&w, &bin32_sample);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

fn zigcc_LargeBinWrite(allocator: std.mem.Allocator) !void {
    var arr: [2000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    const b = try zigcc_Payload.binToPayload(&bin1k_sample, allocator);
    defer b.free(allocator);
    try p.write(b);
}

fn justin_LargeBinWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [2000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packBinary(&w, &bin1k_sample);
}

fn zigcc_LargeBinRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [2000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        const b = try zigcc_Payload.binToPayload(&bin1k_sample, allocator);
        defer b.free(allocator);
        try p.write(b);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_LargeBinRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [2000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packBinary(&w, &bin1k_sample);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// ============================================================================
// 4. Arrays: Small (10 elements), Medium (100 elements)
// ============================================================================

fn zigcc_SmallArrayWrite(allocator: std.mem.Allocator) !void {
    var arr: [1000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    var a = try zigcc_Payload.arrPayload(10, allocator);
    defer a.free(allocator);
    for (0..10) |i| {
        try a.setArrElement(i, zigcc_Payload.intToPayload(@intCast(i)));
    }
    try p.write(a);
}

fn justin_SmallArrayWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packArrayHeader(&w, 10);
    for (0..10) |i| {
        try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
    }
}

fn zigcc_SmallArrayRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        var a = try zigcc_Payload.arrPayload(10, allocator);
        defer a.free(allocator);
        for (0..10) |i| {
            try a.setArrElement(i, zigcc_Payload.intToPayload(@intCast(i)));
        }
        try p.write(a);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_SmallArrayRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packArrayHeader(&w, 10);
        for (0..10) |i| {
            try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
        }
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

fn zigcc_MediumArrayWrite(allocator: std.mem.Allocator) !void {
    var arr: [5000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    var a = try zigcc_Payload.arrPayload(100, allocator);
    defer a.free(allocator);
    for (0..100) |i| {
        try a.setArrElement(i, zigcc_Payload.intToPayload(@intCast(i)));
    }
    try p.write(a);
}

fn justin_MediumArrayWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [5000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packArrayHeader(&w, 100);
    for (0..100) |i| {
        try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
    }
}

fn zigcc_MediumArrayRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [5000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        var a = try zigcc_Payload.arrPayload(100, allocator);
        defer a.free(allocator);
        for (0..100) |i| {
            try a.setArrElement(i, zigcc_Payload.intToPayload(@intCast(i)));
        }
        try p.write(a);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_MediumArrayRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [5000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packArrayHeader(&w, 100);
        for (0..100) |i| {
            try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
        }
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// ============================================================================
// 5. Maps: Small (10 entries), Medium (50 entries)
// ============================================================================

fn zigcc_SmallMapWrite(allocator: std.mem.Allocator) !void {
    var arr: [1000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    var m = zigcc_Payload.mapPayload(allocator);
    defer m.free(allocator);
    for (0..10) |i| {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try m.mapPut(key, zigcc_Payload.intToPayload(@intCast(i)));
    }
    try p.write(m);
}

fn justin_SmallMapWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packMapHeader(&w, 10);
    for (0..10) |i| {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try justinhj.packer.packString(&w, key);
        try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
    }
}

fn zigcc_SmallMapRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        var m = zigcc_Payload.mapPayload(allocator);
        defer m.free(allocator);
        for (0..10) |i| {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            try m.mapPut(key, zigcc_Payload.intToPayload(@intCast(i)));
        }
        try p.write(m);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_SmallMapRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packMapHeader(&w, 10);
        for (0..10) |i| {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            try justinhj.packer.packString(&w, key);
            try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
        }
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

fn zigcc_MediumMapWrite(allocator: std.mem.Allocator) !void {
    var arr: [5000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    var m = zigcc_Payload.mapPayload(allocator);
    defer m.free(allocator);
    for (0..50) |i| {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try m.mapPut(key, zigcc_Payload.intToPayload(@intCast(i)));
    }
    try p.write(m);
}

fn justin_MediumMapWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [5000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packMapHeader(&w, 50);
    for (0..50) |i| {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
        try justinhj.packer.packString(&w, key);
        try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
    }
}

fn zigcc_MediumMapRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [5000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        var m = zigcc_Payload.mapPayload(allocator);
        defer m.free(allocator);
        for (0..50) |i| {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            try m.mapPut(key, zigcc_Payload.intToPayload(@intCast(i)));
        }
        try p.write(m);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_MediumMapRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [5000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packMapHeader(&w, 50);
        for (0..50) |i| {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            try justinhj.packer.packString(&w, key);
            try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
        }
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// ============================================================================
// 6. Extension Types: type 42, 16 bytes
// ============================================================================

const ext_sample: [16]u8 = @splat(1);

fn zigcc_ExtWrite(allocator: std.mem.Allocator) !void {
    var arr: [1000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    const ext = try zigcc_Payload.extToPayload(42, &ext_sample, allocator);
    defer ext.free(allocator);
    try p.write(ext);
}

fn justin_ExtWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    try justinhj.packer.packExt(&w, 42, &ext_sample);
}

fn zigcc_ExtRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        const ext = try zigcc_Payload.extToPayload(42, &ext_sample, allocator);
        defer ext.free(allocator);
        try p.write(ext);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_ExtRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packExt(&w, 42, &ext_sample);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// ============================================================================
// 7. Timestamps: timestamp32, timestamp64
// ============================================================================

fn zigcc_Timestamp32Write(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    const ts = zigcc_Payload.timestampFromSeconds(1234567890);
    try p.write(ts);
}

fn justin_Timestamp32Write(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, 1234567890, .big);
    try justinhj.packer.packExt(&w, -1, &buf);
}

fn zigcc_Timestamp32Read(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        const ts = zigcc_Payload.timestampFromSeconds(1234567890);
        try p.write(ts);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_Timestamp32Read(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, 1234567890, .big);
        try justinhj.packer.packExt(&w, -1, &buf);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

fn zigcc_Timestamp64Write(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);
    const ts = zigcc_Payload.timestampToPayload(1234567890, 123456789);
    try p.write(ts);
}

fn justin_Timestamp64Write(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [1000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);
    var buf: [8]u8 = undefined;
    const val: u64 = (@as(u64, 123456789) << 34) | @as(u64, 1234567890);
    std.mem.writeInt(u64, &buf, val, .big);
    try justinhj.packer.packExt(&w, -1, &buf);
}

fn zigcc_Timestamp64Read(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);
        const ts = zigcc_Payload.timestampToPayload(1234567890, 123456789);
        try p.write(ts);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_Timestamp64Read(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [1000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        var buf: [8]u8 = undefined;
        const val: u64 = (@as(u64, 123456789) << 34) | @as(u64, 1234567890);
        std.mem.writeInt(u64, &buf, val, .big);
        try justinhj.packer.packExt(&w, -1, &buf);
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// ============================================================================
// 8. Complex Structures: Nested Structure, Mixed Types
// ============================================================================

// Nested: {"users": [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]}
fn zigcc_NestedWrite(allocator: std.mem.Allocator) !void {
    var arr: [10000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);

    var root = zigcc_Payload.mapPayload(allocator);
    defer root.free(allocator);

    var users = try zigcc_Payload.arrPayload(2, allocator);
    var user1 = zigcc_Payload.mapPayload(allocator);
    try user1.mapPut("id", zigcc_Payload.intToPayload(1));
    try user1.mapPut("name", try zigcc_Payload.strToPayload("Alice", allocator));
    try users.setArrElement(0, user1);

    var user2 = zigcc_Payload.mapPayload(allocator);
    try user2.mapPut("id", zigcc_Payload.intToPayload(2));
    try user2.mapPut("name", try zigcc_Payload.strToPayload("Bob", allocator));
    try users.setArrElement(1, user2);

    try root.mapPut("users", users);
    try p.write(root);
}

fn justin_NestedWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [10000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);

    try justinhj.packer.packMapHeader(&w, 1);
    try justinhj.packer.packString(&w, "users");
    try justinhj.packer.packArrayHeader(&w, 2);

    // user 1
    try justinhj.packer.packMapHeader(&w, 2);
    try justinhj.packer.packString(&w, "id");
    try justinhj.packer.packInt(&w, @as(i64, 1));
    try justinhj.packer.packString(&w, "name");
    try justinhj.packer.packString(&w, "Alice");

    // user 2
    try justinhj.packer.packMapHeader(&w, 2);
    try justinhj.packer.packString(&w, "id");
    try justinhj.packer.packInt(&w, @as(i64, 2));
    try justinhj.packer.packString(&w, "name");
    try justinhj.packer.packString(&w, "Bob");
}

fn zigcc_NestedRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [10000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);

        var root = zigcc_Payload.mapPayload(allocator);
        defer root.free(allocator);
        var users = try zigcc_Payload.arrPayload(2, allocator);

        var user1 = zigcc_Payload.mapPayload(allocator);
        try user1.mapPut("id", zigcc_Payload.intToPayload(1));
        try user1.mapPut("name", try zigcc_Payload.strToPayload("Alice", allocator));
        try users.setArrElement(0, user1);

        var user2 = zigcc_Payload.mapPayload(allocator);
        try user2.mapPut("id", zigcc_Payload.intToPayload(2));
        try user2.mapPut("name", try zigcc_Payload.strToPayload("Bob", allocator));
        try users.setArrElement(1, user2);

        try root.mapPut("users", users);
        try p.write(root);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_NestedRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [10000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justin_NestedWrite(allocator);
        // serialize into State.buffer
        try justinhj.packer.packMapHeader(&w, 1);
        try justinhj.packer.packString(&w, "users");
        try justinhj.packer.packArrayHeader(&w, 2);
        try justinhj.packer.packMapHeader(&w, 2);
        try justinhj.packer.packString(&w, "id");
        try justinhj.packer.packInt(&w, @as(i64, 1));
        try justinhj.packer.packString(&w, "name");
        try justinhj.packer.packString(&w, "Alice");
        try justinhj.packer.packMapHeader(&w, 2);
        try justinhj.packer.packString(&w, "id");
        try justinhj.packer.packInt(&w, @as(i64, 2));
        try justinhj.packer.packString(&w, "name");
        try justinhj.packer.packString(&w, "Bob");
        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// Mixed: [nil, true, -100, 200u, 3.14, "hello", bin(8B), [1,2], {"key": 42}, timestamp(1000000)]
fn zigcc_MixedWrite(allocator: std.mem.Allocator) !void {
    var arr: [5000]u8 = undefined;
    var wb = zigcc_fixedBufferStream(&arr);
    var rb = zigcc_fixedBufferStream(&arr);
    var p = zigcc_pack.init(&wb, &rb);

    var mixed = try zigcc_Payload.arrPayload(10, allocator);
    defer mixed.free(allocator);

    try mixed.setArrElement(0, zigcc_Payload.nilToPayload());
    try mixed.setArrElement(1, zigcc_Payload.boolToPayload(true));
    try mixed.setArrElement(2, zigcc_Payload.intToPayload(-100));
    try mixed.setArrElement(3, zigcc_Payload.uintToPayload(200));
    try mixed.setArrElement(4, zigcc_Payload.floatToPayload(3.14));
    try mixed.setArrElement(5, try zigcc_Payload.strToPayload("hello", allocator));

    var bin_data: [8]u8 = @splat(1);
    try mixed.setArrElement(6, try zigcc_Payload.binToPayload(&bin_data, allocator));

    var inner_arr = try zigcc_Payload.arrPayload(2, allocator);
    try inner_arr.setArrElement(0, zigcc_Payload.intToPayload(1));
    try inner_arr.setArrElement(1, zigcc_Payload.intToPayload(2));
    try mixed.setArrElement(7, inner_arr);

    var inner_map = zigcc_Payload.mapPayload(allocator);
    try inner_map.mapPut("key", zigcc_Payload.intToPayload(42));
    try mixed.setArrElement(8, inner_map);

    try mixed.setArrElement(9, zigcc_Payload.timestampFromSeconds(1000000));
    try p.write(mixed);
}

fn justin_MixedWrite(allocator: std.mem.Allocator) !void {
    _ = allocator;
    var arr: [5000]u8 = undefined;
    var w = FixedBufferWriter.init(&arr);

    try justinhj.packer.packArrayHeader(&w, 10);
    try justinhj.packer.packNil(&w);
    try justinhj.packer.packBool(&w, true);
    try justinhj.packer.packInt(&w, @as(i64, -100));
    try justinhj.packer.packUInt(&w, 200);
    try justinhj.packer.packFloat64(&w, 3.14);
    try justinhj.packer.packString(&w, "hello");

    var bin_data: [8]u8 = @splat(1);
    try justinhj.packer.packBinary(&w, &bin_data);

    try justinhj.packer.packArrayHeader(&w, 2);
    try justinhj.packer.packInt(&w, @as(i64, 1));
    try justinhj.packer.packInt(&w, @as(i64, 2));

    try justinhj.packer.packMapHeader(&w, 1);
    try justinhj.packer.packString(&w, "key");
    try justinhj.packer.packInt(&w, @as(i64, 42));

    var ts_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &ts_buf, 1000000, .big);
    try justinhj.packer.packExt(&w, -1, &ts_buf);
}

fn zigcc_MixedRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [5000]u8 = @splat(0);
    };
    if (!State.initialized) {
        var wb = zigcc_fixedBufferStream(State.buffer[0..]);
        var rb = zigcc_fixedBufferStream(State.buffer[0..]);
        var p = zigcc_pack.init(&wb, &rb);

        var mixed = try zigcc_Payload.arrPayload(10, allocator);
        defer mixed.free(allocator);

        try mixed.setArrElement(0, zigcc_Payload.nilToPayload());
        try mixed.setArrElement(1, zigcc_Payload.boolToPayload(true));
        try mixed.setArrElement(2, zigcc_Payload.intToPayload(-100));
        try mixed.setArrElement(3, zigcc_Payload.uintToPayload(200));
        try mixed.setArrElement(4, zigcc_Payload.floatToPayload(3.14));
        try mixed.setArrElement(5, try zigcc_Payload.strToPayload("hello", allocator));

        var bin_data: [8]u8 = @splat(1);
        try mixed.setArrElement(6, try zigcc_Payload.binToPayload(&bin_data, allocator));

        var inner_arr = try zigcc_Payload.arrPayload(2, allocator);
        try inner_arr.setArrElement(0, zigcc_Payload.intToPayload(1));
        try inner_arr.setArrElement(1, zigcc_Payload.intToPayload(2));
        try mixed.setArrElement(7, inner_arr);

        var inner_map = zigcc_Payload.mapPayload(allocator);
        try inner_map.mapPut("key", zigcc_Payload.intToPayload(42));
        try mixed.setArrElement(8, inner_map);

        try mixed.setArrElement(9, zigcc_Payload.timestampFromSeconds(1000000));
        try p.write(mixed);
        State.initialized = true;
    }
    var wb = zigcc_fixedBufferStream(State.buffer[0..]);
    var rb = zigcc_fixedBufferStream(State.buffer[0..]);
    var p = zigcc_pack.init(&wb, &rb);
    const val = try p.read(allocator);
    defer val.free(allocator);
}

fn justin_MixedRead(allocator: std.mem.Allocator) !void {
    const State = struct {
        var initialized = false;
        var buffer: [5000]u8 = @splat(0);
        var len: usize = 0;
    };
    if (!State.initialized) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packArrayHeader(&w, 10);
        try justinhj.packer.packNil(&w);
        try justinhj.packer.packBool(&w, true);
        try justinhj.packer.packInt(&w, @as(i64, -100));
        try justinhj.packer.packUInt(&w, 200);
        try justinhj.packer.packFloat64(&w, 3.14);
        try justinhj.packer.packString(&w, "hello");

        var bin_data: [8]u8 = @splat(1);
        try justinhj.packer.packBinary(&w, &bin_data);

        try justinhj.packer.packArrayHeader(&w, 2);
        try justinhj.packer.packInt(&w, @as(i64, 1));
        try justinhj.packer.packInt(&w, @as(i64, 2));

        try justinhj.packer.packMapHeader(&w, 1);
        try justinhj.packer.packString(&w, "key");
        try justinhj.packer.packInt(&w, @as(i64, 42));

        var ts_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &ts_buf, 1000000, .big);
        try justinhj.packer.packExt(&w, -1, &ts_buf);

        State.len = w.pos;
        State.initialized = true;
    }
    const val = try justinhj.unpacker.unpack(allocator, State.buffer[0..State.len]);
    defer justinhj.types.freeObject(allocator, val);
}

// ============================================================================
// 9. Chunked-Streaming Workload (justinhj unique capability)
// ============================================================================

fn benchChunkedFeed(
    comptime chunk_step: usize,
    buffer: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var unpacker = try justinhj.unpacker.Unpacker.init(allocator, .{ .max_buffer_size = 8192 });
    defer unpacker.deinit();

    var offset: usize = 0;
    while (offset < buffer.len) {
        const step = @min(chunk_step, buffer.len - offset);
        try unpacker.feed(buffer[offset .. offset + step]);
        offset += step;
    }
    const val = try unpacker.next();
    defer justinhj.types.freeObject(allocator, val);
}

fn getPreSerializedMediumMap(allocator: std.mem.Allocator) ![]const u8 {
    const State = struct {
        var buffer: [5000]u8 = undefined;
        var len: usize = 0;
        var ready = false;
    };
    if (!State.ready) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packMapHeader(&w, 50);
        for (0..50) |i| {
            var key_buf: [16]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "key{d}", .{i}) catch unreachable;
            try justinhj.packer.packString(&w, key);
            try justinhj.packer.packInt(&w, @as(i64, @intCast(i)));
        }
        State.len = w.pos;
        State.ready = true;
    }
    _ = allocator;
    return State.buffer[0..State.len];
}

fn getPreSerializedNested(allocator: std.mem.Allocator) ![]const u8 {
    const State = struct {
        var buffer: [10000]u8 = undefined;
        var len: usize = 0;
        var ready = false;
    };
    if (!State.ready) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packMapHeader(&w, 1);
        try justinhj.packer.packString(&w, "users");
        try justinhj.packer.packArrayHeader(&w, 2);
        try justinhj.packer.packMapHeader(&w, 2);
        try justinhj.packer.packString(&w, "id");
        try justinhj.packer.packInt(&w, @as(i64, 1));
        try justinhj.packer.packString(&w, "name");
        try justinhj.packer.packString(&w, "Alice");
        try justinhj.packer.packMapHeader(&w, 2);
        try justinhj.packer.packString(&w, "id");
        try justinhj.packer.packInt(&w, @as(i64, 2));
        try justinhj.packer.packString(&w, "name");
        try justinhj.packer.packString(&w, "Bob");
        State.len = w.pos;
        State.ready = true;
    }
    _ = allocator;
    return State.buffer[0..State.len];
}

fn getPreSerializedMixed(allocator: std.mem.Allocator) ![]const u8 {
    const State = struct {
        var buffer: [5000]u8 = undefined;
        var len: usize = 0;
        var ready = false;
    };
    if (!State.ready) {
        var w = FixedBufferWriter.init(&State.buffer);
        try justinhj.packer.packArrayHeader(&w, 10);
        try justinhj.packer.packNil(&w);
        try justinhj.packer.packBool(&w, true);
        try justinhj.packer.packInt(&w, @as(i64, -100));
        try justinhj.packer.packUInt(&w, 200);
        try justinhj.packer.packFloat64(&w, 3.14);
        try justinhj.packer.packString(&w, "hello");
        var bin_data: [8]u8 = @splat(1);
        try justinhj.packer.packBinary(&w, &bin_data);
        try justinhj.packer.packArrayHeader(&w, 2);
        try justinhj.packer.packInt(&w, @as(i64, 1));
        try justinhj.packer.packInt(&w, @as(i64, 2));
        try justinhj.packer.packMapHeader(&w, 1);
        try justinhj.packer.packString(&w, "key");
        try justinhj.packer.packInt(&w, @as(i64, 42));
        var ts_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &ts_buf, 1000000, .big);
        try justinhj.packer.packExt(&w, -1, &ts_buf);
        State.len = w.pos;
        State.ready = true;
    }
    _ = allocator;
    return State.buffer[0..State.len];
}

// Chunked runners
fn runChunkedBench(
    comptime name: []const u8,
    comptime chunk_step: usize,
    comptime iterations: usize,
    getBufFn: fn (std.mem.Allocator) anyerror![]const u8,
) !void {
    const allocator = std.heap.smp_allocator;
    const buf = try getBufFn(allocator);

    // Warmup
    for (0..10) |_| {
        try benchChunkedFeed(chunk_step, buf, allocator);
    }

    const start_ns = getTimeNs();
    for (0..iterations) |_| {
        try benchChunkedFeed(chunk_step, buf, allocator);
    }
    const elapsed_ns = getTimeNs() - start_ns;
    const avg_ns: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    const ops_sec: u64 = if (avg_ns > 0) @intFromFloat(1_000_000_000.0 / avg_ns) else 0;

    std.debug.print(
        "{s:42} | {d:7} | {d:8.1} ns/op | {d:8} ops/sec\n",
        .{ name, iterations, avg_ns, ops_sec },
    );
}

// ============================================================================
// Main Runner
// ============================================================================

pub fn main(init: std.process.Init) !void {
    BenchRuntime.io = init.io;

    const banner: [85]u8 = @splat('=');
    const divider: [85]u8 = @splat('-');

    std.debug.print("\n{s}\n", .{banner});
    std.debug.print("  MessagePack Comparative Benchmark Suite: zigcc vs justinhj\n", .{});
    std.debug.print("  Machine: Apple Silicon (macOS) | Zig: 0.17.0\n", .{});
    std.debug.print("{s}\n\n", .{banner});

    std.debug.print("{s:35} | {s:7} | {s:14} | {s:14} | {s:13}\n", .{
        "Workload", "Iters", "zigcc (ns/op)", "justinhj (ns)", "Comparison",
    });
    std.debug.print("{s}\n", .{divider});

    // 1. Basic Types
    std.debug.print("[Basic Types]\n", .{});
    try compareBenchmark("Nil Write", 1_000_000, zigcc_NilWrite, justin_NilWrite);
    try compareBenchmark("Nil Read", 1_000_000, zigcc_NilRead, justin_NilRead);
    try compareBenchmark("Bool Write", 1_000_000, zigcc_BoolWrite, justin_BoolWrite);
    try compareBenchmark("Bool Read", 1_000_000, zigcc_BoolRead, justin_BoolRead);
    try compareBenchmark("Small Int Write", 1_000_000, zigcc_SmallIntWrite, justin_SmallIntWrite);
    try compareBenchmark("Small Int Read", 1_000_000, zigcc_SmallIntRead, justin_SmallIntRead);
    try compareBenchmark("Large Int Write", 1_000_000, zigcc_LargeIntWrite, justin_LargeIntWrite);
    try compareBenchmark("Large Int Read", 1_000_000, zigcc_LargeIntRead, justin_LargeIntRead);
    try compareBenchmark("Float Write", 1_000_000, zigcc_FloatWrite, justin_FloatWrite);
    try compareBenchmark("Float Read", 1_000_000, zigcc_FloatRead, justin_FloatRead);

    // 2. Strings
    std.debug.print("\n[Strings]\n", .{});
    try compareBenchmark("Short String Write (5 bytes)", 500_000, zigcc_ShortStrWrite, justin_ShortStrWrite);
    try compareBenchmark("Short String Read (5 bytes)", 500_000, zigcc_ShortStrRead, justin_ShortStrRead);
    try compareBenchmark("Medium String Write (~300 bytes)", 100_000, zigcc_MediumStrWrite, justin_MediumStrWrite);
    try compareBenchmark("Medium String Read (~300 bytes)", 100_000, zigcc_MediumStrRead, justin_MediumStrRead);

    // 3. Binary Data
    std.debug.print("\n[Binary Data]\n", .{});
    try compareBenchmark("Small Binary Write (32 bytes)", 500_000, zigcc_SmallBinWrite, justin_SmallBinWrite);
    try compareBenchmark("Small Binary Read (32 bytes)", 500_000, zigcc_SmallBinRead, justin_SmallBinRead);
    try compareBenchmark("Large Binary Write (1KB)", 100_000, zigcc_LargeBinWrite, justin_LargeBinWrite);
    try compareBenchmark("Large Binary Read (1KB)", 100_000, zigcc_LargeBinRead, justin_LargeBinRead);

    // 4. Arrays
    std.debug.print("\n[Arrays]\n", .{});
    try compareBenchmark("Small Array Write (10 elements)", 100_000, zigcc_SmallArrayWrite, justin_SmallArrayWrite);
    try compareBenchmark("Small Array Read (10 elements)", 100_000, zigcc_SmallArrayRead, justin_SmallArrayRead);
    try compareBenchmark("Medium Array Write (100 elements)", 50_000, zigcc_MediumArrayWrite, justin_MediumArrayWrite);
    try compareBenchmark("Medium Array Read (100 elements)", 50_000, zigcc_MediumArrayRead, justin_MediumArrayRead);

    // 5. Maps
    std.debug.print("\n[Maps]\n", .{});
    try compareBenchmark("Small Map Write (10 entries)", 100_000, zigcc_SmallMapWrite, justin_SmallMapWrite);
    try compareBenchmark("Small Map Read (10 entries)", 100_000, zigcc_SmallMapRead, justin_SmallMapRead);
    try compareBenchmark("Medium Map Write (50 entries)", 50_000, zigcc_MediumMapWrite, justin_MediumMapWrite);
    try compareBenchmark("Medium Map Read (50 entries)", 50_000, zigcc_MediumMapRead, justin_MediumMapRead);

    // 6. Extension Types
    std.debug.print("\n[Extension Types]\n", .{});
    try compareBenchmark("EXT Write (16 bytes)", 500_000, zigcc_ExtWrite, justin_ExtWrite);
    try compareBenchmark("EXT Read (16 bytes)", 500_000, zigcc_ExtRead, justin_ExtRead);

    // 7. Timestamps
    std.debug.print("\n[Timestamps]\n", .{});
    try compareBenchmark("Timestamp32 Write", 1_000_000, zigcc_Timestamp32Write, justin_Timestamp32Write);
    try compareBenchmark("Timestamp32 Read", 1_000_000, zigcc_Timestamp32Read, justin_Timestamp32Read);
    try compareBenchmark("Timestamp64 Write", 1_000_000, zigcc_Timestamp64Write, justin_Timestamp64Write);
    try compareBenchmark("Timestamp64 Read", 1_000_000, zigcc_Timestamp64Read, justin_Timestamp64Read);

    // 8. Complex Structures
    std.debug.print("\n[Complex Structures]\n", .{});
    try compareBenchmark("Nested Structure Write", 50_000, zigcc_NestedWrite, justin_NestedWrite);
    try compareBenchmark("Nested Structure Read", 50_000, zigcc_NestedRead, justin_NestedRead);
    try compareBenchmark("Mixed Types Write", 50_000, zigcc_MixedWrite, justin_MixedWrite);
    try compareBenchmark("Mixed Types Read", 50_000, zigcc_MixedRead, justin_MixedRead);

    // 9. Chunked Streaming
    std.debug.print("\n{s}\n", .{banner});
    std.debug.print("  Chunked-Streaming Workload (Incremental Feeding via State Machine)\n", .{});
    std.debug.print("  * Note: zigcc does not support chunked parsing; buffer must be contiguous in memory.\n", .{});
    std.debug.print("{s}\n\n", .{banner});
    std.debug.print("{s:42} | {s:7} | {s:14} | {s:14}\n", .{
        "Workload (Chunk Size)", "Iters", "Time (ns/op)", "Throughput",
    });
    std.debug.print("{s}\n", .{divider});

    try runChunkedBench("Medium Map (1-byte chunk)", 1, 20_000, getPreSerializedMediumMap);
    try runChunkedBench("Medium Map (8-byte chunk)", 8, 20_000, getPreSerializedMediumMap);
    try runChunkedBench("Medium Map (64-byte chunk)", 64, 20_000, getPreSerializedMediumMap);

    try runChunkedBench("Nested Structure (1-byte chunk)", 1, 20_000, getPreSerializedNested);
    try runChunkedBench("Nested Structure (8-byte chunk)", 8, 20_000, getPreSerializedNested);
    try runChunkedBench("Nested Structure (64-byte chunk)", 64, 20_000, getPreSerializedNested);

    try runChunkedBench("Mixed Types (1-byte chunk)", 1, 20_000, getPreSerializedMixed);
    try runChunkedBench("Mixed Types (8-byte chunk)", 8, 20_000, getPreSerializedMixed);
    try runChunkedBench("Mixed Types (64-byte chunk)", 64, 20_000, getPreSerializedMixed);

    std.debug.print("\n{s}\n", .{banner});
    std.debug.print("Benchmark Complete\n", .{});
    std.debug.print("{s}\n", .{banner});
}
