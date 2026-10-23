const std = @import("std");
const builtin = @import("builtin");
const Ast = @import("Ast.zig");
const Number = @import("Number.zig");
const Semantic = @import("Semantic.zig");
const Str = @import("Str.zig");
const Table = @import("Table.zig").Table;
const Value = @import("Value.zig").Value;
const ValueModule = @import("Value.zig");
const Pattern = @import("Pattern.zig");
const Utf8 = @import("Utf8.zig");
const Collector = @import("Collector.zig").Collector;

const FileHandle = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    table: *Table,
    readable: bool,
    writable: bool,
    owns_file: bool = true,
    closed: bool = false,
    auto_close: bool = false,
    /// Which side of an update file last moved the shared position; a `w+`
    /// stream reports where the writes left off, not the reader's stale copy
    last_side: enum { read, write } = .read,
    reader: ?std.Io.File.Reader = null,
    writer: ?std.Io.File.Writer = null,
    writer_interface: ?*std.Io.Writer = null,
    temp_path: ?[]u8 = null,
    line_formats: ?[]Value = null,
    reader_buffer: [4096]u8 = undefined,
    writer_buffer: [4096]u8 = undefined,
};

/// `string.format`'s numeric conversions go through the C library, exactly
/// like `l_sprintf` in the reference, so rounding (half to even), `%a`, and
/// the flag corners are the platform's own.
extern "c" fn snprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;

pub const Error = error{ OutOfMemory, MissingResolution, UnsupportedExpression, UnsupportedStatement, RuntimeError, StepLimit, ExitRequested, CoroutineClose };
const Frame = struct { cells: []@import("Value.zig").Cell, pointers: []*@import("Value.zig").Cell };
const ErrorFrame = struct {
    program: ?*const Semantic.Program,
    call_offset: ?u32,
    /// On a native frame: whether the Lua code at `call_offset` wrote the call
    /// syntactically, and the method name when it used `:`. `luaL_argerror`
    /// reads both off the calling instruction through `lua_getinfo("n")`, and
    /// they are what decide which of the two names a message carries and
    /// whether the argument index counts `self`.
    from_call_site: bool = false,
    method: ?[]const u8 = null,
};
const DateParts = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64, weekday: i64, yearday: i64 };

fn floorDiv128(numerator: i128, denominator: i128) i128 {
    const quotient = @divTrunc(numerator, denominator);
    const remainder = @rem(numerator, denominator);
    return if (remainder != 0 and ((remainder < 0) != (denominator < 0))) quotient - 1 else quotient;
}

fn daysFromCivil(year_value: i128, month: i128, day: i128) i128 {
    const year = year_value - @intFromBool(month <= 2);
    const era = floorDiv128(year, 400);
    const year_of_era = year - era * 400;
    const adjusted_month = month + (if (month > 2) @as(i128, -3) else 9);
    const day_of_year = @divTrunc(153 * adjusted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

fn dateParts(timestamp: i128) DateParts {
    const days = floorDiv128(timestamp, 86400);
    const seconds_in_day = timestamp - days * 86400;
    const shifted_days = days + 719468;
    const era = floorDiv128(shifted_days, 146097);
    const day_of_era = shifted_days - era * 146097;
    const year_of_era = @divTrunc(day_of_era - @divTrunc(day_of_era, 1460) + @divTrunc(day_of_era, 36524) - @divTrunc(day_of_era, 146096), 365);
    var year = year_of_era + era * 400;
    const day_of_year = day_of_era - (365 * year_of_era + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100));
    const month_prime = @divTrunc(5 * day_of_year + 2, 153);
    const day = day_of_year - @divTrunc(153 * month_prime + 2, 5) + 1;
    const month = month_prime + (if (month_prime < 10) @as(i128, 3) else -9);
    year += @intFromBool(month <= 2);
    const year_start = daysFromCivil(year, 1, 1);
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(@divTrunc(seconds_in_day, 3600)),
        .minute = @intCast(@divTrunc(@rem(seconds_in_day, 3600), 60)),
        .second = @intCast(@rem(seconds_in_day, 60)),
        .weekday = @intCast(@mod(days + 4, 7) + 1),
        .yearday = @intCast(days - year_start + 1),
    };
}

fn nextRandomState(state: *[4]u64) u64 {
    const product = state[1] *% 5;
    const result = ((product << 7) | (product >> 57)) *% 9;
    const shifted = state[1] << 17;
    state[2] ^= state[0];
    state[3] ^= state[1];
    state[1] ^= state[2];
    state[0] ^= state[3];
    state[2] ^= shifted;
    state[3] = (state[3] << 45) | (state[3] >> 19);
    return result;
}

fn seedRandomState(first: u64, second: u64) [4]u64 {
    var state: [4]u64 = .{ first, 0xff, second, 0 };
    for (0..16) |_| _ = nextRandomState(&state);
    return state;
}

/// `mkstemp`'s replacement alphabet, which keeps generated names within the
/// characters every filesystem accepts.
const temp_name_alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

fn lineAt(source: []const u8, offset: u32) usize {
    const at = @min(@as(usize, offset), source.len);
    var line: usize = 1;
    for (source[0..at]) |byte| if (byte == '\n') {
        line += 1;
    };
    return line;
}

/// `luaO_chunkid`, near enough: the name is written into the buffer shortened
/// the way the reference shortens it for a message.
fn shortSource(buffer: *[61]u8, name: []const u8) []const u8 {
    // `luaO_chunkid` with a `LUA_IDSIZE` (60) buffer: long names keep their
    // tail behind an `...` and everything stays under sixty visible bytes
    const bufflen: usize = 60;
    if (name.len == 0) return "?";
    if (name[0] == '=') {
        const literal = name[1..];
        if (literal.len < bufflen) {
            @memcpy(buffer[0..literal.len], literal);
            return buffer[0..literal.len];
        }
        @memcpy(buffer[0 .. bufflen - 1], literal[0 .. bufflen - 1]);
        return buffer[0 .. bufflen - 1];
    }
    if (name[0] == '@') {
        const file = name[1..];
        if (name.len <= bufflen) {
            @memcpy(buffer[0..file.len], file);
            return buffer[0..file.len];
        }
        // The reference copies one byte past the name, which is its final
        // NUL, so the visible tail behind the dots is `bufflen - 4` bytes
        const tail = bufflen - 4;
        buffer[0] = '.';
        buffer[1] = '.';
        buffer[2] = '.';
        @memcpy(buffer[3 .. 3 + tail], file[file.len - tail ..]);
        return buffer[0 .. 3 + tail];
    }
    // a string chunk, which reads as [string "..."]. The reference shortens
    // one to the bytes before its first newline — or the first `room` of them
    // where the line itself is longer — and puts `...` behind either sort of
    // cut, so a source with a newline in it reads `[string "abc..."]` even
    // when the head is short.
    var text = name;
    var cut = false;
    if (std.mem.indexOfScalar(u8, text, '\n')) |at| {
        text = text[0..at];
        cut = true;
    }
    const room = bufflen - ("[string \"".len + "...".len + "\"]".len + 1);
    if (text.len >= room) cut = true;
    const piece = text[0..@min(text.len, room)];
    const suffix: []const u8 = if (cut) "...\"]" else "\"]";
    const prefix = "[string \"";
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + piece.len], piece);
    @memcpy(buffer[prefix.len + piece.len .. prefix.len + piece.len + suffix.len], suffix);
    return buffer[0 .. prefix.len + piece.len + suffix.len];
}

/// `LUA_SIGNATURE[0]`: the byte whose presence at the head of a source
/// turns a load into a binary one, whatever the rest of it says.
const binary_chunk_intro: u8 = 0x1b;

/// How far a binary header has come with the bytes pulled so far: `.more`
/// while the next check still needs bytes the reader might give, `.failed`
/// the moment a field disagrees, and `.valid` once the thirty-one header
/// bytes all check out — as far as the format can be judged without a
/// bytecode reader behind it.
const BinaryVerdict = union(enum) { more, failed: []const u8, valid };

/// `checkHeader`'s tests, in order and over the stream as a whole: the
/// signature, the version and format bytes, `LUAC_DATA`, the three type
/// sizes, and the `lua_Integer` and `lua_Number` the header must carry to
/// declare the producer's layout.
fn binaryLoadVerdict(source: []const u8) BinaryVerdict {
    const signature = "\x1bLua";
    if (source.len < signature.len) return .more;
    if (!std.mem.eql(u8, source[0..signature.len], signature)) return .{ .failed = "not a binary chunk" };
    if (source.len < 5) return .more;
    if (source[4] != 0x54) return .{ .failed = "version mismatch" };
    if (source.len < 6) return .more;
    if (source[5] != 0) return .{ .failed = "format mismatch" };
    if (source.len < 12) return .more;
    if (!std.mem.eql(u8, source[6..12], "\x19\x93\r\n\x1a\n")) return .{ .failed = "corrupted chunk" };
    if (source.len < 13) return .more;
    if (source[12] != 4) return .{ .failed = "Instruction size mismatch" };
    if (source.len < 14) return .more;
    if (source[13] != 8) return .{ .failed = "lua_Integer size mismatch" };
    if (source.len < 15) return .more;
    if (source[14] != 8) return .{ .failed = "lua_Number size mismatch" };
    if (source.len < 23) return .more;
    if (!std.mem.eql(u8, source[15..23], "\x78\x56\x00\x00\x00\x00\x00\x00")) return .{ .failed = "integer format mismatch" };
    if (source.len < 31) return .more;
    if (!std.mem.eql(u8, source[23..31], "\x00\x00\x00\x00\x00\x28\x77\x40")) return .{ .failed = "float format mismatch" };
    return .valid;
}

/// `luaU_undump`'s name: an `=` or `@` intro dropped, a source carrying the
/// signature read as `binary string`, and any other name as itself.
fn binaryErrorPrefix(chunk_name: []const u8) []const u8 {
    if (chunk_name.len > 0 and (chunk_name[0] == '=' or chunk_name[0] == '@')) return chunk_name[1..];
    if (chunk_name.len > 0 and chunk_name[0] == binary_chunk_intro) return "binary string";
    return chunk_name;
}

/// Whether a diagnostic's own token ends where the text does, which is the
/// lexer starving for input rather than objecting to what it has.
fn noteStarvedToken(diagnostics: *const @import("Diagnostic.zig").Reporter, source: []const u8, flag: *bool) void {
    if (diagnostics.errors.items.len == 0) return;
    const span = diagnostics.errors.items[0].span;
    flag.* = @as(usize, span.end) >= source.len;
}

/// The part of the VM that says where the interpreter is: the running
/// program, the call frames and the values in transit. A coroutine owns one of
/// these while it is suspended, which is what makes it resumable; everything
/// else in `VM` is shared by every coroutine, the way the reference shares one
/// `lua_State` between its threads.
const ExecState = struct {
    semantics: *const Semantic.Program = undefined,
    locals: []*@import("Value.zig").Cell = &.{},
    upvalues: []*@import("Value.zig").Cell = &.{},
    varargs: []const Value = &.{},
    function_index: u32 = 0,
    active_environment: *@import("Value.zig").Cell = undefined,
    // One entry per running Lua function, innermost last. `call_offset` is
    // where that function was called from in the frame below it, which is what
    // `error` level 2 and up point at. Natives do not get a frame: a native has
    // no position of its own to report.
    error_frames: std.ArrayList(ErrorFrame) = .empty,
    active_functions: std.ArrayList(*@import("Value.zig").Function) = .empty,
    suspended_locals: std.ArrayList([]*@import("Value.zig").Cell) = .empty,
    suspended_varargs: std.ArrayList([]const Value) = .empty,
    suspended_results: std.ArrayList([]Value) = .empty,
    results: std.ArrayList(Value) = .empty,
    close_values: std.ArrayList(Value) = .empty,
    returned: bool = false,
    breaking: bool = false,
    goto_name: ?[]const u8 = null,
    thrown_error: ?Value = null,
    steps_left: usize = 1_000_000,
    error_offset: ?u32 = null,
    /// Set by the two places that turn a syntactic call into a native call and
    /// read by `invokeNativeValues`, which folds them into the frame it pushes.
    /// Anything else that reaches a native — `pcall`'s argument, a metamethod,
    /// a generic `for` iterator — leaves them false, which is when the
    /// reference's `lua_getinfo` finds no name and `pushglobalfuncname` supplies
    /// the qualified one instead.
    pending_from_call_site: bool = false,
    pending_method: ?[]const u8 = null,
    /// The coroutine this state belongs to, once `create` or `init` links it.
    coroutine: ?*Coroutine = null,
};

/// One coroutine: an interpreter state plus the host stack it is suspended in.
/// `std.Io.fiber` performs the stack switch, so a yield parks the Zig call
/// stack exactly as it is and the next resume continues inside it, still
/// holding the interpreter's own frames.
const Coroutine = struct {
    const Status = enum { suspended, running, normal, dead };

    vm: *VM,
    object: *ValueModule.Thread,
    thread_value: Value,
    status: Status,
    main: bool = false,
    started: bool = false,
    /// Set by `coroutine.close`; every suspension point then unwinds with
    /// `error.CoroutineClose` instead of resuming the body.
    close_requested: bool = false,
    /// This coroutine's interpreter state; it owns the list buffers while the
    /// coroutine is not running.
    state: ExecState = .{},
    /// Where the resumer's interpreter state waits while this coroutine runs.
    /// It aliases the resumer's own lists, so it is never deinitialized here.
    caller_state: ExecState = .{},
    caller: ?*Coroutine = null,
    caller_context: ?*std.Io.fiber.Context = null,
    body: Value = .nil,
    error_value: ?Value = null,
    /// The values crossing the resume/yield boundary.
    transfer: []Value = &.{},
    stack: ?[]align(16) u8 = null,
    context: std.Io.fiber.Context = undefined,
};

/// How much host stack a coroutine gets. Deep Lua call chains spend a few
/// kilobytes of Zig stack per level, and the call-depth limit is 200.
const coroutine_stack_size = 1 << 20;

/// The coroutine whose naked fiber entry is about to run. A fresh fiber can
/// take no arguments of its own, and only one is ever started at a time.
var starting_coroutine: ?*Coroutine = null;

/// Entry point for a fresh coroutine stack: park the `Coroutine` pointer
/// where the entry stub expects its first argument, then switch in. The
/// argument is ignored because `starting_coroutine` already names it.
fn fiberEntry() callconv(.withStackAlign(.c, @max(16, @alignOf(std.Io.fiber.Context)))) noreturn {
    const coroutine = starting_coroutine.?;
    starting_coroutine = null;
    const vm = coroutine.vm;
    vm.runCoroutineBody(coroutine);
    vm.leaveCoroutine(coroutine, .dead);
    unreachable;
}

fn fiberNakedEntry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x0, sp
            \\ b %[entry]
            :
            : [entry] "X" (&fiberEntry),
        ),
        .x86_64 => asm volatile (
            \\ leaq 8(%%rsp), %%rdi
            \\ jmp %[entry:P]
            :
            : [entry] "X" (&fiberEntry),
        ),
        else => @compileError("coroutines need an architecture with std.Io.fiber support"),
    }
}

/// Switches from the current host stack into `coroutine`'s, saving where to
/// come back to in the caller's local `Context`.
fn switchInto(coroutine: *Coroutine) void {
    var resumer_context: std.Io.fiber.Context = undefined;
    coroutine.caller_context = &resumer_context;
    var switching: std.Io.fiber.Switch = .{ .old = &resumer_context, .new = &coroutine.context };
    _ = std.Io.fiber.contextSwitch(&switching);
}

/// Simple tree-walking runtime over the resolved AST. Keep it direct for now;
/// introduce an IR only when a concrete optimization or backend needs one.
pub const VM = struct {
    allocator: std.mem.Allocator,
    interner: *Str.Interner,
    exec: ExecState = .{},
    owned_program_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    owned_cells: std.ArrayList(*@import("Value.zig").Cell) = .empty,
    tracker: *@import("Object.zig").Tracker,
    collector: Collector,
    globals: *Table,
    global_environment: *@import("Value.zig").Cell,
    string_metatable: ?*Table = null,
    writer: ?*std.Io.Writer = null,
    stderr: ?*std.Io.Writer = null,
    io: ?std.Io = null,
    environ_map: ?*std.process.Environ.Map = null,
    warn_state: enum { off, ready } = .off,
    owned_tables: std.ArrayList(*Table) = .empty,
    owned_files: std.ArrayList(*FileHandle) = .empty,
    file_metatable: ?*Table = null,
    /// `io.stdin`/`io.stdout`/`io.stderr` and the current default files are
    /// the same objects at the start, but `io.input`/`io.output` move only
    /// the defaults, so the two are cached apart
    default_input: ?*Table = null,
    default_output: ?*Table = null,
    default_error: ?*Table = null,
    stdin_cache: ?*Table = null,
    stdout_cache: ?*Table = null,
    stderr_cache: ?*Table = null,
    owned_functions: std.ArrayList(*@import("Value.zig").Function) = .empty,
    owned_frames: std.ArrayList(Frame) = .empty,
    owned_captures: std.ArrayList([]*@import("Value.zig").Cell) = .empty,
    coroutines: std.ArrayList(*Coroutine) = .empty,
    /// A body for the function value `coroutine.wrap` returns; the wrapper
    /// dispatches on `native` and never looks at this.
    wrapper_body: Ast.FunctionBody = undefined,
    number_buffer: [64]u8 = undefined,
    text_scratch: [8][64]u8 = undefined,
    text_scratch_slot: u3 = 0,
    rng_state: [4]u64 = seedRandomState(0x6c75616c697465, 0x72616e646f6d),
    tmp_name_state: [4]u64 = seedRandomState(0x746d706e616d65, 0x6c75616c697465),
    gc_stopped: bool = false,
    gc_pending: bool = false,
    // Where the deferred sweep stands in the cycle the reference's collector
    // reports through `collectgarbage("step")`: a cycle that has not started
    // yet is "at pause", and each step either begins one (false) or finishes
    // the outstanding one (true), the way a basic step answers after a full
    // collect. An approximation of the boundary state, not of the work done.
    gc_at_pause: bool = true,
    gc_deferral_depth: usize = 0,
    gc_threshold: usize = 1024,
    exit_status: ?u8 = null,

    pub fn init(allocator: std.mem.Allocator, interner: *Str.Interner, semantics: *const Semantic.Program, tracker: *@import("Object.zig").Tracker, globals: *Table) Error!VM {
        const global_environment = allocator.create(@import("Value.zig").Cell) catch return error.OutOfMemory;
        errdefer allocator.destroy(global_environment);
        global_environment.* = .{ .value = .{ .table = globals } };
        var vm: VM = .{
            .allocator = allocator,
            .interner = interner,
            .exec = .{
                .semantics = semantics,
                .active_environment = global_environment,
            },
            .tracker = tracker,
            .collector = .init(allocator),
            .globals = globals,
            .global_environment = global_environment,
        };
        vm.exec.locals = try vm.allocFrame(semantics.functions[0].frame_size);
        try vm.installTableLibrary();
        try vm.installStringLibrary();
        try vm.installUtf8Library();
        try vm.installMathLibrary();
        try vm.installOsLibrary();
        try vm.installIoLibrary();
        try vm.installBaseLibrary();
        try vm.installCoroutineLibrary();
        return vm;
    }

    pub fn deinit(vm: *VM) void {
        for (vm.coroutines.items) |coroutine| vm.destroyCoroutine(coroutine);
        vm.coroutines.deinit(vm.allocator);
        vm.allocator.destroy(vm.global_environment);
        for (vm.owned_cells.items) |cell| vm.allocator.destroy(cell);
        vm.owned_cells.deinit(vm.allocator);
        for (vm.owned_frames.items) |frame| {
            vm.allocator.free(frame.pointers);
            vm.allocator.free(frame.cells);
        }
        vm.owned_frames.deinit(vm.allocator);
        for (vm.owned_captures.items) |captures| vm.allocator.free(captures);
        vm.owned_captures.deinit(vm.allocator);
        vm.exec.suspended_locals.deinit(vm.allocator);
        vm.exec.suspended_varargs.deinit(vm.allocator);
        vm.exec.suspended_results.deinit(vm.allocator);
        vm.exec.error_frames.deinit(vm.allocator);
        vm.exec.active_functions.deinit(vm.allocator);
        vm.exec.results.deinit(vm.allocator);
        vm.exec.close_values.deinit(vm.allocator);
        for (vm.owned_files.items) |handle| {
            closeFileHandle(handle);
            vm.allocator.destroy(handle);
        }
        vm.owned_files.deinit(vm.allocator);
        for (vm.owned_tables.items) |table| table.deinit(vm.tracker);
        vm.owned_tables.deinit(vm.allocator);
        for (vm.owned_functions.items) |function| vm.tracker.free(function);
        vm.owned_functions.deinit(vm.allocator);
        for (vm.owned_program_arenas.items) |arena| {
            arena.deinit();
            vm.allocator.destroy(arena);
        }
        vm.owned_program_arenas.deinit(vm.allocator);
    }

    pub fn run(vm: *VM, chunk: *const Ast.Chunk) Error![]const Value {
        vm.exec.error_frames.append(vm.allocator, .{ .program = vm.exec.semantics, .call_offset = null }) catch return error.OutOfMemory;
        errdefer _ = vm.exec.error_frames.pop();
        try vm.execBlock(&chunk.block);
        _ = vm.exec.error_frames.pop();
        try vm.collectAtSafePoint();
        return vm.exec.results.items;
    }

    fn tick(vm: *VM) Error!void {
        if (!vm.gc_stopped and vm.tracker.count >= vm.gc_threshold) vm.gc_pending = true;
        if (vm.exec.steps_left == 0) return error.StepLimit;
        vm.exec.steps_left -= 1;
    }

    fn execBlock(vm: *VM, block: *const Ast.Block) Error!void {
        const close_start = vm.exec.close_values.items.len;
        vm.execBlockBody(block) catch |err| {
            const original_error = vm.exec.thrown_error;
            vm.closeScope(close_start) catch return error.RuntimeError;
            vm.exec.thrown_error = original_error;
            return err;
        };
        try vm.closeScope(close_start);
    }

    fn execBlockBody(vm: *VM, block: *const Ast.Block) Error!void {
        var statement_index: usize = 0;
        while (true) {
            if (vm.exec.returned or vm.exec.breaking) return;
            if (vm.exec.goto_name) |target| {
                if (findLabelStatement(block, target)) |label_index| {
                    vm.exec.goto_name = null;
                    statement_index = label_index + 1;
                    continue;
                }
                return;
            }
            if (statement_index >= block.statements.len) break;
            try vm.execStatement(block.statements[statement_index]);
            try vm.collectAtSafePoint();
            statement_index += 1;
        }
        if (vm.exec.goto_name != null) return;
        if (!vm.exec.returned) if (block.ret_statement) |ret| {
            try vm.execReturn(ret);
            try vm.collectAtSafePoint();
        };
    }

    fn closeScope(vm: *VM, start: usize) Error!void {
        var close_error: ?Error = null;
        while (vm.exec.close_values.items.len > start) {
            const value = vm.exec.close_values.pop().?;
            if (value == .nil or (value == .boolean and !value.boolean)) continue;
            const method = if (value == .table) try vm.metamethod(value.table, "__close") else .nil;
            if (method == .nil) {
                close_error = error.RuntimeError;
                continue;
            }
            const error_value = vm.exec.thrown_error orelse Value.nil;
            const returned = vm.invokeCallableValues(method, &.{ value, error_value }) catch |err| {
                close_error = err;
                continue;
            };
            vm.allocator.free(returned);
        }
        if (close_error) |err| return err;
    }

    fn execRepeatIteration(vm: *VM, node: *const Ast.RepeatStatement) Error!bool {
        const close_start = vm.exec.close_values.items.len;
        vm.execBlockBody(&node.block) catch |err| {
            const original_error = vm.exec.thrown_error;
            vm.closeScope(close_start) catch return error.RuntimeError;
            vm.exec.thrown_error = original_error;
            return err;
        };
        var should_stop = vm.exec.returned or vm.exec.goto_name != null;
        if (vm.exec.breaking) {
            vm.exec.breaking = false;
            should_stop = true;
        } else if (!should_stop) {
            const condition = vm.eval(node.condition) catch |err| {
                const original_error = vm.exec.thrown_error;
                vm.closeScope(close_start) catch return error.RuntimeError;
                vm.exec.thrown_error = original_error;
                return err;
            };
            should_stop = condition.truthy();
        }
        try vm.closeScope(close_start);
        return should_stop;
    }

    fn findLabelStatement(block: *const Ast.Block, target: []const u8) ?usize {
        for (block.statements, 0..) |statement, i| switch (statement) {
            .label => |label| if (std.mem.eql(u8, label.name.name, target)) return i,
            else => {},
        };
        return null;
    }

    fn execStatement(vm: *VM, statement: Ast.Statement) Error!void {
        vm.exec.error_offset = statementSpan(statement).start;
        try vm.tick();
        switch (statement) {
            .empty, .label => {},
            .goto => |node| vm.exec.goto_name = node.name.name,
            .@"break" => vm.exec.breaking = true,
            .function_call => |call| {
                _ = try vm.evalCall(call);
            },
            .local_declaration => |decl| {
                const values = try vm.evalList(decl.expressions);
                defer vm.allocator.free(values);
                for (decl.names, 0..) |name, i| {
                    const value = if (i < values.len) values[i] else .nil;
                    try vm.declareCell(try vm.localSlot(name.name), value);
                    if (name.attribute) |attribute| if (std.mem.eql(u8, attribute.name.name, "close")) {
                        if (value != .nil and value != .boolean) {
                            const method = if (value == .table) try vm.metamethod(value.table, "__close") else .nil;
                            if (method == .nil) return vm.raise("variable '{s}' got a non-closable value", .{name.name.name});
                        }
                        vm.exec.close_values.append(vm.allocator, value) catch return error.OutOfMemory;
                    };
                }
            },
            .local_function_definition => |definition| {
                // the name is in scope in its own body, so the cell the closure
                // captures has to be the one the declaration installs
                const slot = try vm.localSlot(definition.name);
                try vm.declareCell(slot, .nil);
                const value = try vm.makeFunction(&definition.body);
                vm.exec.locals[slot].value = .{ .function = value };
            },
            .function_definition => |definition| {
                const function: Value = .{ .function = try vm.makeFunction(&definition.body) };
                if (definition.name.fields.len == 0 and definition.name.method == null) {
                    try vm.setName(definition.name.first, function);
                } else {
                    var receiver = try vm.getName(definition.name.first);
                    const traversed_fields = if (definition.name.method != null) definition.name.fields.len else definition.name.fields.len - 1;
                    // Each read goes through what the last one found and names
                    // itself the way `varinfo` does: the first name resolves
                    // itself, every later step is the field that was read
                    var note_buffer: [192]u8 = undefined;
                    for (definition.name.fields[0..traversed_fields], 0..) |field, step| {
                        const note = if (step == 0)
                            vm.identifierDescription(definition.name.first, &note_buffer)
                        else
                            std.fmt.bufPrint(&note_buffer, " (field '{s}')", .{definition.name.fields[step - 1].name}) catch "";
                        receiver = try vm.getTableIndex(receiver, .{ .string = vm.interner.intern(field.name) catch return error.OutOfMemory }, note);
                    }
                    // The last field is written through this receiver, so one
                    // that is not a table is refused the way the write is
                    const table = switch (receiver) {
                        .table => |table| table,
                        else => {
                            const note = if (traversed_fields == 0)
                                vm.identifierDescription(definition.name.first, &note_buffer)
                            else
                                std.fmt.bufPrint(&note_buffer, " (field '{s}')", .{definition.name.fields[traversed_fields - 1].name}) catch "";
                            return vm.raiseIndexFailure(receiver, note);
                        },
                    };
                    const final_name = if (definition.name.method) |method|
                        method.name
                    else
                        definition.name.fields[definition.name.fields.len - 1].name;
                    try vm.setTableIndex(.{ .table = table }, .{ .string = vm.interner.intern(final_name) catch return error.OutOfMemory }, function, "");
                }
            },
            .assignment => |assign| {
                const Target = union(enum) { name: Ast.Identifier, index: struct { receiver: Value, key: Value } };
                const targets = vm.allocator.alloc(Target, assign.variables.len) catch return error.OutOfMemory;
                defer vm.allocator.free(targets);
                for (assign.variables, 0..) |variable, i| targets[i] = switch (variable) {
                    .name => |name| .{ .name = name },
                    .field => |field| .{ .index = .{ .receiver = try vm.eval(field.object), .key = .{ .string = vm.interner.intern(field.name.name) catch return error.OutOfMemory } } },
                    .index => |index| .{ .index = .{ .receiver = try vm.eval(index.object), .key = try vm.eval(index.index) } },
                };
                const values = try vm.evalList(assign.expressions);
                defer vm.allocator.free(values);
                for (targets, 0..) |target, i| {
                    const value: Value = if (i < values.len) values[i] else .nil;
                    switch (target) {
                        .name => |name| try vm.setName(name, value),
                        .index => |index| {
                            // The receiver's expression is still in hand, so
                            // the refusal can name the value it was given
                            var note_buffer: [192]u8 = undefined;
                            const receiver_expression = switch (assign.variables[i]) {
                                .field => |field| field.object,
                                .index => |expression| expression.object,
                                .name => unreachable,
                            };
                            try vm.setTableIndex(index.receiver, index.key, value, vm.operandDescription(receiver_expression, &note_buffer));
                        },
                    }
                }
            },
            .do => |node| try vm.execBlock(&node.block),
            .@"if" => |node| {
                if ((try vm.eval(node.condition)).truthy()) return vm.execBlock(&node.block);
                for (node.elseif_clauses) |clause| if ((try vm.eval(clause.condition)).truthy()) return vm.execBlock(&clause.block);
                if (node.else_clause) |clause| try vm.execBlock(&clause.block);
            },
            .@"while" => |node| while ((try vm.eval(node.condition)).truthy()) {
                try vm.tick();
                try vm.execBlock(&node.block);
                if (vm.exec.returned or vm.exec.goto_name != null) break;
                if (vm.exec.breaking) {
                    vm.exec.breaking = false;
                    break;
                }
            },
            .repeat => |node| while (true) {
                try vm.tick();
                if (try vm.execRepeatIteration(node)) break;
            },
            .numeric_for => |node| {
                // Reference `luaV_forprep` (lvm.c): an integer initial value
                // *and* step run the loop over integers (only the limit is
                // coerced); anything else runs it over floats, so the control
                // variable's type depends on the *step*'s type and a value
                // that will not convert names itself through `luaG_forerror`.
                const initial_value = try vm.eval(node.initial);
                const limit_value = try vm.eval(node.limit);
                const step_value: Value = if (node.step) |expr| try vm.eval(expr) else .{ .number = .{ .int = 1 } };
                const slot = try vm.localSlot(node.name);
                if (initial_value == .number and initial_value.number.isInt() and
                    step_value == .number and step_value.number.isInt())
                {
                    const initial = initial_value.number.int;
                    const step = step_value.number.int;
                    if (step == 0) return vm.raise("'for' step is zero", .{});
                    // `forlimit`: the limit is floored (or raised to a ceil for
                    // a descending loop) into an integer; one that lands
                    // outside the integer range clips to the nearest bound —
                    // or skips the loop when it is already on the far side.
                    const limit: i64 = limit_blk: {
                        const number = arithmeticNumber(limit_value) orelse
                            return vm.raise("bad 'for' limit (number expected, got {s})", .{limit_value.typeName()});
                        if (number == .int) break :limit_blk number.int;
                        const bound = number.float;
                        // `luaV_flttointeger`: floor, and one up from there when
                        // the loop runs down — the inequality is what lets a
                        // limit outside the bounds fall through to the clip
                        const floored = @floor(bound);
                        const rounded = if (step < 0 and floored != bound) floored + 1 else floored;
                        const max_bound: f64 = @floatFromInt(Number.Number.max_int);
                        const min_bound: f64 = @floatFromInt(Number.Number.min_int);
                        if (rounded >= min_bound and rounded < max_bound)
                            break :limit_blk @intFromFloat(rounded);
                        // out of integer range: `luai_numlt(0, flim)` decides
                        // which side of the loop it sits on
                        if (bound > 0) {
                            if (step < 0) return;  // a descending loop starts past it
                            break :limit_blk Number.Number.max_int;
                        } else {
                            if (step > 0) return;  // an ascending loop starts past it
                            break :limit_blk Number.Number.min_int;
                        }
                    };
                    if (if (step > 0) initial > limit else initial < limit) return;  // starts past the limit
                    // The reference stores the *remaining* iterations after
                    // the first, in unsigned arithmetic.
                    const ulimit: u64 = @bitCast(limit);
                    const uinit: u64 = @bitCast(initial);
                    var remaining: u64 = if (step > 0) count_blk: {
                        var count = ulimit -% uinit;
                        if (step != 1) count /= @as(u64, @bitCast(step));
                        break :count_blk count;
                    } else count_blk: {
                        // `-(step + 1)` avoids negating `mininteger` itself
                        const divisor = @as(u64, @bitCast(0 -% (step +% 1))) + 1;
                        break :count_blk (uinit -% ulimit) / divisor;
                    };
                    var current = initial;
                    while (true) {
                        try vm.tick();
                        try vm.declareCell(slot, .{ .number = .{ .int = current } });
                        try vm.execBlock(&node.block);
                        if (vm.exec.returned or vm.exec.goto_name != null) break;
                        if (vm.exec.breaking) {
                            vm.exec.breaking = false;
                            break;
                        }
                        if (remaining == 0) break;
                        remaining -= 1;
                        current +%= step;
                    }
                } else {
                    // Floats all the way: `for i = 1, "3", "1"` counts 1.0,
                    // 2.0, 3.0. The reference checks the values in limit,
                    // step, initial-value order.
                    const limit_number = arithmeticNumber(limit_value) orelse
                        return vm.raise("bad 'for' limit (number expected, got {s})", .{limit_value.typeName()});
                    const step_number = arithmeticNumber(step_value) orelse
                        return vm.raise("bad 'for' step (number expected, got {s})", .{step_value.typeName()});
                    const initial_number = arithmeticNumber(initial_value) orelse
                        return vm.raise("bad 'for' initial value (number expected, got {s})", .{initial_value.typeName()});
                    const initial_float = initial_number.toFloat();
                    const limit_float = limit_number.toFloat();
                    const step_float = step_number.toFloat();
                    if (step_float == 0) return vm.raise("'for' step is zero", .{});
                    if (if (step_float > 0) limit_float < initial_float else initial_float < limit_float) return;  // starts past the limit
                    var current = initial_float;
                    while (true) {
                        try vm.tick();
                        try vm.declareCell(slot, .{ .number = .{ .float = current } });
                        try vm.execBlock(&node.block);
                        if (vm.exec.returned or vm.exec.goto_name != null) break;
                        if (vm.exec.breaking) {
                            vm.exec.breaking = false;
                            break;
                        }
                        // `floatforloop`: advance, and keep going while the
                        // index is still within the limit in the step's
                        // direction — a NaN comparison ends the loop.
                        current += step_float;
                        const within = if (step_float > 0) current <= limit_float else limit_float <= current;
                        if (!within) break;
                    }
                }
            },
            .generic_for => |node| {
                const setup = try vm.evalList(node.expressions);
                defer vm.allocator.free(setup);
                if (setup.len == 0) return error.RuntimeError;
                const iterator = setup[0];
                const state: Value = if (setup.len > 1) setup[1] else .nil;
                var control: Value = if (setup.len > 2) setup[2] else .nil;
                while (true) {
                    try vm.tick();
                    const iterator_args = [_]Value{ state, control };
                    const yielded = try vm.invokeCallableValues(iterator, &iterator_args);
                    defer vm.allocator.free(yielded);
                    if (yielded.len == 0 or yielded[0] == .nil) break;
                    control = yielded[0];
                    for (node.names, 0..) |name, i| {
                        try vm.declareCell(try vm.localSlot(name), if (i < yielded.len) yielded[i] else .nil);
                    }
                    try vm.execBlock(&node.block);
                    if (vm.exec.returned or vm.exec.goto_name != null) break;
                    if (vm.exec.breaking) {
                        vm.exec.breaking = false;
                        break;
                    }
                }
            },
        }
    }

    fn statementSpan(statement: Ast.Statement) @import("Token.zig").Span {
        return switch (statement) {
            .empty => |node| node.span,
            .assignment => |node| node.span,
            .function_call => |node| node.span,
            .label => |node| node.span,
            .@"break" => |node| node.span,
            .goto => |node| node.span,
            .do => |node| node.span,
            .@"while" => |node| node.span,
            .repeat => |node| node.span,
            .@"if" => |node| node.span,
            .numeric_for => |node| node.span,
            .generic_for => |node| node.span,
            .function_definition => |node| node.span,
            .local_function_definition => |node| node.span,
            .local_declaration => |node| node.span,
        };
    }

    fn execReturn(vm: *VM, ret: Ast.RetStatement) Error!void {
        const values = try vm.evalList(ret.expressions);
        defer vm.allocator.free(values);
        vm.exec.results.appendSlice(vm.allocator, values) catch return error.OutOfMemory;
        vm.exec.returned = true;
    }

    fn evalList(vm: *VM, expressions: []const Ast.Expression) Error![]Value {
        var values: std.ArrayList(Value) = .empty;
        errdefer values.deinit(vm.allocator);
        for (expressions, 0..) |expr, i| {
            const is_last = i + 1 == expressions.len;
            if (is_last) switch (expr) {
                .vararg => {
                    values.appendSlice(vm.allocator, vm.exec.varargs) catch return error.OutOfMemory;
                    continue;
                },
                .function_call => |call| {
                    const extra = try vm.evalCallMany(call);
                    defer vm.allocator.free(extra);
                    values.appendSlice(vm.allocator, extra) catch return error.OutOfMemory;
                    continue;
                },
                else => {},
            };
            values.append(vm.allocator, try vm.eval(expr)) catch return error.OutOfMemory;
        }
        return values.toOwnedSlice(vm.allocator) catch return error.OutOfMemory;
    }

    /// A slot some nested function reads gets a new cell every time its
    /// declaration runs, so each turn of a loop hands its closures a variable
    /// of their own instead of one shared with later turns. Uncaptured slots
    /// keep their frame cell and are simply overwritten.
    fn declareCell(vm: *VM, slot: usize, value: Value) Error!void {
        if (!vm.slotIsCaptured(slot)) {
            vm.exec.locals[slot].value = value;
            return;
        }
        const cell = vm.allocator.create(@import("Value.zig").Cell) catch return error.OutOfMemory;
        cell.* = .{ .value = value };
        vm.owned_cells.append(vm.allocator, cell) catch {
            vm.allocator.destroy(cell);
            return error.OutOfMemory;
        };
        vm.exec.locals[slot] = cell;
    }

    fn slotIsCaptured(vm: *VM, slot: usize) bool {
        const function = vm.exec.semantics.functions[vm.exec.function_index];
        return slot < function.captured_slots.len and function.captured_slots[slot];
    }

    fn localSlot(vm: *VM, name: Ast.Identifier) Error!usize {
        return switch (vm.exec.semantics.resolutions.get(name.span.start) orelse return error.MissingResolution) {
            .local => |slot| if (slot < vm.exec.locals.len) slot else error.MissingResolution,
            else => error.UnsupportedExpression,
        };
    }

    fn setName(vm: *VM, name: Ast.Identifier, value: Value) Error!void {
        switch (vm.exec.semantics.resolutions.get(name.span.start) orelse return error.MissingResolution) {
            .local => |slot| vm.exec.locals[slot].value = value,
            .upvalue => |slot| if (slot < vm.exec.upvalues.len) {
                vm.exec.upvalues[slot].value = value;
            } else return error.MissingResolution,
            .global => {
                if (std.mem.eql(u8, name.name, "_ENV")) {
                    vm.exec.active_environment.value = value;
                    return;
                }
                const key = Value{ .string = vm.interner.intern(name.name) catch return error.OutOfMemory };
                const environment = try vm.environmentValue(name);
                try vm.setTableIndex(environment, key, value, vm.environmentNote(name));
            },
        }
    }

    fn getName(vm: *VM, name: Ast.Identifier) Error!Value {
        return switch (vm.exec.semantics.resolutions.get(name.span.start) orelse return error.MissingResolution) {
            .local => |slot| vm.exec.locals[slot].value,
            .global => blk: {
                if (std.mem.eql(u8, name.name, "_ENV")) break :blk vm.exec.active_environment.value;
                break :blk try vm.getTableIndex(
                    try vm.environmentValue(name),
                    .{ .string = vm.interner.intern(name.name) catch return error.OutOfMemory },
                    vm.environmentNote(name),
                );
            },
            .upvalue => |slot| if (slot < vm.exec.upvalues.len) vm.exec.upvalues[slot].value else error.MissingResolution,
        };
    }

    fn environmentValue(vm: *VM, name: Ast.Identifier) Error!Value {
        return switch (vm.exec.semantics.environment_resolutions.get(name.span.start) orelse .global) {
            .local => |slot| if (slot < vm.exec.locals.len) vm.exec.locals[slot].value else error.MissingResolution,
            .upvalue => |slot| if (slot < vm.exec.upvalues.len) vm.exec.upvalues[slot].value else error.MissingResolution,
            .global => vm.exec.active_environment.value,
        };
    }

    /// The `varinfo` tail for the `_ENV` lookup an unresolved global performs:
    /// the value that could not be indexed is the `_ENV` binding itself, and
    /// the reference names that binding. A function's own environment is the
    /// `_ENV` upvalue every global-using chunk gets, so only a shadowing local
    /// is spoken of as a local.
    fn environmentNote(vm: *VM, name: Ast.Identifier) []const u8 {
        return switch (vm.exec.semantics.environment_resolutions.get(name.span.start) orelse .global) {
            .local => " (local '_ENV')",
            .upvalue, .global => " (upvalue '_ENV')",
        };
    }

    fn eval(vm: *VM, expr: Ast.Expression) Error!Value {
        vm.exec.error_offset = expressionSpan(expr).start;
        try vm.tick();
        return switch (expr) {
            .nil => .nil,
            .boolean => |node| .{ .boolean = node.value },
            .number => |node| .{ .number = node.value },
            .string => |node| .{ .string = vm.interner.intern(node.value) catch return error.OutOfMemory },
            .variable => |variable| switch (variable.*) {
                .name => |name| try vm.getName(name),
                .field => |field| {
                    var note_buffer: [192]u8 = undefined;
                    const note = vm.operandDescription(field.object, &note_buffer);
                    const object = try vm.eval(field.object);
                    return try vm.getTableIndex(object, .{ .string = vm.interner.intern(field.name.name) catch return error.OutOfMemory }, note);
                },
                .index => |index| {
                    var note_buffer: [192]u8 = undefined;
                    const note = vm.operandDescription(index.object, &note_buffer);
                    const object = try vm.eval(index.object);
                    return try vm.getTableIndex(object, try vm.eval(index.index), note);
                },
            },
            .parenthesized => |node| try vm.eval(node.expression),
            .unary => |node| try vm.evalUnary(node.operator, node.expression),
            .binary => |node| try vm.evalBinary(node),
            .table => |table| try vm.evalTableConstructor(table),
            .function => |function| .{ .function = try vm.makeFunction(&function.body) },
            .function_call => |call| try vm.evalCall(call),
            .vararg => if (vm.exec.varargs.len == 0) .nil else vm.exec.varargs[0],
        };
    }

    fn expressionSpan(expr: Ast.Expression) @import("Token.zig").Span {
        return switch (expr) {
            .nil => |node| node.span,
            .boolean => |node| node.span,
            .number => |node| node.span,
            .string => |node| node.span,
            .vararg => |node| node.span,
            .variable => |node| switch (node.*) {
                .name => |name| name.span,
                .index => |index| index.span,
                .field => |field| field.span,
            },
            .unary => |node| node.span,
            .binary => |node| node.span,
            .function => |node| node.span,
            .table => |node| node.span,
            .parenthesized => |node| node.span,
            .function_call => |node| node.span,
        };
    }

    fn makeFunction(vm: *VM, body: *const Ast.FunctionBody) Error!*@import("Value.zig").Function {
        const definition = vm.exec.semantics.definitions.get(body.span.start) orelse return error.MissingResolution;
        const semantic_function = vm.exec.semantics.functions[definition.function];
        const captures = vm.allocator.alloc(*@import("Value.zig").Cell, semantic_function.upvalues.len) catch return error.OutOfMemory;
        errdefer vm.allocator.free(captures);
        for (semantic_function.upvalues, 0..) |upvalue, i| captures[i] = switch (upvalue) {
            .parent_local => |slot| if (slot < vm.exec.locals.len) vm.exec.locals[slot] else return error.MissingResolution,
            .parent_upvalue => |slot| if (slot < vm.exec.upvalues.len) vm.exec.upvalues[slot] else return error.MissingResolution,
        };
        const function = vm.tracker.alloc(@import("Value.zig").Function, .function) catch return error.OutOfMemory;
        errdefer vm.tracker.free(function);
        function.semantics = vm.exec.semantics;
        function.body = body;
        function.function_index = definition.function;
        function.captures = captures;
        function.environment = vm.exec.active_environment;
        function.native = null;
        function.bound = .nil;
        vm.owned_functions.append(vm.allocator, function) catch return error.OutOfMemory;
        errdefer for (vm.owned_functions.items, 0..) |owned, i| if (owned == function) {
            _ = vm.owned_functions.swapRemove(i);
            break;
        };
        vm.owned_captures.append(vm.allocator, captures) catch return error.OutOfMemory;
        return function;
    }

    fn evalCall(vm: *VM, call: *const Ast.FunctionCall) Error!Value {
        if (call.arguments != .parenthesized) return vm.evalSugarCall(call);
        const values = try vm.invokeCallValues(call);
        defer vm.allocator.free(values);
        return if (values.len == 0) .nil else values[0];
    }

    fn evalCallMany(vm: *VM, call: *const Ast.FunctionCall) Error![]Value {
        return vm.invokeCallValues(call);
    }

    fn invokeCallValues(vm: *VM, call: *const Ast.FunctionCall) Error![]Value {
        const explicit_values = switch (call.arguments) {
            .parenthesized => |parenthesized| try vm.evalList(parenthesized.expressions),
            .table => |table| try vm.allocator.dupe(Value, &.{try vm.evalTableConstructor(&table)}),
            .string => |string| try vm.allocator.dupe(Value, &.{.{ .string = vm.interner.intern(string.value) catch return error.OutOfMemory }}),
        };
        defer vm.allocator.free(explicit_values);
        // The call site is where `error` reports from once the arguments have
        // been evaluated, the way the reference blames the call instruction.
        const callable = if (call.method) |method| blk: {
            const receiver = try vm.eval(call.expression);
            const key = Value{ .string = vm.interner.intern(method.name) catch return error.OutOfMemory };
            var receiver_note_buffer: [192]u8 = undefined;
            const method_value = try vm.getTableIndex(receiver, key, vm.operandDescription(call.expression, &receiver_note_buffer));
            vm.exec.error_offset = call.span.start;
            if (!try vm.isCallable(method_value)) {
                var description_buffer: [192]u8 = undefined;
                const description = std.fmt.bufPrint(&description_buffer, " (method '{s}')", .{method.name}) catch "";
                return vm.callFailure(method_value, description);
            }
            const arguments = vm.allocator.alloc(Value, explicit_values.len + 1) catch return error.OutOfMemory;
            defer vm.allocator.free(arguments);
            arguments[0] = receiver;
            @memcpy(arguments[1..], explicit_values);
            vm.exec.pending_from_call_site = true;
            vm.exec.pending_method = method.name;
            break :blk try vm.invokeCallableValues(method_value, arguments);
        } else blk: {
            const function = try vm.eval(call.expression);
            vm.exec.error_offset = call.span.start;
            if (!try vm.isCallable(function)) {
                var description_buffer: [192]u8 = undefined;
                return vm.callFailure(function, vm.operandDescription(call.expression, &description_buffer));
            }
            vm.exec.pending_from_call_site = true;
            vm.exec.pending_method = null;
            break :blk try vm.invokeCallableValues(function, explicit_values);
        };
        return callable;
    }

    fn evalSugarCall(vm: *VM, call: *const Ast.FunctionCall) Error!Value {
        const argument = switch (call.arguments) {
            .table => |table| try vm.evalTableConstructor(&table),
            .string => |string| Value{ .string = vm.interner.intern(string.value) catch return error.OutOfMemory },
            .parenthesized => unreachable,
        };
        const results = if (call.method) |method| blk: {
            const receiver = try vm.eval(call.expression);
            var receiver_note_buffer: [192]u8 = undefined;
            const method_value = try vm.getTableIndex(receiver, .{ .string = vm.interner.intern(method.name) catch return error.OutOfMemory }, vm.operandDescription(call.expression, &receiver_note_buffer));
            vm.exec.error_offset = call.span.start;
            if (!try vm.isCallable(method_value)) {
                var description_buffer: [192]u8 = undefined;
                const description = std.fmt.bufPrint(&description_buffer, " (method '{s}')", .{method.name}) catch "";
                return vm.callFailure(method_value, description);
            }
            vm.exec.pending_from_call_site = true;
            vm.exec.pending_method = method.name;
            break :blk try vm.invokeCallableValues(method_value, &.{ receiver, argument });
        } else blk: {
            const function = try vm.eval(call.expression);
            vm.exec.error_offset = call.span.start;
            if (!try vm.isCallable(function)) {
                var description_buffer: [192]u8 = undefined;
                return vm.callFailure(function, vm.operandDescription(call.expression, &description_buffer));
            }
            vm.exec.pending_from_call_site = true;
            vm.exec.pending_method = null;
            break :blk try vm.invokeCallableValues(function, &.{argument});
        };
        defer vm.allocator.free(results);
        return if (results.len == 0) .nil else results[0];
    }

    fn protectedCall(vm: *VM, args: []const Value, has_handler: bool) Error![]Value {
        const short: []const u8 = if (has_handler) "xpcall" else "pcall";
        if (has_handler) {
            // `luaB_xpcall` reads the handler before it looks at the function
            _ = try vm.checkFunction(args, 2, short, short);
        } else {
            // `luaB_pcall` refuses a call with nothing at all to call
            try vm.checkAny(args, 1, short, short);
        }
        const function = args[0];
        const handler = if (has_handler) args[1] else .nil;
        const call_args = args[if (has_handler) 2 else 1..];
        const saved_error = vm.exec.thrown_error;
        vm.exec.thrown_error = null;
        const results = vm.invokeCallableValues(function, call_args) catch |err| {
            // A pending close is not catchable: `pcall` and `xpcall` pass it
            // through, the way `lua_closethread`'s status passes through the
            // reference's protected calls.
            if (err == error.CoroutineClose) {
                vm.exec.thrown_error = saved_error;
                return err;
            }
            const thrown = vm.exec.thrown_error orelse Value{ .string = vm.interner.intern("runtime error") catch return error.OutOfMemory };
            vm.exec.thrown_error = saved_error;
            if (err != error.RuntimeError) return err;
            var handled = thrown;
            if (has_handler) {
                vm.exec.thrown_error = null;
                const message = vm.invokeCallableValues(handler, &.{thrown}) catch {
                    vm.exec.thrown_error = saved_error;
                    const fallback = Value{ .string = vm.interner.intern("error in error handling") catch return error.OutOfMemory };
                    return vm.allocator.dupe(Value, &.{ .{ .boolean = false }, fallback }) catch return error.OutOfMemory;
                };
                handled = if (message.len == 0) .nil else message[0];
                vm.allocator.free(message);
                vm.exec.thrown_error = saved_error;
            }
            return vm.allocator.dupe(Value, &.{ .{ .boolean = false }, handled }) catch return error.OutOfMemory;
        };
        defer vm.allocator.free(results);
        vm.exec.thrown_error = saved_error;
        const values = vm.allocator.alloc(Value, results.len + 1) catch return error.OutOfMemory;
        values[0] = .{ .boolean = true };
        @memcpy(values[1..], results);
        return values;
    }

    /// How the call reached the native: carried from the syntactic call site,
    /// if there was one, to the frame the native pushes. `luaL_argerror` reads
    /// the same two facts off the calling instruction.
    const CallSite = struct {
        from_call_site: bool = false,
        method: ?[]const u8 = null,
    };

    fn invokeCallableValues(vm: *VM, callable: Value, args: []const Value) Error![]Value {
        return vm.invokeCallableDepth(callable, args, 0);
    }

    fn invokeCallableDepth(vm: *VM, callable: Value, args: []const Value, depth: usize) Error![]Value {
        if (depth >= 200) return error.RuntimeError;
        // Whatever wrote `pending_*` intended it for this call and nothing
        // deeper, so it is taken here and handed down explicitly.
        const site: CallSite = .{
            .from_call_site = vm.exec.pending_from_call_site,
            .method = vm.exec.pending_method,
        };
        vm.exec.pending_from_call_site = false;
        vm.exec.pending_method = null;
        return vm.invokeCallableInfo(callable, args, depth, site);
    }

    fn invokeCallableInfo(vm: *VM, callable: Value, args: []const Value, depth: usize, site: CallSite) Error![]Value {
        return switch (callable) {
            .function => |function| blk: {
                // `coroutine.wrap`'s value runs its native with the thread
                // bound in front of the call's own arguments.
                if (function.native) |native| {
                    const arguments = vm.allocator.alloc(Value, args.len + 1) catch return error.OutOfMemory;
                    defer vm.allocator.free(arguments);
                    arguments[0] = function.bound;
                    @memcpy(arguments[1..], args);
                    break :blk try vm.invokeNativeValues(native, arguments, site);
                }
                break :blk try vm.invokeValues(function, args);
            },
            .native_function => |function| vm.invokeNativeValues(function, args, site),
            .table => |table| blk: {
                const method = try vm.metamethod(table, "__call");
                if (method == .nil) return vm.raisePlain("attempt to call a {s} value", .{callable.typeName()});
                const arguments = vm.allocator.alloc(Value, args.len + 1) catch return error.OutOfMemory;
                defer vm.allocator.free(arguments);
                arguments[0] = callable;
                @memcpy(arguments[1..], args);
                break :blk try vm.invokeCallableInfo(method, arguments, depth + 1, site);
            },
            else => return vm.raisePlain("attempt to call a {s} value", .{callable.typeName()}),
        };
    }

    fn invokeNativeValues(vm: *VM, function: ValueModule.NativeFunction, args: []const Value, site: CallSite) Error![]Value {
        // Natives get a position-less frame so that `error` levels count them,
        // the way the reference counts C calls: asking for a level that lands
        // on a native yields no position rather than the Lua frame below it.
        vm.exec.error_frames.append(vm.allocator, .{
            .program = null,
            .call_offset = vm.exec.error_offset,
            .from_call_site = site.from_call_site,
            .method = site.method,
        }) catch return error.OutOfMemory;
        defer _ = vm.exec.error_frames.pop();
        switch (function) {
            .base_print => return vm.basePrint(args),
            .base_type => return vm.baseType(args),
            .base_tostring => return vm.baseToString(args),
            .base_tonumber => return vm.baseToNumber(args),
            .base_assert => return vm.baseAssert(args),
            .base_error => return vm.baseError(args),
            .base_pcall => return vm.protectedCall(args, false),
            .base_xpcall => return vm.protectedCall(args, true),
            .base_select => return vm.baseSelect(args),
            .base_rawequal => return vm.baseRawequal(args),
            .base_rawget => return vm.baseRawGet(args),
            .base_rawset => return vm.baseRawSet(args),
            .base_rawlen => return vm.baseRawLen(args),
            .base_setmetatable => return vm.baseSetMetatable(args),
            .base_getmetatable => return vm.baseGetMetatable(args),
            .base_load => return vm.baseLoad(args),
            .base_loadfile => return vm.baseLoadFile(args),
            .base_dofile => return vm.baseDoFile(args),
            .base_warn => return vm.baseWarn(args),
            .base_collectgarbage => return vm.baseCollectGarbage(args),
            .pairs, .ipairs => {
                // `luaL_checkany` only: a number or a string is handed to the
                // iterator, which is where it gets refused
                try vm.checkAny(args, 1, if (function == .pairs) "pairs" else "ipairs", if (function == .pairs) "pairs" else "ipairs");
                if (function == .pairs) {
                    const method = if (args[0] == .table) try vm.metamethod(args[0].table, "__pairs") else try vm.valueMetamethod(args[0], "__pairs");
                    if (method != .nil) return vm.invokeCallableValues(method, &.{args[0]});
                }
                const iterator: Value = .{ .native_function = if (function == .pairs) .next else .ipairs_iterator };
                // `ipairs` starts its control at integer zero, `pairs` at nil
                const control: Value = if (function == .ipairs) .{ .number = Number.Number.fromInt(0) } else .nil;
                return vm.allocator.dupe(Value, &.{ iterator, args[0], control }) catch return error.OutOfMemory;
            },
            .next => {
                const table = try vm.checkTable(args, 1, "next", "next");
                const key = if (args.len == 1 or args[1] == .nil) null else args[1];
                // A resume key the walk cannot continue from is refused the
                // way `findindex` refuses it, and without a position: the
                // reference reports it against `next`'s own C frame, never
                // against the line that called it.
                if (key) |given| if (!table.resumableNextKey(given)) return vm.raisePlain("invalid key to 'next'", .{});
                const pair = table.next(key);
                if (pair) |entry| return vm.allocator.dupe(Value, &.{ entry.key, entry.value }) catch return error.OutOfMemory;
                return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
            },
            .ipairs_iterator => {
                // `ipairsaux`: the index is taken from argument two and the
                // subject is whatever `lua_geti` was given
                if (args.len < 1) return error.RuntimeError;
                const previous: i64 = if (args.len > 1) try intArgument(args[1]) else 0;
                const index = std.math.add(i64, previous, 1) catch return error.RuntimeError;
                const key: Value = .{ .number = Number.Number.fromInt(index) };
                // `ipairsaux` reads through `lua_geti`, so a subject table's
                // `__index` runs: 5.4 walks past the array's own end if the
                // metamethod keeps answering
                const value = try vm.getTableIndex(args[0], key, "");
                if (value == .nil) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
                return vm.allocator.dupe(Value, &.{ key, value }) catch return error.OutOfMemory;
            },
            .table_insert => return vm.tableInsert(args),
            .table_remove => return vm.tableRemove(args),
            .table_concat => return vm.tableConcat(args),
            .table_unpack => return vm.tableUnpack(args),
            .table_pack => return vm.tablePack(args),
            .table_move => return vm.tableMove(args),
            .table_sort => return vm.tableSort(args),
            .string_len => return vm.stringLen(args),
            .string_sub => return vm.stringSub(args),
            .string_rep => return vm.stringRep(args),
            .string_reverse => return vm.stringReverse(args),
            .string_upper => return vm.stringCase(args, true),
            .string_lower => return vm.stringCase(args, false),
            .string_byte => return vm.stringByte(args),
            .string_char => return vm.stringChar(args),
            .string_find => return vm.stringFind(args),
            .string_match => return vm.stringMatch(args),
            .string_gmatch => return vm.stringGmatch(args),
            .string_gmatch_iterator => return vm.stringGmatchIterator(args),
            .string_gsub => return vm.stringGsub(args),
            .string_format => return vm.stringFormat(args),
            .string_pack => return vm.stringPack(args),
            .string_packsize => return vm.stringPackSize(args),
            .string_unpack => return vm.stringUnpack(args),
            .string_dump => return vm.stringDump(args),
            .utf8_char => return vm.utf8Char(args),
            .utf8_len => return vm.utf8Len(args),
            .utf8_codepoint => return vm.utf8Codepoint(args),
            .utf8_offset => return vm.utf8Offset(args),
            .utf8_codes => return vm.utf8Codes(args),
            .utf8_codes_iterator, .utf8_codes_iterator_lax => return vm.utf8CodesIterator(args, function == .utf8_codes_iterator_lax),
            .math_abs => return vm.mathAbs(args),
            .math_floor => return vm.mathRound(args, true),
            .math_ceil => return vm.mathRound(args, false),
            .math_sqrt => return vm.mathSqrt(args),
            .math_fmod => return vm.mathFmod(args),
            .math_max => return vm.mathMinMax(args, true),
            .math_min => return vm.mathMinMax(args, false),
            .math_tointeger => return vm.mathToInteger(args),
            .math_type => return vm.mathType(args),
            .math_sin => return vm.mathUnary(args, .sin),
            .math_cos => return vm.mathUnary(args, .cos),
            .math_tan => return vm.mathUnary(args, .tan),
            .math_asin => return vm.mathUnary(args, .asin),
            .math_acos => return vm.mathUnary(args, .acos),
            .math_atan => return vm.mathAtan(args),
            .math_exp => return vm.mathUnary(args, .exp),
            .math_log => return vm.mathLog(args),
            .math_deg => return vm.mathUnary(args, .deg),
            .math_rad => return vm.mathUnary(args, .rad),
            .math_modf => return vm.mathModf(args),
            .math_ult => return vm.mathUlt(args),
            .math_random => return vm.mathRandom(args),
            .math_randomseed => return vm.mathRandomSeed(args),
            .os_clock => return vm.osClock(args),
            .os_time => return vm.osTime(args),
            .os_difftime => return vm.osDiffTime(args),
            .os_getenv => return vm.osGetEnv(args),
            .os_date => return vm.osDate(args),
            .os_execute => return vm.osExecute(args),
            .os_remove => return vm.osRemove(args),
            .os_rename => return vm.osRename(args),
            .os_setlocale => return vm.osSetLocale(args),
            .os_exit => return vm.osExit(args),
            .os_tmpname => return vm.osTmpName(args),
            .io_open => return vm.ioOpen(args),
            .io_write => return vm.ioWrite(args),
            .io_flush => return vm.ioFlush(args),
            .io_type => return vm.ioType(args),
            .io_close => return vm.ioClose(args),
            .io_lines => return vm.ioLines(args),
            .io_input => return vm.ioInput(args),
            .io_output => return vm.ioOutput(args),
            .io_read => return vm.ioRead(args),
            .io_tmpfile => return vm.ioTmpFile(args),
            .io_index => return vm.ioIndex(args),
            .file_read => return vm.fileRead(args),
            .file_write => return vm.fileWrite(args),
            .file_flush => return vm.fileFlush(args),
            .file_close => return vm.fileClose(args, "?"),
            .file_seek => return vm.fileSeek(args),
            .file_lines => return vm.fileLines(args),
            .file_setvbuf => return vm.fileSetvbuf(args),
            .file_lines_iterator => return vm.fileLinesIterator(args),
            .file_tostring => return vm.fileToString(args),
            .coroutine_create => return vm.coroutineCreate(args),
            .coroutine_resume => return vm.coroutineResume(args),
            .coroutine_yield => return vm.coroutineYield(args),
            .coroutine_status => return vm.coroutineStatus(args),
            .coroutine_running => return vm.coroutineRunning(args),
            .coroutine_isyieldable => return vm.coroutineIsYieldable(args),
            .coroutine_close => return vm.coroutineClose(args),
            .coroutine_wrap => return vm.coroutineWrap(args),
            // reached only through the function value `wrap` builds, which
            // feeds the bound thread in front of the arguments
            .coroutine_wrap_call => return vm.coroutineWrapCall(args),
        }
    }

    /// The shared checking behind `create` and `wrap`.
    fn createThread(vm: *VM, args: []const Value, short: []const u8, long: []const u8) Error!*Coroutine {
        if (args.len < 1) return vm.raiseArgument(1, short, long, "function expected, got no value", .{});
        const body = args[0];
        if (body != .function and body != .native_function)
            return vm.raiseArgument(1, short, long, "function expected, got {s}", .{body.typeName()});
        const object = vm.tracker.alloc(ValueModule.Thread, .thread) catch return error.OutOfMemory;
        errdefer vm.tracker.free(object);
        const coroutine = vm.allocator.create(Coroutine) catch return error.OutOfMemory;
        errdefer vm.allocator.destroy(coroutine);
        coroutine.* = .{
            .vm = vm,
            .object = object,
            .thread_value = .{ .thread = object },
            .status = .suspended,
            .body = body,
        };
        object.coroutine = coroutine;
        vm.coroutines.append(vm.allocator, coroutine) catch return error.OutOfMemory;
        return coroutine;
    }

    fn coroutineCreate(vm: *VM, args: []const Value) Error![]Value {
        const coroutine = try vm.createThread(args, "create", "coroutine.create");
        return vm.allocator.dupe(Value, &.{coroutine.thread_value}) catch return error.OutOfMemory;
    }

    fn coroutineArgument(vm: *VM, args: []const Value, short: []const u8, long: []const u8) Error!*Coroutine {
        if (args.len < 1) return vm.raiseArgument(1, short, long, "thread expected, got no value", .{});
        if (args[0] != .thread) return vm.raiseArgument(1, short, long, "thread expected, got {s}", .{args[0].typeName()});
        const object = args[0].thread;
        const coroutine: *Coroutine = @ptrCast(@alignCast(object.coroutine orelse return error.RuntimeError));
        return coroutine;
    }

    /// `refuse to resume` cases: the reference returns `false` and a message
    /// rather than raising, so `pcall(coroutine.resume, ...)` reports success.
    fn resumeFailure(vm: *VM, message: []const u8) Error![]Value {
        const text: Value = .{ .string = vm.interner.intern(message) catch return error.OutOfMemory };
        return vm.allocator.dupe(Value, &.{ .{ .boolean = false }, text }) catch return error.OutOfMemory;
    }

    fn coroutineResume(vm: *VM, args: []const Value) Error![]Value {
        const coroutine = try vm.coroutineArgument(args, "resume", "coroutine.resume");
        return vm.resumeThread(coroutine, args[1..]);
    }

    /// What `resume` and the `wrap` callable share: run the coroutine, then
    /// report `true` with the yielded values or `false` with the error.
    fn resumeThread(vm: *VM, coroutine: *Coroutine, args: []const Value) Error![]Value {
        switch (coroutine.status) {
            .dead => return vm.resumeFailure("cannot resume dead coroutine"),
            .running, .normal => return vm.resumeFailure("cannot resume non-suspended coroutine"),
            .suspended => {},
        }
        try vm.resumeCoroutine(coroutine, args);
        if (coroutine.error_value) |value| {
            return vm.allocator.dupe(Value, &.{ .{ .boolean = false }, value }) catch return error.OutOfMemory;
        }
        const values = vm.allocator.alloc(Value, coroutine.transfer.len + 1) catch return error.OutOfMemory;
        values[0] = .{ .boolean = true };
        @memcpy(values[1..], coroutine.transfer);
        return values;
    }

    fn coroutineWrap(vm: *VM, args: []const Value) Error![]Value {
        const coroutine = try vm.createThread(args, "wrap", "coroutine.wrap");
        const function = vm.tracker.alloc(ValueModule.Function, .function) catch return error.OutOfMemory;
        errdefer vm.tracker.free(function);
        function.semantics = vm.exec.semantics;
        function.body = &vm.wrapper_body;
        function.function_index = 0;
        function.captures = &.{};
        function.environment = vm.exec.active_environment;
        function.native = .coroutine_wrap_call;
        function.bound = coroutine.thread_value;
        vm.owned_functions.append(vm.allocator, function) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .function = function }}) catch return error.OutOfMemory;
    }

    /// The callable `wrap` returns; the dispatcher put the thread first.
    fn coroutineWrapCall(vm: *VM, args: []const Value) Error![]Value {
        const object = args[0].thread;
        const coroutine: *Coroutine = @ptrCast(@alignCast(object.coroutine orelse return error.RuntimeError));
        const results = try vm.resumeThread(coroutine, args[1..]);
        defer vm.allocator.free(results);
        if (!results[0].boolean) {
            const value = results[1];
            // The reference closes the errored thread here, which leaves it
            // dead and empty rather than dead with the error still in hand.
            coroutine.error_value = null;
            if (value == .string) {
                var position_buffer: [192]u8 = undefined;
                if (try vm.nativeRaisePosition(&position_buffer)) |position| {
                    const message = std.fmt.allocPrint(vm.allocator, "{s}{s}", .{ position, value.string.slice() }) catch return error.OutOfMemory;
                    defer vm.allocator.free(message);
                    vm.exec.thrown_error = .{ .string = vm.interner.intern(message) catch return error.OutOfMemory };
                    return error.RuntimeError;
                }
            }
            vm.exec.thrown_error = value;
            return error.RuntimeError;
        }
        return vm.allocator.dupe(Value, results[1..]) catch return error.OutOfMemory;
    }

    fn coroutineYield(vm: *VM, args: []const Value) Error![]Value {
        const coroutine = vm.exec.coroutine orelse return vm.raisePlain("attempt to yield from outside a coroutine", .{});
        if (coroutine.main) return vm.raisePlain("attempt to yield from outside a coroutine", .{});
        try vm.replaceTransfer(coroutine, args);
        vm.leaveCoroutine(coroutine, .suspended);
        if (coroutine.close_requested) return error.CoroutineClose;
        return vm.allocator.dupe(Value, coroutine.transfer) catch return error.OutOfMemory;
    }

    fn coroutineStatus(vm: *VM, args: []const Value) Error![]Value {
        const coroutine = try vm.coroutineArgument(args, "status", "coroutine.status");
        const name: []const u8 = if (coroutine == vm.exec.coroutine)
            "running"
        else switch (coroutine.status) {
            .running, .normal => "normal",
            .suspended => "suspended",
            .dead => "dead",
        };
        const text: Value = .{ .string = vm.interner.intern(name) catch return error.OutOfMemory };
        return vm.allocator.dupe(Value, &.{text}) catch return error.OutOfMemory;
    }

    fn coroutineRunning(vm: *VM, args: []const Value) Error![]Value {
        _ = args;
        const coroutine = vm.exec.coroutine orelse return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{ coroutine.thread_value, .{ .boolean = coroutine.main } }) catch return error.OutOfMemory;
    }

    fn coroutineIsYieldable(vm: *VM, args: []const Value) Error![]Value {
        const coroutine = if (args.len == 0)
            vm.exec.coroutine.?
        else
            try vm.coroutineArgument(args, "isyieldable", "coroutine.isyieldable");
        // In the reference only the main coroutine reports false; a suspended
        // coroutine is yieldable again the moment it is resumed.
        return vm.allocator.dupe(Value, &.{.{ .boolean = !coroutine.main }}) catch return error.OutOfMemory;
    }

    fn coroutineClose(vm: *VM, args: []const Value) Error![]Value {
        const coroutine = try vm.coroutineArgument(args, "close", "coroutine.close");
        const alive: [1]Value = .{.{ .boolean = true }};
        switch (coroutine.status) {
            .running => return vm.raise("cannot close a running coroutine", .{}),
            .normal => return vm.raise("cannot close a normal coroutine", .{}),
            .dead => {
                if (coroutine.error_value) |value| {
                    return vm.allocator.dupe(Value, &.{ .{ .boolean = false }, value }) catch return error.OutOfMemory;
                }
                return vm.allocator.dupe(Value, &alive) catch return error.OutOfMemory;
            },
            .suspended => {
                if (!coroutine.started) {
                    coroutine.status = .dead;
                    return vm.allocator.dupe(Value, &alive) catch return error.OutOfMemory;
                }
                // Resuming makes every suspension point unwind instead of
                // continuing, which is what runs the pending close handlers.
                coroutine.close_requested = true;
                vm.enterCoroutine(coroutine);
                switchInto(coroutine);
                if (coroutine.error_value) |value| {
                    return vm.allocator.dupe(Value, &.{ .{ .boolean = false }, value }) catch return error.OutOfMemory;
                }
                return vm.allocator.dupe(Value, &alive) catch return error.OutOfMemory;
            },
        }
    }

    fn replaceTransfer(vm: *VM, coroutine: *Coroutine, args: []const Value) Error!void {
        const copy = vm.allocator.dupe(Value, args) catch return error.OutOfMemory;
        if (coroutine.transfer.len != 0) vm.allocator.free(coroutine.transfer);
        coroutine.transfer = copy;
    }

    /// Hands the interpreter over to `coroutine`, stashing the current state
    /// in its `caller_state` for when it comes back.
    fn enterCoroutine(vm: *VM, coroutine: *Coroutine) void {
        coroutine.caller_state = vm.exec;
        coroutine.caller = vm.exec.coroutine;
        if (coroutine.caller) |caller| {
            if (!caller.main) caller.status = .normal;
        }
        const state = coroutine.state;
        coroutine.state = .{};
        vm.exec = state;
        vm.exec.coroutine = coroutine;
        coroutine.status = .running;
        coroutine.started = true;
    }

    /// Parks the coroutine's state and switches back to its resumer; returns
    /// inside the coroutine once something resumes it again.
    fn leaveCoroutine(vm: *VM, coroutine: *Coroutine, status: Coroutine.Status) void {
        coroutine.status = status;
        coroutine.state = vm.exec;
        vm.exec = coroutine.caller_state;
        coroutine.caller_state = .{};
        if (coroutine.caller) |caller| {
            if (!caller.main) caller.status = .running;
        }
        var switching: std.Io.fiber.Switch = .{ .old = &coroutine.context, .new = coroutine.caller_context.? };
        _ = std.Io.fiber.contextSwitch(&switching);
    }

    fn resumeCoroutine(vm: *VM, coroutine: *Coroutine, args: []const Value) Error!void {
        if (!coroutine.started) {
            try vm.allocateCoroutineStack(coroutine);
            starting_coroutine = coroutine;
        }
        try vm.replaceTransfer(coroutine, args);
        vm.enterCoroutine(coroutine);
        switchInto(coroutine);
    }

    fn allocateCoroutineStack(vm: *VM, coroutine: *Coroutine) Error!void {
        const stack = vm.allocator.alignedAlloc(u8, .fromByteUnits(16), coroutine_stack_size) catch return error.OutOfMemory;
        coroutine.stack = stack;
        const top = @intFromPtr(stack.ptr) + coroutine_stack_size;
        // A frame with a zero return address, so that anything that walks the
        // stack (the debug allocator does, for its traces) stops here rather
        // than reading its way off the fiber.
        const frame: *[2]usize = @ptrFromInt(top - @sizeOf([2]usize));
        frame.* = .{ 0, 0 };
        coroutine.context = switch (builtin.cpu.arch) {
            .aarch64 => .{ .sp = top - 16, .fp = top - 16, .pc = @intFromPtr(&fiberNakedEntry) },
            .x86_64 => .{ .rsp = top - 8, .rbp = top - 8, .rip = @intFromPtr(&fiberNakedEntry) },
            else => unreachable,
        };
    }

    /// Runs the body of a fresh coroutine, on its own host stack. Errors are
    /// parked on the coroutine; `coroutine.close`'s request is not an error.
    fn runCoroutineBody(vm: *VM, coroutine: *Coroutine) void {
        const arguments = coroutine.transfer;
        coroutine.transfer = &.{};
        const results = vm.invokeCallableValues(coroutine.body, arguments) catch |err| {
            if (arguments.len != 0) vm.allocator.free(arguments);
            // whatever a resume handed the yield that was running is dead now
            if (coroutine.transfer.len != 0) {
                vm.allocator.free(coroutine.transfer);
                coroutine.transfer = &.{};
            }
            if (err != error.CoroutineClose) {
                coroutine.error_value = vm.exec.thrown_error orelse vm.runtimeErrorValue();
            }
            return;
        };
        if (arguments.len != 0) vm.allocator.free(arguments);
        if (coroutine.transfer.len != 0) vm.allocator.free(coroutine.transfer);
        coroutine.transfer = results;
    }

    fn runtimeErrorValue(vm: *VM) Value {
        return .{ .string = vm.interner.intern("runtime error") catch return .nil };
    }

    fn destroyCoroutine(vm: *VM, coroutine: *Coroutine) void {
        if (coroutine.stack) |stack| vm.allocator.free(stack);
        if (coroutine.transfer.len != 0) vm.allocator.free(coroutine.transfer);
        vm.tracker.free(coroutine.object);
        // The running state's lists are the VM's own (see `deinit`); only a
        // parked coroutine owns a separate set.
        if (coroutine != vm.exec.coroutine) {
            coroutine.state.error_frames.deinit(vm.allocator);
            coroutine.state.active_functions.deinit(vm.allocator);
            coroutine.state.suspended_locals.deinit(vm.allocator);
            coroutine.state.suspended_varargs.deinit(vm.allocator);
            coroutine.state.suspended_results.deinit(vm.allocator);
            coroutine.state.results.deinit(vm.allocator);
            coroutine.state.close_values.deinit(vm.allocator);
        }
        vm.allocator.destroy(coroutine);
    }

    fn stringLen(vm: *VM, args: []const Value) Error![]Value {
        // `luaL_checklstring` reads a number as the string it writes out
        const bytes = try vm.checkString(args, 1, "len", "string.len");
        const len = std.math.cast(i64, bytes.len) orelse return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{.{ .number = Number.Number.fromInt(len) }}) catch return error.OutOfMemory;
    }

    fn stringSub(vm: *VM, args: []const Value) Error![]Value {
        const short = "sub";
        const long = "string.sub";
        const bytes = try vm.checkString(args, 1, short, long);
        const len = std.math.cast(i64, bytes.len) orelse return error.RuntimeError;
        const raw_first = try vm.checkInteger(args, 2, short, long);
        const raw_last = try vm.optInteger(args, 3, -1, short, long);
        const first = relativeStringIndex(raw_first, len);
        const last = relativeStringIndex(raw_last, len);
        if (first > last or first > len or last < 1) {
            const empty = vm.interner.intern("") catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = empty }}) catch return error.OutOfMemory;
        }
        const start: usize = @intCast(@max(first, 1) - 1);
        const end: usize = @intCast(@min(last, len));
        const slice = if (start >= end) "" else bytes[start..end];
        const string = vm.interner.intern(slice) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn relativeStringIndex(index: i64, len: i64) i64 {
        if (index >= 0) return index;
        return @max(0, @addWithOverflow(index, len + 1)[0]);
    }

    fn stringRep(vm: *VM, args: []const Value) Error![]Value {
        const short = "rep";
        const long = "string.rep";
        const bytes = try vm.checkString(args, 1, short, long);
        const count = try vm.checkInteger(args, 2, short, long);
        const separator = try vm.optString(args, 3, "", short, long);
        if (count <= 0) {
            const empty = vm.interner.intern("") catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = empty }}) catch return error.OutOfMemory;
        }
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        var i: i64 = 0;
        while (i < count) : (i += 1) {
            try vm.tick();
            if (i != 0) output.appendSlice(vm.allocator, separator) catch return error.OutOfMemory;
            output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
        }
        const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringReverse(vm: *VM, args: []const Value) Error![]Value {
        const bytes = try vm.checkString(args, 1, "reverse", "string.reverse");
        const reversed = vm.allocator.alloc(u8, bytes.len) catch return error.OutOfMemory;
        defer vm.allocator.free(reversed);
        for (bytes, 0..) |byte, i| reversed[bytes.len - i - 1] = byte;
        const string = vm.interner.intern(reversed) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringCase(vm: *VM, args: []const Value, uppercase: bool) Error![]Value {
        const name: []const u8 = if (uppercase) "upper" else "lower";
        const bytes = try vm.checkString(args, 1, name, if (uppercase) "string.upper" else "string.lower");
        const changed = vm.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        defer vm.allocator.free(changed);
        for (changed) |*byte| byte.* = if (uppercase) std.ascii.toUpper(byte.*) else std.ascii.toLower(byte.*);
        const string = vm.interner.intern(changed) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringByte(vm: *VM, args: []const Value) Error![]Value {
        const short = "byte";
        const long = "string.byte";
        const bytes = try vm.checkString(args, 1, short, long);
        const len = std.math.cast(i64, bytes.len) orelse return error.RuntimeError;
        const raw_first = try vm.optInteger(args, 2, 1, short, long);
        const raw_last = try vm.optInteger(args, 3, raw_first, short, long);
        const first = relativeStringIndex(raw_first, len);
        const last = relativeStringIndex(raw_last, len);
        if (first > last or first > len or last < 1) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const start = @max(first, 1);
        const end = @min(last, len);
        if (start > end) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const count: usize = @intCast(end - start + 1);
        const values = vm.allocator.alloc(Value, count) catch return error.OutOfMemory;
        for (values, 0..) |*value, offset| value.* = .{ .number = Number.Number.fromInt(bytes[@intCast(start - 1 + @as(i64, @intCast(offset)))]) };
        return values;
    }

    fn stringChar(vm: *VM, args: []const Value) Error![]Value {
        const short = "char";
        const long = "string.char";
        const bytes = vm.allocator.alloc(u8, args.len) catch return error.OutOfMemory;
        defer vm.allocator.free(bytes);
        for (args, 0..) |_, i| {
            const code = try vm.checkInteger(args, i + 1, short, long);
            // `luaL_argcheck` after the cast to an unsigned, so a negative
            // argument lands on the same refusal as one past 255
            const unsigned: u64 = @bitCast(@as(i64, code));
            if (unsigned > 255) return vm.raiseArgument(i + 1, short, long, "value out of range", .{});
            bytes[i] = @intCast(code);
        }
        const string = vm.interner.intern(bytes) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringFind(vm: *VM, args: []const Value) Error![]Value {
        const short = "find";
        const long = "string.find";
        const source = try vm.checkString(args, 1, short, long);
        const pattern = try vm.checkString(args, 2, short, long);
        const source_len = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const raw_init = try vm.optInteger(args, 3, 1, short, long);
        const start_index = if (raw_init < 0) @max(1, @addWithOverflow(raw_init, source_len + 1)[0]) else raw_init;
        // a fourth argument is taken as plain whatever it is, the way
        // `lua_toboolean` reads it
        const plain = args.len > 3 and args[3] != .nil and (args[3] != .boolean or args[3].boolean);
        const start: usize = @intCast(@min(@max(start_index, 1) - 1, source_len));
        if (start_index <= source_len + 1) {
            // `str_find_aux`: a pattern without specials is searched for
            // plainly whether or not the plain argument was given, which is
            // why `find("abc", ")")` finds nothing rather than reaching the
            // matcher and refusing the unopened capture
            const special = std.mem.indexOfAny(u8, pattern, "^$*+?.([%-") != null;
            const found = if (plain or !special) blk: {
                if (std.mem.indexOfPos(u8, source, start, pattern)) |position| break :blk Pattern.Result{
                    .start = position,
                    .end = position + pattern.len,
                    .captures = undefined,
                    .capture_count = 0,
                };
                break :blk null;
            } else switch (Pattern.find(source, pattern, start)) {
                .found => |result| result,
                .absent => null,
                .failed => |failure| return vm.patternError(failure),
            };
            if (found) |result| {
                // captures are pushed all at once, so the first unfinished
                // one among them is refused before any value comes back
                if (hasUnfinishedCapture(result.captures[0..result.capture_count])) return vm.patternError(.{ .kind = .unfinished_capture });
                const extra = if (result.capture_count == 0) 0 else result.capture_count;
                const values = vm.allocator.alloc(Value, 2 + extra) catch return error.OutOfMemory;
                values[0] = .{ .number = Number.Number.fromInt(@intCast(result.start + 1)) };
                values[1] = .{ .number = Number.Number.fromInt(@intCast(result.end)) };
                for (result.captures[0..result.capture_count], 0..) |capture, i| values[i + 2] = try vm.patternCapture(source, capture);
                return values;
            }
        }
        // no match is a nil rather than a false, which is what `find` hands
        // back — `match` is written the same way further down
        return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
    }

    fn stringMatch(vm: *VM, args: []const Value) Error![]Value {
        const short = "match";
        const long = "string.match";
        const source = try vm.checkString(args, 1, short, long);
        const pattern = try vm.checkString(args, 2, short, long);
        const len = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const raw_init = try vm.optInteger(args, 3, 1, short, long);
        const start_index = if (raw_init < 0) @max(1, @addWithOverflow(raw_init, len + 1)[0]) else raw_init;
        if (start_index > len + 1) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const start: usize = @intCast(@min(@max(start_index, 1) - 1, len));
        const found = switch (Pattern.find(source, pattern, start)) {
            .found => |result| result,
            .absent => return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory,
            .failed => |failure| return vm.patternError(failure),
        };
        if (hasUnfinishedCapture(found.captures[0..found.capture_count])) return vm.patternError(.{ .kind = .unfinished_capture });
        if (found.capture_count == 0) {
            const matched = vm.interner.intern(source[found.start..found.end]) catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = matched }}) catch return error.OutOfMemory;
        }
        const values = vm.allocator.alloc(Value, found.capture_count) catch return error.OutOfMemory;
        for (found.captures[0..found.capture_count], 0..) |capture, i| values[i] = try vm.patternCapture(source, capture);
        return values;
    }

    /// `string.gmatch` hands back one stateful closure, not the three values a
    /// generic for would rather have: the state rides in the closure's `bound`
    /// the same way `coroutine.wrap` carries its thread, so `it()` with no
    /// arguments works and the for-loop's own state and control values are
    /// passed through and ignored.
    fn stringGmatch(vm: *VM, args: []const Value) Error![]Value {
        const short = "gmatch";
        const long = "string.gmatch";
        const source = vm.interner.intern(try vm.checkString(args, 1, short, long)) catch return error.OutOfMemory;
        const pattern = vm.interner.intern(try vm.checkString(args, 2, short, long)) catch return error.OutOfMemory;
        const state = try vm.newTable();
        try vm.setStringField(state, "source", .{ .string = source });
        try vm.setStringField(state, "pattern", .{ .string = pattern });
        try vm.setStringField(state, "position", .{ .number = Number.Number.fromInt(0) });
        const function = vm.tracker.alloc(ValueModule.Function, .function) catch return error.OutOfMemory;
        errdefer vm.tracker.free(function);
        function.semantics = vm.exec.semantics;
        function.body = &vm.wrapper_body;
        function.function_index = 0;
        function.captures = &.{};
        function.environment = vm.exec.active_environment;
        function.native = .string_gmatch_iterator;
        function.bound = .{ .table = state };
        vm.owned_functions.append(vm.allocator, function) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .function = function }}) catch return error.OutOfMemory;
    }

    fn stringGmatchIterator(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .table) return error.RuntimeError;
        const state = args[0].table;
        const source_value = try vm.getStringField(state, "source");
        const pattern_value = try vm.getStringField(state, "pattern");
        const position_value = try vm.getStringField(state, "position");
        if (source_value != .string or pattern_value != .string or position_value != .number) return error.RuntimeError;
        const source = source_value.string.slice();
        const position = try intArgument(position_value);
        if (position < 0 or position > source.len) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const result = switch (Pattern.find(source, pattern_value.string.slice(), @intCast(position))) {
            .found => |found| found,
            .absent => return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory,
            .failed => |failure| return vm.patternError(failure),
        };
        if (hasUnfinishedCapture(result.captures[0..result.capture_count])) return vm.patternError(.{ .kind = .unfinished_capture });
        const next_position = if (result.end == result.start) result.end + 1 else result.end;
        try vm.setStringField(state, "position", .{ .number = Number.Number.fromInt(@intCast(next_position)) });
        if (result.capture_count == 0) {
            const string = vm.interner.intern(source[result.start..result.end]) catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
        }
        const values = vm.allocator.alloc(Value, result.capture_count) catch return error.OutOfMemory;
        for (result.captures[0..result.capture_count], 0..) |capture, i| values[i] = try vm.patternCapture(source, capture);
        return values;
    }

    fn stringGsub(vm: *VM, args: []const Value) Error![]Value {
        const short = "gsub";
        const long = "string.gsub";
        // interned so that reading the replacement cannot disturb the bytes
        const held_source = vm.interner.intern(try vm.checkString(args, 1, short, long)) catch return error.OutOfMemory;
        const held_pattern = vm.interner.intern(try vm.checkString(args, 2, short, long)) catch return error.OutOfMemory;
        const source = held_source.slice();
        const pattern = held_pattern.slice();
        // the replacement is checked up front, before any matching happens
        const replacement = if (args.len >= 3) args[2] else return vm.typeError(3, short, long, "string/function/table", null);
        switch (replacement) {
            .string, .number, .function, .native_function, .table => {},
            else => return vm.typeError(3, short, long, "string/function/table", replacement),
        }
        const max_replacements = try vm.optInteger(args, 4, @as(i64, std.math.cast(i64, source.len) orelse return error.RuntimeError) + 1, short, long);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        var search: usize = 0;
        var copied: usize = 0;
        var replacements: i64 = 0;
        while (search <= source.len and replacements < max_replacements) {
            try vm.tick();
            const result = switch (Pattern.find(source, pattern, search)) {
                .found => |found| found,
                .absent => break,
                .failed => |failure| return vm.patternError(failure),
            };
            output.appendSlice(vm.allocator, source[copied..result.start]) catch return error.OutOfMemory;
            try vm.appendGsubReplacement(&output, source, result, replacement);
            replacements += 1;
            copied = result.end;
            if (result.end == result.start) {
                if (result.end == source.len) {
                    search = source.len + 1;
                } else {
                    output.append(vm.allocator, source[result.end]) catch return error.OutOfMemory;
                    copied = result.end + 1;
                    search = result.end + 1;
                }
            } else search = result.end;
        }
        output.appendSlice(vm.allocator, source[copied..]) catch return error.OutOfMemory;
        const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
        const values = vm.allocator.alloc(Value, 2) catch return error.OutOfMemory;
        values[0] = .{ .string = string };
        values[1] = .{ .number = Number.Number.fromInt(replacements) };
        return values;
    }

    fn appendGsubReplacement(vm: *VM, output: *std.ArrayList(u8), source: []const u8, result: Pattern.Result, replacement: Value) Error!void {
        const whole = source[result.start..result.end];
        const captures = result.captures[0..result.capture_count];
        if (replacement == .string) return vm.appendGsubTemplate(output, source, result, replacement.string.slice());
        // a number is written out the way `luaL_addvalue` writes it
        if (replacement == .number) return vm.appendReplacementValue(output, replacement);

        var value: Value = .nil;
        if (replacement == .table) {
            // `push_onecapture(ms, 0, ...)`: with no captures the whole match
            // is the index, and the first capture is refused if still open
            if (captures.len != 0 and captures[0].unfinished) return vm.patternError(.{ .kind = .unfinished_capture });
            const key = if (captures.len != 0) try vm.patternCapture(source, captures[0]) else Value{ .string = vm.interner.intern(whole) catch return error.OutOfMemory };
            value = try vm.getTableIndex(replacement, key, "");
        } else if (replacement == .function or replacement == .native_function) {
            // `push_captures` pushes them all, so any still open is refused
            if (hasUnfinishedCapture(captures)) return vm.patternError(.{ .kind = .unfinished_capture });
            const call_args = if (captures.len == 0) blk: {
                const matched = vm.interner.intern(whole) catch return error.OutOfMemory;
                break :blk &[_]Value{.{ .string = matched }};
            } else blk: {
                const values = vm.allocator.alloc(Value, captures.len) catch return error.OutOfMemory;
                for (captures, 0..) |capture, i| values[i] = try vm.patternCapture(source, capture);
                break :blk values;
            };
            defer if (captures.len != 0) vm.allocator.free(@constCast(call_args));
            const returned = try vm.invokeCallableValues(replacement, call_args);
            defer vm.allocator.free(returned);
            value = if (returned.len == 0) .nil else returned[0];
        } else return error.RuntimeError;

        if (value == .nil or (value == .boolean and !value.boolean)) {
            output.appendSlice(vm.allocator, whole) catch return error.OutOfMemory;
        } else switch (value) {
            .string, .number => try vm.appendReplacementValue(output, value),
            // `add_value` refuses whatever `lua_isstring` does not take, which
            // is everything else a table lookup or the call came back with
            else => return vm.raise("invalid replacement value (a {s})", .{value.typeName()}),
        }
    }

    fn appendGsubTemplate(vm: *VM, output: *std.ArrayList(u8), source: []const u8, result: Pattern.Result, template: []const u8) Error!void {
        var i: usize = 0;
        while (i < template.len) {
            if (template[i] != '%') {
                output.append(vm.allocator, template[i]) catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            // a '%' the reference cannot read — at the end or before
            // something that is neither '%' nor a digit — is refused as an
            // invalid use of it in the replacement string
            if (i + 1 >= template.len) return vm.raise("invalid use of '%' in replacement string", .{});
            const replacement = template[i + 1];
            if (replacement == '%') {
                output.append(vm.allocator, '%') catch return error.OutOfMemory;
            } else if (replacement == '0') {
                output.appendSlice(vm.allocator, source[result.start..result.end]) catch return error.OutOfMemory;
            } else if (replacement >= '1' and replacement <= '9') {
                const capture_index: usize = replacement - '1';
                if (capture_index >= result.capture_count) {
                    // `get_onecapture` answers with the whole match for
                    // index zero and refuses any other index past the captures
                    if (capture_index != 0) return vm.patternError(.{ .kind = .invalid_capture_index, .index = @intCast(capture_index + 1) });
                    output.appendSlice(vm.allocator, source[result.start..result.end]) catch return error.OutOfMemory;
                } else {
                    const capture = result.captures[capture_index];
                    if (capture.unfinished) return vm.patternError(.{ .kind = .unfinished_capture });
                    const value = try vm.patternCapture(source, capture);
                    try vm.appendReplacementValue(output, value);
                }
            } else return vm.raise("invalid use of '%' in replacement string", .{});
            i += 2;
        }
    }

    fn appendReplacementValue(vm: *VM, output: *std.ArrayList(u8), value: Value) Error!void {
        var buffer: [64]u8 = undefined;
        const bytes = try vm.stringBytesInto(value, &buffer);
        output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
    }

    const PackKind = enum { signed, unsigned, float32, float64, fixed_string, zero_string, sized_string, padding, align_only };
    const PackSpec = struct { kind: PackKind, size: usize, alignment: usize, prefix_size: usize = 0 };
    const PackOption = struct { kind: PackKind, size: usize, control: bool = false };
    const PackFormat = struct {
        source: []const u8,
        short: []const u8,
        long: []const u8,
        index: usize = 0,
        little_endian: bool = @import("builtin").cpu.arch.endian() == .little,
        // `initheader` starts the alignment at one, so nothing is aligned
        // before a '!' option says otherwise.
        max_alignment: usize = 1,

        /// `getnum`: digits are accumulated only while the running value still
        /// fits, so a longer run is left partly for the next option.
        fn parseNumber(format: *PackFormat) ?i64 {
            if (format.index >= format.source.len or !std.ascii.isDigit(format.source[format.index])) return null;
            var value: i64 = format.source[format.index] - '0';
            format.index += 1;
            while (format.index < format.source.len and
                std.ascii.isDigit(format.source[format.index]) and value <= 214748363)
            {
                value = value * 10 + (format.source[format.index] - '0');
                format.index += 1;
            }
            return value;
        }

        /// `getnumlimit`: a size that has to lie in [1, 16].
        fn limit(format: *PackFormat, vm: *VM, default: i64) Error!usize {
            const size = format.parseNumber() orelse default;
            if (size > 16 or size <= 0) return vm.raise("integral size ({d}) out of limits [1,16]", .{size});
            return @intCast(size);
        }

        /// `getoption`: exactly one option character, with the side effects a
        /// header option has. `control` marks the ones that pack nothing.
        fn option(format: *PackFormat, vm: *VM) Error!PackOption {
            const option_character = format.source[format.index];
            format.index += 1;
            return switch (option_character) {
                ' ', '\t', '\n', '\r', '\x0b', '\x0c' => .{ .kind = .padding, .size = 0, .control = true },
                '<' => blk: {
                    format.little_endian = true;
                    break :blk .{ .kind = .padding, .size = 0, .control = true };
                },
                '>' => blk: {
                    format.little_endian = false;
                    break :blk .{ .kind = .padding, .size = 0, .control = true };
                },
                '=' => blk: {
                    format.little_endian = @import("builtin").cpu.arch.endian() == .little;
                    break :blk .{ .kind = .padding, .size = 0, .control = true };
                },
                '!' => blk: {
                    // `offsetof(struct cD, u)` over `LUAI_MAXALIGN`, whose
                    // members all ask for eight bytes on this target.
                    format.max_alignment = try format.limit(vm, @alignOf(c_long));
                    break :blk .{ .kind = .padding, .size = 0, .control = true };
                },
                'x' => .{ .kind = .padding, .size = 1 },
                'X' => .{ .kind = .align_only, .size = 0 },
                'b' => .{ .kind = .signed, .size = 1 },
                'B' => .{ .kind = .unsigned, .size = 1 },
                'h' => .{ .kind = .signed, .size = @sizeOf(c_short) },
                'H' => .{ .kind = .unsigned, .size = @sizeOf(c_short) },
                'l' => .{ .kind = .signed, .size = @sizeOf(c_long) },
                'L' => .{ .kind = .unsigned, .size = @sizeOf(c_long) },
                'j' => .{ .kind = .signed, .size = @sizeOf(i64) },
                'J' => .{ .kind = .unsigned, .size = @sizeOf(u64) },
                'T' => .{ .kind = .unsigned, .size = @sizeOf(usize) },
                'i' => .{ .kind = .signed, .size = try format.limit(vm, @sizeOf(c_int)) },
                'I' => .{ .kind = .unsigned, .size = try format.limit(vm, @sizeOf(c_int)) },
                'f' => .{ .kind = .float32, .size = @sizeOf(f32) },
                'd', 'n' => .{ .kind = .float64, .size = @sizeOf(f64) },
                // the size of 's' is the length prefix, of 'c' the string length
                'c' => .{
                    .kind = .fixed_string,
                    .size = @intCast(format.parseNumber() orelse return vm.raise("missing size for format option 'c'", .{})),
                },
                'z' => .{ .kind = .zero_string, .size = 0 },
                's' => .{ .kind = .sized_string, .size = try format.limit(vm, @sizeOf(usize)) },
                else => return vm.raise("invalid format option '{c}'", .{option_character}),
            };
        }

        /// `getdetails`: one option plus the padding it asks for.
        fn next(format: *PackFormat, vm: *VM) Error!?PackSpec {
            while (format.index < format.source.len) {
                const choice = try format.option(vm);
                if (choice.control) continue;
                const raw_alignment = if (choice.kind == .align_only) blk: {
                    // 'X' takes its alignment from the option that follows it
                    if (format.index >= format.source.len)
                        return vm.raiseArgument(1, format.short, format.long, "invalid next option for option 'X'", .{});
                    const followed = try format.option(vm);
                    if (followed.control or followed.size == 0 or followed.kind == .fixed_string)
                        return vm.raiseArgument(1, format.short, format.long, "invalid next option for option 'X'", .{});
                    break :blk followed.size;
                } else choice.size;
                return .{
                    .kind = choice.kind,
                    .size = choice.size,
                    .prefix_size = if (choice.kind == .sized_string) choice.size else 0,
                    .alignment = try format.alignedSize(vm, choice.kind, raw_alignment),
                };
            }
            return null;
        }

        /// `getdetails`'s alignment rules: an option of size one or less, and a
        /// fixed-size string, never align; anything else is clamped to the
        /// header's maximum, which has to be a power of two.
        fn alignedSize(format: *PackFormat, vm: *VM, kind: PackKind, size: usize) Error!usize {
            if (size <= 1 or kind == .fixed_string) return 1;
            const clamped = @min(size, format.max_alignment);
            if (clamped & (clamped - 1) != 0)
                return vm.raiseArgument(1, format.short, format.long, "format asks for alignment not power of 2", .{});
            return clamped;
        }
    };

    fn packPadding(position: usize, alignment: usize) usize {
        return (alignment - position % alignment) % alignment;
    }

    fn appendPackedInteger(vm: *VM, output: *std.ArrayList(u8), number: u128, size: usize, little_endian: bool) Error!void {
        for (0..size) |i| {
            const significant = if (little_endian) i else size - i - 1;
            const shift: u7 = @intCast(significant * 8);
            output.append(vm.allocator, @truncate(number >> shift)) catch return error.OutOfMemory;
        }
    }

    /// `unpackint`: reads a little- or big-endian integer of `size` bytes,
    /// sign-extending what it holds, and refusing the ones whose unread bytes
    /// do not agree with its sign.
    fn unpackInteger(vm: *VM, bytes: []const u8, position: usize, size: usize, little_endian: bool, signed: bool) Error!i64 {
        const limit = @min(size, 8);
        var result: u64 = 0;
        var index = limit;
        while (index > 0) {
            index -= 1;
            result = (result << 8) | bytes[position + (if (little_endian) index else size - 1 - index)];
        }
        if (size < 8) {
            if (signed) {
                const mask: u64 = @as(u64, 1) << @intCast(size * 8 - 1);
                result = (result ^ mask) -% mask;
            }
        } else if (size > 8) {
            const mask: u8 = if (!signed or @as(i64, @bitCast(result)) >= 0) 0 else 0xff;
            for (limit..size) |i| {
                if (bytes[position + (if (little_endian) i else size - 1 - i)] != mask)
                    return vm.raise("{d}-byte integer does not fit into Lua Integer", .{size});
            }
        }
        return @bitCast(result);
    }

    fn readPackedInteger(bytes: []const u8, position: usize, size: usize, little_endian: bool) u64 {
        var result: u64 = 0;
        for (0..size) |i| {
            const source = if (little_endian) i else size - i - 1;
            result |= @as(u64, bytes[position + source]) << @intCast(i * 8);
        }
        return result;
    }

    fn stringPack(vm: *VM, args: []const Value) Error![]Value {
        const short = "pack";
        const long = "string.pack";
        const format_text = try vm.checkString(args, 1, short, long);
        var format: PackFormat = .{ .source = format_text, .short = short, .long = long };
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        // `str_pack` leaves a nil behind its values to separate them from the
        // buffer, so a value that was never passed still reads as a nil there
        const stack = vm.allocator.alloc(Value, args.len + 1) catch return error.OutOfMemory;
        defer vm.allocator.free(stack);
        @memcpy(stack[0..args.len], args);
        stack[args.len] = .nil;
        // the format is argument one, so the values start at two
        var argument: usize = 2;
        while (try format.next(vm)) |spec| {
            const padding = packPadding(output.items.len, spec.alignment);
            try output.appendNTimes(vm.allocator, 0, padding);
            switch (spec.kind) {
                .padding => try output.appendNTimes(vm.allocator, 0, spec.size),
                .align_only => {},
                .signed => {
                    const integer = try vm.checkInteger(stack, argument, short, long);
                    if (spec.size < 8) {
                        const limit: i128 = @as(i128, 1) << @intCast(spec.size * 8 - 1);
                        if (integer < -limit or integer >= limit)
                            return vm.raiseArgument(argument, short, long, "integer overflow", .{});
                    }
                    try vm.appendPackedInteger(&output, @bitCast(@as(i128, integer)), spec.size, format.little_endian);
                    argument += 1;
                },
                .unsigned => {
                    const integer = try vm.checkInteger(stack, argument, short, long);
                    const unsigned: u64 = @bitCast(integer);
                    if (spec.size < 8 and unsigned >= (@as(u64, 1) << @intCast(spec.size * 8)))
                        return vm.raiseArgument(argument, short, long, "unsigned overflow", .{});
                    try vm.appendPackedInteger(&output, unsigned, spec.size, format.little_endian);
                    argument += 1;
                },
                .float32 => {
                    const number = try vm.checkNumber(stack, argument, short, long);
                    const bits: u32 = @bitCast(@as(f32, @floatCast(number.toFloat())));
                    try vm.appendPackedInteger(&output, bits, spec.size, format.little_endian);
                    argument += 1;
                },
                .float64 => {
                    const number = try vm.checkNumber(stack, argument, short, long);
                    const bits: u64 = @bitCast(number.toFloat());
                    try vm.appendPackedInteger(&output, bits, spec.size, format.little_endian);
                    argument += 1;
                },
                .fixed_string => {
                    const bytes = try vm.checkString(stack, argument, short, long);
                    if (bytes.len > spec.size)
                        return vm.raiseArgument(argument, short, long, "string longer than given size", .{});
                    output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                    try output.appendNTimes(vm.allocator, 0, spec.size - bytes.len);
                    argument += 1;
                },
                .zero_string => {
                    const bytes = try vm.checkString(stack, argument, short, long);
                    if (std.mem.indexOfScalar(u8, bytes, 0) != null)
                        return vm.raiseArgument(argument, short, long, "string contains zeros", .{});
                    output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                    output.append(vm.allocator, 0) catch return error.OutOfMemory;
                    argument += 1;
                },
                .sized_string => {
                    const bytes = try vm.checkString(stack, argument, short, long);
                    const length: u128 = bytes.len;
                    if (spec.prefix_size < 8 and length >= (@as(u128, 1) << @intCast(spec.prefix_size * 8)))
                        return vm.raiseArgument(argument, short, long, "string length does not fit in given size", .{});
                    try vm.appendPackedInteger(&output, length, spec.prefix_size, format.little_endian);
                    output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                    argument += 1;
                },
            }
        }
        const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringPackSize(vm: *VM, args: []const Value) Error![]Value {
        const short = "packsize";
        const long = "string.packsize";
        const format_text = try vm.checkString(args, 1, short, long);
        var format: PackFormat = .{ .source = format_text, .short = short, .long = long };
        var size: usize = 0;
        while (try format.next(vm)) |spec| {
            if (spec.kind == .zero_string or spec.kind == .sized_string)
                return vm.raiseArgument(1, short, long, "variable-length format", .{});
            size += packPadding(size, spec.alignment) + spec.size;
            if (size > std.math.maxInt(i32)) return vm.raiseArgument(1, short, long, "format result too large", .{});
        }
        return vm.singleNumber(Number.Number.fromInt(@intCast(size)));
    }

    fn stringUnpack(vm: *VM, args: []const Value) Error![]Value {
        const short = "unpack";
        const long = "string.unpack";
        const format_text = try vm.checkString(args, 1, short, long);
        const bytes = try vm.checkString(args, 2, short, long);
        // `posrelatI`: a positive position is itself, zero is one, and a
        // negative one counts back from the end but is clipped to one.
        const raw_position = try vm.optInteger(args, 3, 1, short, long);
        const length: i64 = std.math.cast(i64, bytes.len) orelse return error.RuntimeError;
        const position: i64 = if (raw_position > 0)
            raw_position
        else if (raw_position == 0)
            1
        else if (raw_position < -length)
            1
        else
            length + raw_position + 1;
        if (position - 1 > length) return vm.raiseArgument(3, short, long, "initial position out of string", .{});
        var cursor: usize = @intCast(position - 1);
        var format: PackFormat = .{ .source = format_text, .short = short, .long = long };
        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(vm.allocator);
        while (try format.next(vm)) |spec| {
            const padding_offset = packPadding(cursor, spec.alignment);
            if (padding_offset + spec.size > bytes.len - cursor)
                return vm.raiseArgument(2, short, long, "data string too short", .{});
            cursor += padding_offset;
            switch (spec.kind) {
                .signed, .unsigned => {
                    const integer = try unpackInteger(vm, bytes, cursor, spec.size, format.little_endian, spec.kind == .signed);
                    try values.append(vm.allocator, .{ .number = Number.Number.fromInt(integer) });
                    cursor += spec.size;
                },
                .float32 => {
                    const bits: u32 = @truncate(readPackedInteger(bytes, cursor, spec.size, format.little_endian));
                    try values.append(vm.allocator, .{ .number = Number.Number.fromFloat(@as(f64, @floatCast(@as(f32, @bitCast(bits))))) });
                    cursor += spec.size;
                },
                .float64 => {
                    const bits = readPackedInteger(bytes, cursor, spec.size, format.little_endian);
                    try values.append(vm.allocator, .{ .number = Number.Number.fromFloat(@bitCast(bits)) });
                    cursor += spec.size;
                },
                .fixed_string => {
                    const string = vm.interner.intern(bytes[cursor .. cursor + spec.size]) catch return error.OutOfMemory;
                    try values.append(vm.allocator, .{ .string = string });
                    cursor += spec.size;
                },
                .zero_string => {
                    const end = std.mem.indexOfScalarPos(u8, bytes, cursor, 0) orelse
                        return vm.raiseArgument(2, short, long, "unfinished string for format 'z'", .{});
                    const string = vm.interner.intern(bytes[cursor..end]) catch return error.OutOfMemory;
                    try values.append(vm.allocator, .{ .string = string });
                    cursor = end + 1;
                },
                .sized_string => {
                    const prefix = try unpackInteger(vm, bytes, cursor, spec.prefix_size, format.little_endian, false);
                    const available = bytes.len - cursor - spec.prefix_size;
                    if (prefix < 0 or @as(u64, @bitCast(prefix)) > available)
                        return vm.raiseArgument(2, short, long, "data string too short", .{});
                    const len: usize = @intCast(prefix);
                    const start = cursor + spec.prefix_size;
                    const string = vm.interner.intern(bytes[start .. start + len]) catch return error.OutOfMemory;
                    try values.append(vm.allocator, .{ .string = string });
                    cursor = start + len;
                },
                .padding => {
                    cursor += spec.size;
                },
                .align_only => {},
            }
        }
        try values.append(vm.allocator, .{ .number = Number.Number.fromInt(@intCast(cursor + 1)) });
        return vm.allocator.dupe(Value, values.items) catch return error.OutOfMemory;
    }

    /// `str_dump`. The reference refuses a C function with "unable to dump
    /// given function" and otherwise writes a bytecode prelude; lualite has
    /// no bytecode writer, so every function — a closure or a native one,
    /// since both pass `luaL_checktype(..., LUA_TFUNCTION)` — meets that same
    /// refusal. A positioned raise, since `luaL_error` is what reports it.
    fn stringDump(vm: *VM, args: []const Value) Error![]Value {
        const short = "dump";
        const long = "string.dump";
        if (args.len < 1) return vm.typeError(1, short, long, "function", null);
        switch (args[0]) {
            .function, .native_function => return vm.raise("unable to dump given function", .{}),
            else => return vm.typeError(1, short, long, "function", args[0]),
        }
    }

    fn stringFormat(vm: *VM, args: []const Value) Error![]Value {
        const short = "format";
        const long = "string.format";
        const format = try vm.checkString(args, 1, short, long);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        // the format itself is argument one, so the values start at two
        var consumed: usize = 0;
        var i: usize = 0;
        while (i < format.len) {
            if (format[i] != '%') {
                output.append(vm.allocator, format[i]) catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            i += 1;
            if (i < format.len and format[i] == '%') {
                output.append(vm.allocator, '%') catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            // a format item takes its value before it is even looked at
            const argument = consumed + 2;
            if (argument > args.len) return vm.raiseArgument(argument, short, long, "no value", .{});
            consumed += 1;
            // `getformat`: spans the flags, width and precision, and then takes
            // the conversion character that follows them.
            const item_start = i;
            while (i < format.len and (std.mem.indexOfScalar(u8, "-+#0 ", format[i]) != null or
                std.ascii.isDigit(format[i]) or format[i] == '.')) i += 1;
            if (i - item_start >= 21) return vm.raise("invalid format (too long)", .{});
            const conversion = format[item_start - 1 .. @min(i + 1, format.len)];
            const specifier: u8 = if (i < format.len) blk: {
                const specifier = format[i];
                i += 1;
                break :blk specifier;
            } else 0;
            const value = args[argument - 1];
            switch (specifier) {
                'c' => {
                    try vm.formatCheck(conversion, "-", false);
                    const integer = try vm.checkInteger(args, argument, short, long);
                    try vm.appendNumericFormat(&output, .{ .number = Number.Number.fromInt(integer) }, conversion, specifier);
                },
                // for the integer conversions `checkformat` comes second, the
                // way `str_format` reads its argument first
                'd', 'i' => {
                    const integer = try vm.checkInteger(args, argument, short, long);
                    try vm.formatCheck(conversion, "-+0 ", true);
                    try vm.appendNumericFormat(&output, .{ .number = Number.Number.fromInt(integer) }, conversion, specifier);
                },
                'u' => {
                    const integer = try vm.checkInteger(args, argument, short, long);
                    try vm.formatCheck(conversion, "-0", true);
                    try vm.appendNumericFormat(&output, .{ .number = Number.Number.fromInt(integer) }, conversion, specifier);
                },
                'o', 'x', 'X' => {
                    const integer = try vm.checkInteger(args, argument, short, long);
                    try vm.formatCheck(conversion, "-#0", true);
                    try vm.appendNumericFormat(&output, .{ .number = Number.Number.fromInt(integer) }, conversion, specifier);
                },
                'a', 'A' => {
                    try vm.formatCheck(conversion, "-+#0 ", true);
                    const number = try vm.checkNumber(args, argument, short, long);
                    try vm.appendNumericFormat(&output, .{ .number = number }, conversion, specifier);
                },
                'f', 'e', 'E', 'g', 'G' => {
                    const number = try vm.checkNumber(args, argument, short, long);
                    try vm.formatCheck(conversion, "-+#0 ", true);
                    try vm.appendNumericFormat(&output, .{ .number = number }, conversion, specifier);
                },
                'p' => {
                    try vm.formatCheck(conversion, "-", false);
                    try vm.appendNumericFormat(&output, value, conversion, specifier);
                },
                'q' => {
                    // `addliteral`: strings and numbers have a literal form,
                    // nil and booleans are written out by `luaL_tolstring`
                    if (conversion.len != 2) return vm.raise("specifier '%q' cannot have modifiers", .{});
                    switch (value) {
                        .string => |string| try vm.appendQuoted(&output, string.slice()),
                        .number => |number| try vm.appendQuotedNumber(&output, number),
                        .nil, .boolean => try vm.appendTolstring(&output, value),
                        else => return vm.raiseArgument(argument, short, long, "value has no literal form", .{}),
                    }
                },
                's' => {
                    // `luaL_tolstring`: a string is used as it is, and anything
                    // else goes through `tostring`
                    var owned: ?[]Value = null;
                    defer if (owned) |results| vm.allocator.free(results);
                    const bytes = if (value == .string) value.string.slice() else blk: {
                        const results = try vm.baseToString(&.{value});
                        owned = results;
                        break :blk results[0].string.slice();
                    };
                    if (conversion.len == 2) {
                        output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                    } else {
                        if (std.mem.indexOfScalar(u8, bytes, 0) != null)
                            return vm.raiseArgument(argument, short, long, "string contains zeros", .{});
                        try vm.formatCheck(conversion, "-", true);
                        if (std.mem.indexOfScalar(u8, conversion, '.') == null and bytes.len >= 100) {
                            // no precision and too long a string to format, so
                            // the reference adds it without applying the width
                            output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                        } else {
                            const options = sFormat(conversion);
                            const count = if (options.precision) |precision| @min(bytes.len, precision) else bytes.len;
                            try vm.appendFormatField(&output, bytes[0..count], options.width, options.left, ' ');
                        }
                    }
                },
                else => return vm.raise("invalid conversion '{s}' to 'format'", .{conversion}),
            }
        }
        const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    /// `checkformat` in lstrlib.c: a specification is valid when its flags are
    /// the conversion's own, its width and precision are at most two digits
    /// each, and what follows them is the conversion character again.
    fn formatCheck(vm: *VM, form: []const u8, flags: []const u8, precision: bool) Error!void {
        var index: usize = 1;
        while (index < form.len and std.mem.indexOfScalar(u8, flags, form[index]) != null) index += 1;
        if (index < form.len and form[index] != '0') {
            index = get2digits(form, index);
            if (index < form.len and form[index] == '.' and precision) {
                index += 1;
                index = get2digits(form, index);
            }
        }
        if (index >= form.len or !std.ascii.isAlphabetic(form[index]))
            return vm.raise("invalid conversion specification: '{s}'", .{form});
    }

    /// `get2digits`: a width or a precision of at most two digits.
    fn get2digits(form: []const u8, start: usize) usize {
        var index = start;
        if (index < form.len and std.ascii.isDigit(form[index])) index += 1;
        if (index < form.len and std.ascii.isDigit(form[index])) index += 1;
        return index;
    }

    /// The width and precision a `%s` specification asks for, which the
    /// reference hands to `sprintf` but have to be applied by hand here.
    fn sFormat(form: []const u8) struct { left: bool, width: usize, precision: ?usize } {
        var index: usize = 1;
        var left = false;
        if (index < form.len and form[index] == '-') {
            left = true;
            index += 1;
        }
        const width_start = index;
        while (index < form.len and std.ascii.isDigit(form[index])) index += 1;
        const width = std.fmt.parseInt(usize, form[width_start..index], 10) catch 0;
        var precision: ?usize = null;
        if (index < form.len and form[index] == '.') {
            index += 1;
            const precision_start = index;
            while (index < form.len and std.ascii.isDigit(form[index])) index += 1;
            precision = std.fmt.parseInt(usize, form[precision_start..index], 10) catch 0;
        }
        return .{ .left = left, .width = width, .precision = precision };
    }

    /// `%q` for the values that reach `luaL_tolstring` without a literal form:
    /// nil and the two booleans.
    fn appendTolstring(vm: *VM, output: *std.ArrayList(u8), value: Value) Error!void {
        const bytes: []const u8 = switch (value) {
            .nil => "nil",
            .boolean => |boolean| if (boolean) "true" else "false",
            else => unreachable,
        };
        output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
    }

    fn appendFormatField(vm: *VM, output: *std.ArrayList(u8), bytes: []const u8, width: usize, left: bool, fill: u8) Error!void {
        const padding = width -| bytes.len;
        if (!left) for (0..padding) |_| output.append(vm.allocator, fill) catch return error.OutOfMemory;
        output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
        if (left) for (0..padding) |_| output.append(vm.allocator, ' ') catch return error.OutOfMemory;
    }

    /// `%q`, which follows `addquoted` in lstrlib.c: quote, backslash and
    /// newline are escaped with a backslash before themselves, other control
    /// bytes become a decimal escape that is zero-padded only when a digit
    /// follows and would otherwise be swallowed.
    fn appendQuoted(vm: *VM, output: *std.ArrayList(u8), bytes: []const u8) Error!void {
        output.append(vm.allocator, '"') catch return error.OutOfMemory;
        for (bytes, 0..) |byte, i| {
            if (byte == '"' or byte == '\\' or byte == '\n') {
                output.append(vm.allocator, '\\') catch return error.OutOfMemory;
                output.append(vm.allocator, byte) catch return error.OutOfMemory;
            } else if (byte < 32 or byte == 127) {
                const next_is_digit = i + 1 < bytes.len and std.ascii.isDigit(bytes[i + 1]);
                const escaped = if (next_is_digit)
                    std.fmt.allocPrint(vm.allocator, "\\{d:0>3}", .{byte}) catch return error.OutOfMemory
                else
                    std.fmt.allocPrint(vm.allocator, "\\{d}", .{byte}) catch return error.OutOfMemory;
                defer vm.allocator.free(escaped);
                output.appendSlice(vm.allocator, escaped) catch return error.OutOfMemory;
            } else {
                output.append(vm.allocator, byte) catch return error.OutOfMemory;
            }
        }
        output.append(vm.allocator, '"') catch return error.OutOfMemory;
    }

    /// `%q` for numbers, following `addliteral` in lstrlib.c: integers print
    /// in decimal (their minimum in hex), floats as C hexadecimal floats, and
    /// the infinities and NaN get Lua's spellings.
    fn appendQuotedNumber(vm: *VM, output: *std.ArrayList(u8), number: Number.Number) Error!void {
        if (number.isInt()) {
            const integer = number.toIntExact() orelse unreachable;
            if (integer == std.math.minInt(i64)) {
                output.appendSlice(vm.allocator, "0x8000000000000000") catch return error.OutOfMemory;
                return;
            }
            var integer_buffer: [32]u8 = undefined;
            const printed = std.fmt.bufPrint(&integer_buffer, "{d}", .{integer}) catch return error.RuntimeError;
            output.appendSlice(vm.allocator, printed) catch return error.OutOfMemory;
            return;
        }
        const float = number.toFloat();
        if (std.math.isNan(float)) {
            output.appendSlice(vm.allocator, "(0/0)") catch return error.OutOfMemory;
            return;
        }
        if (std.math.isPositiveInf(float)) {
            output.appendSlice(vm.allocator, "1e9999") catch return error.OutOfMemory;
            return;
        }
        if (std.math.isNegativeInf(float)) {
            output.appendSlice(vm.allocator, "-1e9999") catch return error.OutOfMemory;
            return;
        }
        var float_buffer: [64]u8 = undefined;
        const needed = snprintf(&float_buffer, float_buffer.len, "%a", float);
        if (needed < 0) return error.RuntimeError;
        const written = @min(@as(usize, @intCast(needed)), float_buffer.len - 1);
        output.appendSlice(vm.allocator, float_buffer[0..written]) catch return error.OutOfMemory;
    }

    /// One conversion of `string.format`, written out by C's own `printf` the
    /// way `str_format` does once `checkformat` has let the specification
    /// through. Integers go through `long long` the way `addlenmod` and
    /// `LUA_INTEGER_FRMLEN` do, `%c` truncates to `int` (which C then narrows
    /// to a byte), and `%p` prints a collector address, with `(null)` for the
    /// values `lua_topointer` refuses.
    fn appendNumericFormat(vm: *VM, output: *std.ArrayList(u8), value: Value, form: []const u8, specifier: u8) Error!void {
        const is_integer = specifier == 'd' or specifier == 'i' or specifier == 'u' or specifier == 'o' or specifier == 'x' or specifier == 'X';
        var pointer: ?*const anyopaque = null;
        if (specifier == 'p') pointer = switch (value) {
            .string => |string| @ptrCast(string),
            .table => |table| @ptrCast(table),
            .function => |function| @ptrCast(function),
            .thread => |thread| @ptrCast(thread),
            .native_function => |native| @ptrFromInt(@intFromEnum(native) + 1),
            else => null,
        };
        var form_buffer: [64]u8 = undefined;
        if (form.len + 3 > form_buffer.len) return vm.raise("invalid format (too long)", .{});
        @memcpy(form_buffer[0..form.len], form);
        var length = form.len;
        if (is_integer) {
            // `addlenmod` writes the length modifier before the specifier
            form_buffer[form.len - 1] = 'l';
            form_buffer[form.len] = 'l';
            form_buffer[form.len + 1] = form[form.len - 1];
            length = form.len + 2;
        } else if (specifier == 'p' and pointer == null) {
            // `lua_topointer` has nothing to show, so the reference formats
            // "(null)" as a string instead
            form_buffer[form.len - 1] = 's';
        }
        form_buffer[length] = 0;

        const capacity = 768;
        const buffer = vm.allocator.alloc(u8, capacity) catch return error.OutOfMemory;
        defer vm.allocator.free(buffer);
        const needed: c_int = if (is_integer) blk: {
            const integer = try intArgument(value);
            if (specifier == 'd' or specifier == 'i')
                break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&form_buffer), @as(c_longlong, integer));
            break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&form_buffer), @as(c_ulonglong, @bitCast(integer)));
        } else if (specifier == 'c') blk: {
            const integer = try intArgument(value);
            break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&form_buffer), @as(c_int, @truncate(integer)));
        } else if (specifier == 'p') blk: {
            if (pointer) |address| break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&form_buffer), address);
            break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&form_buffer), "(null)");
        } else blk: {
            if (value != .number) return error.RuntimeError;
            break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&form_buffer), value.number.toFloat());
        };
        if (needed < 0) return error.RuntimeError;
        const written = @min(@as(usize, @intCast(needed)), buffer.len - 1);
        output.appendSlice(vm.allocator, buffer[0..written]) catch return error.OutOfMemory;
    }

    fn setStringField(vm: *VM, table: *Table, name: []const u8, value: Value) Error!void {
        const key = Value{ .string = vm.interner.intern(name) catch return error.OutOfMemory };
        table.set(key, value) catch return error.OutOfMemory;
    }

    fn getStringField(vm: *VM, table: *Table, name: []const u8) Error!Value {
        return table.get(.{ .string = vm.interner.intern(name) catch return error.OutOfMemory });
    }

    fn patternCapture(vm: *VM, source: []const u8, capture: Pattern.Capture) Error!Value {
        if (capture.position) return .{ .number = Number.Number.fromInt(std.math.cast(i64, capture.start + 1) orelse return error.RuntimeError) };
        const string = vm.interner.intern(source[capture.start..capture.end]) catch return error.OutOfMemory;
        return .{ .string = string };
    }

    /// Turns a refused pattern into the message `lstrlib.c` raises, positioned
    /// the way `luaL_error` positions it.
    fn patternError(vm: *VM, failure: Pattern.Failure) Error {
        return switch (failure.kind) {
            .too_many_captures => vm.raise("too many captures", .{}),
            .invalid_pattern_capture => vm.raise("invalid pattern capture", .{}),
            .malformed_missing_percentb => vm.raise("malformed pattern (missing arguments to '%b')", .{}),
            .missing_bracket_after_percentf => vm.raise("missing '[' after '%f' in pattern", .{}),
            .invalid_capture_index => vm.raise("invalid capture index %{d}", .{failure.index}),
            .ends_with_percent => vm.raise("malformed pattern (ends with '%')", .{}),
            .missing_bracket => vm.raise("malformed pattern (missing ']')", .{}),
            .pattern_too_complex => vm.raise("pattern too complex", .{}),
            .unfinished_capture => vm.raise("unfinished capture", .{}),
        };
    }

    /// `get_onecapture` refuses an unfinished capture the moment it is pushed,
    /// so the entry points that push them all — `find`, `match` and the
    /// `gmatch` iterator — check before any value comes back.
    fn hasUnfinishedCapture(captures: []const Pattern.Capture) bool {
        for (captures) |capture| if (capture.unfinished) return true;
        return false;
    }

    fn singleNumber(vm: *VM, number: Number.Number) Error![]Value {
        return vm.allocator.dupe(Value, &.{.{ .number = number }}) catch return error.OutOfMemory;
    }

    fn utf8Char(vm: *VM, args: []const Value) Error![]Value {
        const short = "char";
        const long = "utf8.char";
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(vm.allocator);
        for (args, 0..) |_, i| {
            const integer = try vm.checkInteger(args, i + 1, short, long);
            const unsigned: u64 = @bitCast(integer);
            // `luaL_argcheck(L, code <= UNICODE_MAX, i, "value out of range")`,
            // against a `lua_Unsigned`, so a negative argument is caught here
            if (unsigned > 0x7fffffff) return vm.raiseArgument(i + 1, short, long, "value out of range", .{});
            const encoded = Utf8.encode(unsigned) orelse return vm.raiseArgument(i + 1, short, long, "value out of range", .{});
            bytes.appendSlice(vm.allocator, encoded.bytes[0..encoded.len]) catch return error.OutOfMemory;
        }
        const string = vm.interner.intern(bytes.items) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn utf8RelativePosition(position: i64, length: i64) i64 {
        if (position >= 0) return position;
        const magnitude = 0 -% @as(u64, @bitCast(position));
        if (magnitude > length) return 0;
        return length + position + 1;
    }

    fn utf8Len(vm: *VM, args: []const Value) Error![]Value {
        const short = "len";
        const long = "utf8.len";
        const source = try vm.checkString(args, 1, short, long);
        const length = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const initial = try vm.optInteger(args, 2, 1, short, long);
        const final = try vm.optInteger(args, 3, -1, short, long);
        const start = utf8RelativePosition(initial, length);
        const end = utf8RelativePosition(final, length);
        if (start < 1 or start - 1 > length) return vm.raiseArgument(2, short, long, "initial position out of bounds", .{});
        if (end - 1 >= length) return vm.raiseArgument(3, short, long, "final position out of bounds", .{});
        const lax = args.len >= 4 and args[3].truthy();
        var position: usize = @intCast(start - 1);
        const end_exclusive: usize = if (end <= 0) 0 else @intCast(end);
        var count: i64 = 0;
        while (position < end_exclusive) {
            const decoded = Utf8.decode(source, position, lax) orelse {
                return vm.allocator.dupe(Value, &.{ .nil, .{ .number = Number.Number.fromInt(std.math.cast(i64, position + 1) orelse return error.RuntimeError) } }) catch return error.OutOfMemory;
            };
            position = decoded.next;
            count += 1;
        }
        return vm.allocator.dupe(Value, &.{.{ .number = Number.Number.fromInt(count) }}) catch return error.OutOfMemory;
    }

    fn utf8Codepoint(vm: *VM, args: []const Value) Error![]Value {
        const short = "codepoint";
        const long = "utf8.codepoint";
        const source = try vm.checkString(args, 1, short, long);
        const length = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const start = utf8RelativePosition(try vm.optInteger(args, 2, 1, short, long), length);
        const final = utf8RelativePosition(try vm.optInteger(args, 3, start, short, long), length);
        if (start < 1) return vm.raiseArgument(2, short, long, "out of bounds", .{});
        if (final > length) return vm.raiseArgument(3, short, long, "out of bounds", .{});
        if (start > final) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const lax = args.len >= 4 and args[3].truthy();
        var values: std.ArrayList(Value) = .empty;
        errdefer values.deinit(vm.allocator);
        var position: usize = @intCast(start - 1);
        const end: usize = @intCast(final);
        while (position < end) {
            const decoded = Utf8.decode(source, position, lax) orelse return vm.raise("invalid UTF-8 code", .{});
            values.append(vm.allocator, .{ .number = Number.Number.fromInt(decoded.codepoint) }) catch return error.OutOfMemory;
            position = decoded.next;
        }
        return values.toOwnedSlice(vm.allocator) catch return error.OutOfMemory;
    }

    fn utf8Offset(vm: *VM, args: []const Value) Error![]Value {
        const short = "offset";
        const long = "utf8.offset";
        const source = try vm.checkString(args, 1, short, long);
        const n = try vm.checkInteger(args, 2, short, long);
        const length = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const default_position = if (n >= 0) @as(i64, 1) else length + 1;
        const one_based = utf8RelativePosition(try vm.optInteger(args, 3, default_position, short, long), length);
        if (one_based < 1 or one_based - 1 > length) return vm.raiseArgument(3, short, long, "position out of bounds", .{});
        var position: usize = @intCast(one_based - 1);
        var remaining = n;
        if (remaining == 0) {
            while (position > 0 and position < source.len and Utf8.isContinuation(source[position])) position -= 1;
        } else {
            if (position < source.len and Utf8.isContinuation(source[position])) return vm.raise("initial position is a continuation byte", .{});
            if (remaining < 0) {
                while (remaining < 0 and position > 0) {
                    position -= 1;
                    while (position > 0 and Utf8.isContinuation(source[position])) position -= 1;
                    remaining += 1;
                }
            } else {
                remaining -= 1;
                while (remaining > 0 and position < source.len) {
                    position += 1;
                    while (position < source.len and Utf8.isContinuation(source[position])) position += 1;
                    remaining -= 1;
                }
            }
        }
        const result: Value = if (remaining == 0)
            .{ .number = Number.Number.fromInt(std.math.cast(i64, position + 1) orelse return error.RuntimeError) }
        else
            .nil;
        return vm.allocator.dupe(Value, &.{result}) catch return error.OutOfMemory;
    }

    /// `iter_codes`: the subject string, the byte offset zero, and one of the
    /// two iterators — the reference hands back `iter_auxlax` or
    /// `iter_auxstrict` depending on the second argument, and that difference
    /// is what stands between them.
    fn utf8Codes(vm: *VM, args: []const Value) Error![]Value {
        const short = "codes";
        const long = "utf8.codes";
        const source = try vm.checkString(args, 1, short, long);
        if (source.len > 0 and Utf8.isContinuation(source[0]))
            return vm.raiseArgument(1, short, long, "invalid UTF-8 code", .{});
        const lax = args.len >= 2 and args[1].truthy();
        const held = Value{ .string = vm.interner.intern(source) catch return error.OutOfMemory };
        const iterator: Value = .{ .native_function = if (lax) .utf8_codes_iterator_lax else .utf8_codes_iterator };
        return vm.allocator.dupe(Value, &.{ iterator, held, .{ .number = Number.Number.fromInt(0) } }) catch return error.OutOfMemory;
    }

    /// `iter_aux`: the state is the string itself and the control is a raw
    /// byte offset read the way `lua_tointeger` reads it, so anything that is
    /// not an integer counts as zero and a negative one has run off the end.
    fn utf8CodesIterator(vm: *VM, args: []const Value, lax: bool) Error![]Value {
        if (args.len < 2 or args[0] != .string) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const bytes = args[0].string.slice();
        const control: i64 = switch (args[1]) {
            .number => |number| number.toIntExact() orelse 0,
            else => 0,
        };
        if (control < 0 or control >= bytes.len) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        var position: usize = @intCast(control);
        while (position < bytes.len and Utf8.isContinuation(bytes[position])) position += 1;
        if (position >= bytes.len) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const decoded = Utf8.decode(bytes, position, lax) orelse return vm.raise("invalid UTF-8 code", .{});
        if (decoded.next < bytes.len and Utf8.isContinuation(bytes[decoded.next])) return vm.raise("invalid UTF-8 code", .{});
        return vm.allocator.dupe(Value, &.{
            .{ .number = Number.Number.fromInt(std.math.cast(i64, position + 1) orelse return error.RuntimeError) },
            .{ .number = Number.Number.fromInt(decoded.codepoint) },
        }) catch return error.OutOfMemory;
    }

    fn mathAbs(vm: *VM, args: []const Value) Error![]Value {
        // `luaL_checknumber` is only reached for something that is not already
        // an integer, which is what keeps `math.abs(-3)` an integer
        if (args.len >= 1 and args[0] == .number and args[0].number == .int) {
            const i = args[0].number.int;
            return singleNumber(vm, .{ .int = if (i < 0) 0 -% i else i });
        }
        const n = try vm.checkNumber(args, 1, "abs", "math.abs");
        return singleNumber(vm, .{ .float = @abs(n.toFloat()) });
    }

    fn mathRound(vm: *VM, args: []const Value, floor: bool) Error![]Value {
        const short: []const u8 = if (floor) "floor" else "ceil";
        const long: []const u8 = if (floor) "math.floor" else "math.ceil";
        if (args.len >= 1 and args[0] == .number and args[0].number == .int) return singleNumber(vm, args[0].number);
        const n = try vm.checkNumber(args, 1, short, long);
        const rounded = if (floor) @floor(n.toFloat()) else @ceil(n.toFloat());
        // `pushnumint`: a float that names an integer is handed back as one
        if (Number.Number.fromFloat(rounded).toIntExact()) |integer| return singleNumber(vm, .{ .int = integer });
        return singleNumber(vm, .{ .float = rounded });
    }

    fn mathSqrt(vm: *VM, args: []const Value) Error![]Value {
        const n = try vm.checkNumber(args, 1, "sqrt", "math.sqrt");
        return singleNumber(vm, .{ .float = @sqrt(n.toFloat()) });
    }

    fn mathFmod(vm: *VM, args: []const Value) Error![]Value {
        const short = "fmod";
        const long = "math.fmod";
        if (args.len >= 2 and args[0] == .number and args[1] == .number and args[0].number == .int and args[1].number == .int) {
            const divisor = args[1].number.int;
            // `d + 1u <= 1u` is the reference's way of naming -1 and 0
            if (@as(u64, @bitCast(divisor)) +% 1 <= 1) {
                if (divisor == 0) return vm.raiseArgument(2, short, long, "zero", .{});
                return singleNumber(vm, .{ .int = 0 });
            }
            return singleNumber(vm, .{ .int = @rem(args[0].number.int, divisor) });
        }
        const a = try vm.checkNumber(args, 1, short, long);
        const b = try vm.checkNumber(args, 2, short, long);
        return singleNumber(vm, .{ .float = @rem(a.toFloat(), b.toFloat()) });
    }

    /// `math.max` and `math.min`: any first argument at all is accepted and
    /// handed back when it is the only one, and from there the reference's
    /// `lua_compare` decides, which is the same `<` this runtime raises for.
    fn mathMinMax(vm: *VM, args: []const Value, maximum: bool) Error![]Value {
        const short: []const u8 = if (maximum) "max" else "min";
        const long: []const u8 = if (maximum) "math.max" else "math.min";
        if (args.len == 0) return vm.raiseArgument(1, short, long, "value expected", .{});
        var best: usize = 0;
        for (args[1..], 1..) |arg, i| {
            const keep = if (maximum)
                try vm.lessThanValues(args[best], arg)
            else
                try vm.lessThanValues(arg, args[best]);
            if (keep) best = i;
        }
        return vm.allocator.dupe(Value, &.{args[best]}) catch return error.OutOfMemory;
    }

    fn mathToInteger(vm: *VM, args: []const Value) Error![]Value {
        // a failure is only refused for an argument that was never passed
        const number: ?Number.Number = if (args.len == 0) null else switch (args[0]) {
            .number => |number| number,
            .string => |string| Number.parse(string.slice()),
            else => null,
        };
        if (number) |value| if (value.toIntExact()) |integer| return singleNumber(vm, .{ .int = integer });
        try vm.checkAny(args, 1, "tointeger", "math.tointeger");
        return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
    }

    fn mathType(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1) return vm.raiseArgument(1, "type", "math.type", "value expected", .{});
        const type_name = args[0].mathType() orelse return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const string = vm.interner.intern(type_name) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    const MathUnary = enum { sin, cos, tan, asin, acos, exp, deg, rad };

    fn mathUnary(vm: *VM, args: []const Value, op: MathUnary) Error![]Value {
        const long = switch (op) {
            .sin => "math.sin",
            .cos => "math.cos",
            .tan => "math.tan",
            .asin => "math.asin",
            .acos => "math.acos",
            .exp => "math.exp",
            .deg => "math.deg",
            .rad => "math.rad",
        };
        const short = long[5..];
        const n = try vm.checkNumber(args, 1, short, long);
        const x = n.toFloat();
        const result: f64 = switch (op) {
            .sin => @sin(x),
            .cos => @cos(x),
            .tan => @tan(x),
            .asin => std.math.asin(x),
            .acos => std.math.acos(x),
            .exp => @exp(x),
            .deg => x * (180.0 / std.math.pi),
            .rad => x * (std.math.pi / 180.0),
        };
        return singleNumber(vm, .{ .float = result });
    }

    fn mathAtan(vm: *VM, args: []const Value) Error![]Value {
        const short = "atan";
        const long = "math.atan";
        const y = try vm.checkNumber(args, 1, short, long);
        const x = try vm.optNumber(args, 2, Number.Number.fromFloat(1), short, long);
        return singleNumber(vm, .{ .float = std.math.atan2(y.toFloat(), x.toFloat()) });
    }

    fn mathLog(vm: *VM, args: []const Value) Error![]Value {
        const short = "log";
        const long = "math.log";
        const x = try vm.checkNumber(args, 1, short, long);
        const result = if (args.len >= 2 and args[1] != .nil) blk: {
            const base = try vm.checkNumber(args, 2, short, long);
            break :blk @log(x.toFloat()) / @log(base.toFloat());
        } else @log(x.toFloat());
        return singleNumber(vm, .{ .float = result });
    }

    fn mathModf(vm: *VM, args: []const Value) Error![]Value {
        const short = "modf";
        const long = "math.modf";
        const values = vm.allocator.alloc(Value, 2) catch return error.OutOfMemory;
        if (args.len >= 1 and args[0] == .number and args[0].number == .int) {
            // the integer is its own integral part, and the fraction is `0.0`
            values[0] = args[0];
            values[1] = .{ .number = Number.Number.fromFloat(0) };
            return values;
        }
        const n = try vm.checkNumber(args, 1, short, long);
        const float = n.toFloat();
        const integral = if (float < 0) @ceil(float) else @floor(float);
        // `pushnumint`: an integral part that names an integer is one
        values[0] = if (Number.Number.fromFloat(integral).toIntExact()) |integer|
            .{ .number = .{ .int = integer } }
        else
            .{ .number = Number.Number.fromFloat(integral) };
        values[1] = .{ .number = Number.Number.fromFloat(if (float == integral) 0 else float - integral) };
        return values;
    }

    fn mathUlt(vm: *VM, args: []const Value) Error![]Value {
        const short = "ult";
        const long = "math.ult";
        const a = try vm.checkInteger(args, 1, short, long);
        const b = try vm.checkInteger(args, 2, short, long);
        const result: Value = .{ .boolean = @as(u64, @bitCast(a)) < @as(u64, @bitCast(b)) };
        return vm.allocator.dupe(Value, &.{result}) catch return error.OutOfMemory;
    }

    fn nextRandom(vm: *VM) u64 {
        return nextRandomState(&vm.rng_state);
    }

    fn mathRandom(vm: *VM, args: []const Value) Error![]Value {
        const short = "random";
        const long = "math.random";
        if (args.len > 2) return vm.raise("wrong number of arguments", .{});
        try vm.tick();
        const sample = vm.nextRandom();
        if (args.len == 0) {
            const fraction = @as(f64, @floatFromInt(sample >> 11)) / 9007199254740992.0;
            return vm.singleNumber(.{ .float = fraction });
        }
        const upper = try vm.checkInteger(args, 1, short, long);
        if (args.len == 1 and upper == 0) return vm.singleNumber(.{ .int = @bitCast(sample) });
        const low: i64 = if (args.len == 1) 1 else try vm.checkInteger(args, 1, short, long);
        const high = if (args.len == 1) upper else try vm.checkInteger(args, 2, short, long);
        // the interval check names argument one whatever the arity was
        if (low > high) return vm.raiseArgument(1, short, long, "interval is empty", .{});
        const bound = @as(u64, @bitCast(high)) -% @as(u64, @bitCast(low));
        var mask = bound;
        if ((mask & (mask +% 1)) != 0) {
            mask |= mask >> 1;
            mask |= mask >> 2;
            mask |= mask >> 4;
            mask |= mask >> 8;
            mask |= mask >> 16;
            mask |= mask >> 32;
        }
        var offset = sample & mask;
        while (offset > bound) {
            try vm.tick();
            offset = vm.nextRandom() & mask;
        }
        const result: i64 = @bitCast(@as(u64, @bitCast(low)) +% offset);
        return vm.singleNumber(.{ .int = result });
    }

    fn mathRandomSeed(vm: *VM, args: []const Value) Error![]Value {
        const short = "randomseed";
        const long = "math.randomseed";
        // an absent first argument asks for a seed from the clock; a present
        // one has to be an integer, and `nil` counts as present
        if (args.len == 0) {
            const first: i64 = if (vm.io) |io| std.Io.Clock.real.now(io).toSeconds() else 0;
            const second: i64 = @bitCast(@intFromPtr(vm));
            vm.rng_state = seedRandomState(@bitCast(first), @bitCast(second));
            return vm.allocator.dupe(Value, &.{ .{ .number = Number.Number.fromInt(first) }, .{ .number = Number.Number.fromInt(second) } }) catch return error.OutOfMemory;
        }
        const first = try vm.checkInteger(args, 1, short, long);
        const second = try vm.optInteger(args, 2, 0, short, long);
        vm.rng_state = seedRandomState(@bitCast(first), @bitCast(second));
        return vm.allocator.dupe(Value, &.{ .{ .number = Number.Number.fromInt(first) }, .{ .number = Number.Number.fromInt(second) } }) catch return error.OutOfMemory;
    }

    /// `getfield`: a field that will not read as an integer is refused by
    /// name, an absent one takes its default when it has one and is reported
    /// missing when it does not, and a value too large for the C `int` the
    /// reference builds its `struct tm` out of is out of bound. `delta` is
    /// what the reference subtracts on the way in (1900 for a year, one for a
    /// month) and it enters only the bound, since this runtime keeps the
    /// field the way the date table wrote it.
    fn dateField(vm: *VM, table: *Table, name: []const u8, default: ?i64, delta: i64) Error!i64 {
        const key = Value{ .string = vm.interner.intern(name) catch return error.OutOfMemory };
        const value = table.get(key);
        const number: ?Number.Number = switch (value) {
            .number => |number| number,
            .string => |string| Number.parse(string.slice()),
            else => null,
        };
        if (number) |candidate| if (candidate.toIntExact()) |integer| {
            const in_bounds = if (integer >= 0)
                integer - delta <= std.math.maxInt(i32)
            else
                std.math.minInt(i32) + delta <= integer;
            if (!in_bounds) return vm.raise("field '{s}' is out-of-bound", .{name});
            return integer;
        };
        if (value != .nil) return vm.raise("field '{s}' is not an integer", .{name});
        if (default) |fallback| return fallback;
        return vm.raise("field '{s}' missing in date table", .{name});
    }

    fn setDateField(vm: *VM, table: *Table, name: []const u8, value: i64) Error!void {
        const key = Value{ .string = vm.interner.intern(name) catch return error.OutOfMemory };
        table.set(key, .{ .number = Number.Number.fromInt(value) }) catch return error.OutOfMemory;
    }

    fn appendDateNumber(vm: *VM, output: *std.ArrayList(u8), comptime format: []const u8, value: i64) Error!void {
        var buffer: [80]u8 = undefined;
        // Zig prints a `+` sign for a signed integer as soon as a width is
        // given, so the unsigned half is formatted and the sign is added here.
        const bytes = if (value < 0)
            std.fmt.bufPrint(&buffer, "-" ++ format, .{@as(u64, @intCast(-(value + 1))) + 1}) catch return error.RuntimeError
        else
            std.fmt.bufPrint(&buffer, format, .{@as(u64, @intCast(value))}) catch return error.RuntimeError;
        output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
    }

    fn appendDateText(vm: *VM, output: *std.ArrayList(u8), bytes: []const u8) Error!void {
        output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
    }

    fn formatDate(vm: *VM, format: []const u8, parts: DateParts) Error![]u8 {
        const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
        const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
        const weekday_index: usize = @intCast(@mod(parts.weekday - 1, 7));
        const month_index: usize = @intCast(@mod(parts.month - 1, 12));
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(vm.allocator);
        var index: usize = 0;
        while (index < format.len) : (index += 1) {
            if (format[index] != '%') {
                try vm.appendDateText(&output, format[index .. index + 1]);
                continue;
            }
            index += 1;
            // `checkoption` blames the whole rest of the format for a
            // specifier it does not know, and a trailing `%` has nothing
            // after it at all
            if (index >= format.len) return vm.raiseArgument(1, "date", "os.date", "invalid conversion specifier '%'", .{});
            switch (format[index]) {
                '%' => try vm.appendDateText(&output, "%"),
                'Y' => try vm.appendDateNumber(&output, "{d:0>4}", parts.year),
                'y' => try vm.appendDateNumber(&output, "{d:0>2}", @mod(parts.year, 100)),
                'm' => try vm.appendDateNumber(&output, "{d:0>2}", parts.month),
                'd' => try vm.appendDateNumber(&output, "{d:0>2}", parts.day),
                'e' => try vm.appendDateNumber(&output, "{d: >2}", parts.day),
                'H' => try vm.appendDateNumber(&output, "{d:0>2}", parts.hour),
                'I' => try vm.appendDateNumber(&output, "{d:0>2}", if (@mod(parts.hour, 12) == 0) @as(i64, 12) else @mod(parts.hour, 12)),
                'M' => try vm.appendDateNumber(&output, "{d:0>2}", parts.minute),
                'S' => try vm.appendDateNumber(&output, "{d:0>2}", parts.second),
                'j' => try vm.appendDateNumber(&output, "{d:0>3}", parts.yearday),
                'U' => try vm.appendDateNumber(&output, "{d:0>2}", @divTrunc(parts.yearday - 1 + 7 - (parts.weekday - 1), 7)),
                'W' => try vm.appendDateNumber(&output, "{d:0>2}", @divTrunc(parts.yearday - 1 + 7 - @mod(parts.weekday + 5, 7), 7)),
                'w' => try vm.appendDateNumber(&output, "{d}", parts.weekday - 1),
                'u' => try vm.appendDateNumber(&output, "{d}", if (parts.weekday == 1) @as(i64, 7) else parts.weekday - 1),
                'a' => try vm.appendDateText(&output, weekdays[weekday_index][0..3]),
                'A' => try vm.appendDateText(&output, weekdays[weekday_index]),
                'b', 'h' => try vm.appendDateText(&output, months[month_index][0..3]),
                'B' => try vm.appendDateText(&output, months[month_index]),
                'p' => try vm.appendDateText(&output, if (parts.hour < 12) "AM" else "PM"),
                'F' => {
                    try vm.appendDateNumber(&output, "{d:0>4}", parts.year);
                    try vm.appendDateText(&output, "-");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.month);
                    try vm.appendDateText(&output, "-");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.day);
                },
                'T' => {
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.hour);
                    try vm.appendDateText(&output, ":");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.minute);
                    try vm.appendDateText(&output, ":");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.second);
                },
                'R' => {
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.hour);
                    try vm.appendDateText(&output, ":");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.minute);
                },
                'D' => {
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.month);
                    try vm.appendDateText(&output, "/");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.day);
                    try vm.appendDateText(&output, "/");
                    try vm.appendDateNumber(&output, "{d:0>2}", @mod(parts.year, 100));
                },
                'c' => {
                    try vm.appendDateText(&output, weekdays[weekday_index][0..3]);
                    try vm.appendDateText(&output, " ");
                    try vm.appendDateText(&output, months[month_index][0..3]);
                    try vm.appendDateText(&output, " ");
                    try vm.appendDateNumber(&output, "{d: >2}", parts.day);
                    try vm.appendDateText(&output, " ");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.hour);
                    try vm.appendDateText(&output, ":");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.minute);
                    try vm.appendDateText(&output, ":");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.second);
                    try vm.appendDateText(&output, " ");
                    try vm.appendDateNumber(&output, "{d:0>4}", parts.year);
                },
                'x' => {
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.month);
                    try vm.appendDateText(&output, "/");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.day);
                    try vm.appendDateText(&output, "/");
                    try vm.appendDateNumber(&output, "{d:0>4}", parts.year);
                },
                'X' => {
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.hour);
                    try vm.appendDateText(&output, ":");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.minute);
                    try vm.appendDateText(&output, ":");
                    try vm.appendDateNumber(&output, "{d:0>2}", parts.second);
                },
                'Z' => try vm.appendDateText(&output, "UTC"),
                'z' => try vm.appendDateText(&output, "+0000"),
                'n' => try vm.appendDateText(&output, "\n"),
                't' => try vm.appendDateText(&output, "\t"),
                else => return vm.raiseArgument(1, "date", "os.date", "invalid conversion specifier '%{s}'", .{format[index..]}),
            }
        }
        return output.toOwnedSlice(vm.allocator) catch return error.OutOfMemory;
    }

    fn osClock(vm: *VM, args: []const Value) Error![]Value {
        _ = args;
        const io = vm.io orelse return error.RuntimeError;
        const nanoseconds = std.Io.Clock.cpu_process.now(io).nanoseconds;
        const seconds = @as(f64, @floatFromInt(nanoseconds)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        return vm.singleNumber(.{ .float = seconds });
    }

    /// `os.time`: with no argument, or with `nil`, the clock; otherwise a
    /// date table, whose `year`, `month` and `day` have to be there.
    fn osTime(vm: *VM, args: []const Value) Error![]Value {
        const io = vm.io orelse return error.RuntimeError;
        if (args.len == 0 or args[0] == .nil) return vm.singleNumber(.{ .int = std.Io.Clock.real.now(io).toSeconds() });
        const short = "time";
        const long = "os.time";
        const fields = try vm.checkTable(args, 1, short, long);
        const year = try vm.dateField(fields, "year", null, 1900);
        const month = try vm.dateField(fields, "month", null, 1);
        const day = try vm.dateField(fields, "day", null, 0);
        const hour = try vm.dateField(fields, "hour", 12, 0);
        const minute = try vm.dateField(fields, "min", 0, 0);
        const second = try vm.dateField(fields, "sec", 0, 0);
        const total_month = @as(i128, year) * 12 + @as(i128, month) - 1;
        const normalized_year = floorDiv128(total_month, 12);
        const normalized_month = total_month - normalized_year * 12 + 1;
        const timestamp = daysFromCivil(normalized_year, normalized_month, 1) * 86400 +
            (@as(i128, day) - 1) * 86400 + @as(i128, hour) * 3600 + @as(i128, minute) * 60 + second;
        const unix_seconds = std.math.cast(i64, timestamp) orelse return error.RuntimeError;
        const parts = dateParts(timestamp);
        try vm.setDateField(fields, "year", parts.year);
        try vm.setDateField(fields, "month", parts.month);
        try vm.setDateField(fields, "day", parts.day);
        try vm.setDateField(fields, "hour", parts.hour);
        try vm.setDateField(fields, "min", parts.minute);
        try vm.setDateField(fields, "sec", parts.second);
        try vm.setDateField(fields, "wday", parts.weekday);
        try vm.setDateField(fields, "yday", parts.yearday);
        fields.set(.{ .string = vm.interner.intern("isdst") catch return error.OutOfMemory }, .{ .boolean = false }) catch return error.OutOfMemory;
        return vm.singleNumber(.{ .int = unix_seconds });
    }

    /// `os.difftime`: two times, neither of them optional, read the way
    /// `l_checktime` reads them, and the answer is a float.
    fn osDiffTime(vm: *VM, args: []const Value) Error![]Value {
        const short = "difftime";
        const long = "os.difftime";
        const first = try vm.checkInteger(args, 1, short, long);
        const second = try vm.checkInteger(args, 2, short, long);
        const difference = @as(f64, @floatFromInt(first)) - @as(f64, @floatFromInt(second));
        return vm.singleNumber(.{ .float = difference });
    }

    fn osGetEnv(vm: *VM, args: []const Value) Error![]Value {
        const name = try vm.checkString(args, 1, "getenv", "os.getenv");
        const value = if (vm.environ_map) |environment| environment.get(name) else null;
        if (value) |bytes| {
            const string = vm.interner.intern(bytes) catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
        }
        return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
    }

    /// `os.date`: the format is a string with `nil` meaning `"%c"`, and the
    /// time is a number when it is given at all, with `nil` meaning now.
    fn osDate(vm: *VM, args: []const Value) Error![]Value {
        const io = vm.io orelse return error.RuntimeError;
        const short = "date";
        const long = "os.date";
        const raw_format = try vm.optString(args, 1, "%c", short, long);
        const timestamp: i128 = if (args.len >= 2 and args[2 - 1] != .nil)
            @as(i128, try vm.checkInteger(args, 2, short, long))
        else
            @as(i128, std.Io.Clock.real.now(io).toSeconds());
        const utc = raw_format.len != 0 and raw_format[0] == '!';
        const format = if (utc) raw_format[1..] else raw_format;
        // This runtime currently uses UTC for both paths; `!` is accepted so
        // portable UTC date formatting works consistently on every host.
        const parts = dateParts(timestamp);
        if (std.mem.eql(u8, format, "*t")) {
            const table = try vm.newTable();
            try vm.setDateField(table, "year", parts.year);
            try vm.setDateField(table, "month", parts.month);
            try vm.setDateField(table, "day", parts.day);
            try vm.setDateField(table, "hour", parts.hour);
            try vm.setDateField(table, "min", parts.minute);
            try vm.setDateField(table, "sec", parts.second);
            try vm.setDateField(table, "wday", parts.weekday);
            try vm.setDateField(table, "yday", parts.yearday);
            table.set(.{ .string = vm.interner.intern("isdst") catch return error.OutOfMemory }, .{ .boolean = false }) catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .table = table }}) catch return error.OutOfMemory;
        }
        const formatted = try vm.formatDate(format, parts);
        defer vm.allocator.free(formatted);
        const string = vm.interner.intern(formatted) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn osExecuteFailure(vm: *VM, message: []const u8) Error![]Value {
        const error_string = vm.interner.intern(message) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{ .nil, .{ .string = error_string }, .{ .number = Number.Number.fromInt(1) } }) catch return error.OutOfMemory;
    }

    fn osExecute(vm: *VM, args: []const Value) Error![]Value {
        if (args.len >= 1 and args[0] != .string) return error.RuntimeError;
        if (args.len == 0) return vm.allocator.dupe(Value, &.{.{ .boolean = std.process.can_spawn }}) catch return error.OutOfMemory;
        if (!std.process.can_spawn) return vm.osExecuteFailure("OperationUnsupported");
        const io = vm.io orelse return error.RuntimeError;
        const command = args[0].string.slice();
        const argv_posix = [_][]const u8{ "sh", "-c", command };
        const argv_windows = [_][]const u8{ "cmd.exe", "/C", command };
        var child = std.process.spawn(io, .{ .argv = if (builtin.os.tag == .windows) &argv_windows else &argv_posix }) catch |err| return vm.osExecuteFailure(@errorName(err));
        defer child.kill(io);
        const term = child.wait(io) catch |err| return vm.osExecuteFailure(@errorName(err));
        const status_name: []const u8 = switch (term) {
            .exited => "exit",
            .signal, .stopped, .unknown => "signal",
        };
        const status_code: i64 = switch (term) {
            .exited => |code| code,
            .signal => |signal| @intCast(@intFromEnum(signal)),
            .stopped => |signal| @intCast(@intFromEnum(signal)),
            .unknown => |code| @intCast(code),
        };
        const status_string = vm.interner.intern(status_name) catch return error.OutOfMemory;
        const succeeded = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        return vm.allocator.dupe(Value, &.{ if (succeeded) Value{ .boolean = true } else .nil, .{ .string = status_string }, .{ .number = Number.Number.fromInt(status_code) } }) catch return error.OutOfMemory;
    }

    fn osErrorCode(error_name: []const u8) i64 {
        const mappings = .{
            .{ "FileNotFound", 2 }, .{ "AccessDenied", 13 },       .{ "PermissionDenied", 13 },
            .{ "FileBusy", 16 },    .{ "FileSystem", 5 },          .{ "IsDir", 21 },
            .{ "NotDir", 20 },      .{ "ReadOnlyFileSystem", 30 }, .{ "SystemResources", 12 },
            .{ "NoSpaceLeft", 28 }, .{ "DiskQuota", 122 },         .{ "CrossDevice", 18 },
            .{ "DirNotEmpty", 39 }, .{ "InvalidArgument", 22 },
            .{ "BadFileDescriptor", 9 },
        };
        inline for (mappings) |mapping| if (std.mem.eql(u8, error_name, mapping[0])) return mapping[1];
        return 1;
    }

    /// The strerror text the C library would have printed for the failure a
    /// Zig error name stands for.
    fn fileErrorMessage(error_name: []const u8) []const u8 {
        const mappings = .{
            .{ "FileNotFound", "No such file or directory" },
            .{ "AccessDenied", "Permission denied" },
            .{ "PermissionDenied", "Permission denied" },
            .{ "FileBusy", "Device or resource busy" },
            .{ "FileSystem", "Input/output error" },
            .{ "IsDir", "Is a directory" },
            .{ "NotDir", "Not a directory" },
            .{ "ReadOnlyFileSystem", "Read-only file system" },
            .{ "SystemResources", "Too many open files" },
            .{ "NoSpaceLeft", "No space left on device" },
            .{ "DiskQuota", "Disk quota exceeded" },
            .{ "CrossDevice", "Cross-device link" },
            .{ "DirNotEmpty", "Directory not empty" },
            .{ "InvalidArgument", "Invalid argument" },
            .{ "BadFileDescriptor", "Bad file descriptor" },
        };
        inline for (mappings) |mapping| if (std.mem.eql(u8, error_name, mapping[0])) return mapping[1];
        return "Operation failed";
    }

    /// `luaL_fileresult`'s failure half: nil, the message and the errno. A
    /// name in front of the strerror text is what the calls that know which
    /// file they were working on pass.
    fn osFileFailure(vm: *VM, err: anyerror, name: ?[]const u8) Error![]Value {
        const error_name = @errorName(err);
        const message = if (name) |path|
            std.fmt.allocPrint(vm.allocator, "{s}: {s}", .{ path, fileErrorMessage(error_name) }) catch return error.OutOfMemory
        else
            vm.allocator.dupe(u8, fileErrorMessage(error_name)) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        const interned = vm.interner.intern(message) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{ .nil, .{ .string = interned }, .{ .number = Number.Number.fromInt(osErrorCode(error_name)) } }) catch return error.OutOfMemory;
    }

    fn osRemove(vm: *VM, args: []const Value) Error![]Value {
        const name = try vm.checkString(args, 1, "remove", "os.remove");
        const io = vm.io orelse return error.RuntimeError;
        const directory = std.Io.Dir.cwd();
        directory.deleteFile(io, name) catch |err| {
            if (err == error.IsDir) {
                directory.deleteDir(io, name) catch |dir_err| return vm.osFileFailure(dir_err, name);
                return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
            }
            return vm.osFileFailure(err, name);
        };
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
    }

    fn osRename(vm: *VM, args: []const Value) Error![]Value {
        const short = "rename";
        const long = "os.rename";
        const from_name = try vm.checkString(args, 1, short, long);
        const to_name = try vm.checkString(args, 2, short, long);
        const io = vm.io orelse return error.RuntimeError;
        const directory = std.Io.Dir.cwd();
        directory.rename(from_name, directory, to_name, io) catch |err| return vm.osFileFailure(err, from_name);
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
    }

    /// `os.setlocale` answers from the C library's locale database, which this
    /// runtime does not carry. `"C"` needs none of it: it always installs, and
    /// every category starts there, so a query and a request for `"C"` both
    /// answer `"C"`, while any other name — including the environment lookup
    /// `""` performs — comes back nil the way an unavailable locale does.
    fn osSetLocale(vm: *VM, args: []const Value) Error![]Value {
        const short = "setlocale";
        const long = "os.setlocale";
        const locale: ?[]const u8 = if (args.len >= 1 and args[0] != .nil)
            try vm.checkString(args, 1, short, long)
        else
            null;
        const category = try vm.optString(args, 2, "all", short, long);
        const known = [_][]const u8{ "all", "collate", "ctype", "monetary", "numeric", "time" };
        var valid = false;
        for (known) |candidate| {
            if (std.mem.eql(u8, category, candidate)) {
                valid = true;
                break;
            }
        }
        if (!valid) return vm.raiseArgument(2, short, long, "invalid option '{s}'", .{category});
        if (locale) |name| {
            if (!std.mem.eql(u8, name, "C")) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        }
        const c_locale = vm.interner.intern("C") catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = c_locale }}) catch return error.OutOfMemory;
    }

    /// `os.tmpname` on POSIX is `mkstemp` over `/tmp/lua_XXXXXX`: the file is
    /// created exclusively, closed at once and left on disk for its owner to
    /// remove, and a name that cannot be placed is an error, not a return.
    fn osTmpName(vm: *VM, args: []const Value) Error![]Value {
        _ = args;
        const io = vm.io orelse return error.RuntimeError;
        const prefix = "/tmp/lua_";
        var name_buffer: [prefix.len + 6]u8 = undefined;
        @memcpy(name_buffer[0..prefix.len], prefix);
        // `mkstemp` draws from the C library's own entropy, not from the
        // runtime's `math.random` stream, and this state keeps it that way.
        vm.tmp_name_state[0] ^= @intCast(std.Io.Clock.real.now(io).toNanoseconds());
        var attempts: usize = 0;
        while (attempts < 100) : (attempts += 1) {
            var sample = nextRandomState(&vm.tmp_name_state);
            for (name_buffer[prefix.len..]) |*slot| {
                slot.* = temp_name_alphabet[@as(usize, @intCast(sample % temp_name_alphabet.len))];
                sample /= temp_name_alphabet.len;
            }
            const file = std.Io.Dir.cwd().createFile(io, &name_buffer, .{ .exclusive = true }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return vm.raise("unable to generate a unique filename", .{}),
            };
            file.close(io);
            const interned = vm.interner.intern(&name_buffer) catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = interned }}) catch return error.OutOfMemory;
        }
        return vm.raise("unable to generate a unique filename", .{});
    }

    fn osExit(vm: *VM, args: []const Value) Error![]Value {
        if (args.len >= 2 and args[1] != .boolean) return error.RuntimeError;
        const code_value = if (args.len == 0) Value{ .boolean = true } else args[0];
        const status: u8 = switch (code_value) {
            .boolean => |success| if (success) 0 else 1,
            .number => |number| @truncate(@as(u64, @bitCast(number.toIntExact() orelse return error.RuntimeError))),
            else => return error.RuntimeError,
        };
        vm.exit_status = status;
        return error.ExitRequested;
    }

    fn ioOpen(vm: *VM, args: []const Value) Error![]Value {
        const short = "open";
        const long = "io.open";
        const path = try vm.checkString(args, 1, short, long);
        const mode = try vm.optString(args, 2, "r", short, long);
        if (!checkOpenMode(mode)) return vm.raiseArgument(2, short, long, "invalid mode", .{});
        const io = vm.io orelse return error.RuntimeError;
        const normalized = std.mem.replaceOwned(u8, vm.allocator, mode, "b", "") catch return error.OutOfMemory;
        defer vm.allocator.free(normalized);
        const read_mode = std.mem.eql(u8, normalized, "r");
        const read_update_mode = std.mem.eql(u8, normalized, "r+");
        const write_mode = std.mem.eql(u8, normalized, "w");
        const write_update_mode = std.mem.eql(u8, normalized, "w+");
        const append_mode = std.mem.eql(u8, normalized, "a");
        const append_update_mode = std.mem.eql(u8, normalized, "a+");
        const readable = read_mode or read_update_mode or write_update_mode or append_update_mode;
        const writable = read_update_mode or write_mode or write_update_mode or append_mode or append_update_mode;
        if (!readable and !writable) return vm.raiseArgument(2, short, long, "invalid mode", .{});
        const file = if (read_mode or read_update_mode)
            std.Io.Dir.cwd().openFile(io, path, .{ .mode = if (readable and writable) .read_write else .read_only }) catch |err| return vm.osFileFailure(err, path)
        else
            std.Io.Dir.cwd().createFile(io, path, .{ .read = readable, .truncate = write_mode or write_update_mode }) catch |err| return vm.osFileFailure(err, path);
        errdefer file.close(io);
        const table = try vm.newTable();
        table.metatable = vm.file_metatable;
        const handle = vm.allocator.create(FileHandle) catch return error.OutOfMemory;
        errdefer vm.allocator.destroy(handle);
        handle.* = .{ .allocator = vm.allocator, .io = io, .file = file, .table = table, .readable = readable, .writable = writable };
        if (readable) handle.reader = file.reader(io, &handle.reader_buffer);
        if (writable) {
            if (append_mode or append_update_mode) {
                var writer = file.writer(io, &handle.writer_buffer);
                const stat = file.stat(io) catch |err| return vm.osFileFailure(err, path);
                writer.pos = stat.size;
                handle.writer = writer;
            } else {
                handle.writer = file.writer(io, &handle.writer_buffer);
            }
        }
        const result = vm.allocator.alloc(Value, 1) catch return error.OutOfMemory;
        errdefer vm.allocator.free(result);
        result[0] = .{ .table = table };
        vm.owned_files.append(vm.allocator, handle) catch return error.OutOfMemory;
        return result;
    }

    /// `l_checkmode`: a mode that starts in 'r', 'w' or 'a' is accepted as it
    /// stands, and anything else only when it is a two-character prefix in
    /// front of a binary 'b' — which is the shape the second half of the C
    /// expression describes.
    fn checkOpenMode(mode: []const u8) bool {
        if (mode.len > 0 and std.mem.indexOfScalar(u8, "rwa", mode[0]) != null) return true;
        return mode.len == 3 and mode[2] == 'b';
    }

    fn ioTmpFile(vm: *VM, args: []const Value) Error![]Value {
        _ = args;
        const io = vm.io orelse return error.RuntimeError;
        const now = std.Io.Clock.real.now(io).toNanoseconds();
        vm.rng_state[0] ^= @intCast(now);
        const nonce = nextRandomState(&vm.rng_state);
        const path = try std.fmt.allocPrint(vm.allocator, ".lualite-tmp-{x}-{x}.tmp", .{ now, nonce });
        defer vm.allocator.free(path);
        const tracked_path = vm.allocator.dupe(u8, path) catch return error.OutOfMemory;
        errdefer vm.allocator.free(tracked_path);
        const result = try vm.ioOpen(&.{ .{ .string = vm.interner.intern(path) catch return error.OutOfMemory }, .{ .string = vm.interner.intern("w+") catch return error.OutOfMemory } });
        if (result.len == 0 or result[0] != .table) {
            vm.allocator.free(result);
            return error.RuntimeError;
        }
        const handle = try vm.fileHandle(result[0]);
        handle.temp_path = tracked_path;
        return result;
    }

    /// `g_write`: numbers are written the way the C library formats them, and
    /// everything else has to be a string.
    fn writeValues(vm: *VM, handle: *FileHandle, args: []const Value, first: usize, short: []const u8, long: []const u8) Error!void {
        for (args[first - 1 ..], first..) |value, argument| {
            const bytes = switch (value) {
                .string => |string| string.slice(),
                .number => |number| vm.writeNumberBytes(number),
                else => {
                    const text = try vm.checkString(args, argument, short, long);
                    try vm.writeHandleBytes(handle, text);
                    continue;
                },
            };
            try vm.writeHandleBytes(handle, bytes);
        }
    }

    fn writeHandleBytes(vm: *VM, handle: *FileHandle, bytes: []const u8) Error!void {
        _ = vm;
        // An update stream has to jump to where the reads left off before it
        // writes again, the way a C `FILE*` carries its one position across
        // both directions
        if (handle.last_side == .read) {
            if (handle.reader) |*reader| {
                const position = reader.logicalPos();
                if (handle.writer) |*writer| {
                    writer.interface.flush() catch return error.RuntimeError;
                    writer.seekTo(position) catch return error.RuntimeError;
                }
            }
            handle.last_side = .write;
        }
        if (handle.writer_interface) |writer| {
            writer.writeAll(bytes) catch return error.RuntimeError;
        } else if (handle.writer) |*writer| {
            writer.interface.writeAll(bytes) catch return error.RuntimeError;
        } else return error.RuntimeError;
    }

    fn ioWrite(vm: *VM, args: []const Value) Error![]Value {
        const short = "write";
        const long = "io.write";
        const table = vm.default_output orelse try vm.standardFile(false);
        const handle = try vm.fileHandleArgument(.{ .table = table }, 1, short, long);
        try vm.writeValues(handle, args, 1, short, long);
        return vm.allocator.dupe(Value, &.{.{ .table = table }}) catch return error.OutOfMemory;
    }

    fn ioFlush(vm: *VM, args: []const Value) Error![]Value {
        _ = args;
        const table = vm.default_output orelse try vm.standardFile(false);
        const handle = try vm.fileHandleArgument(.{ .table = table }, 1, "flush", "io.flush");
        if (handle.writer_interface) |writer| {
            writer.flush() catch return error.RuntimeError;
        } else if (handle.writer) |*writer| {
            writer.interface.flush() catch return error.RuntimeError;
        } else return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
    }

    /// `io_type`: any value at all is accepted, and only a file handle answers
    /// with a name for itself.
    fn ioType(vm: *VM, args: []const Value) Error![]Value {
        const short = "type";
        const long = "io.type";
        try vm.checkAny(args, 1, short, long);
        const value = args[0];
        if (value != .table) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        for (vm.owned_files.items) |handle| if (handle.table == value.table) {
            const name = vm.interner.intern(if (handle.closed) "closed file" else "file") catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = name }}) catch return error.OutOfMemory;
        };
        return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
    }

    /// `io_close` with no argument closes the default output; `f_close` is
    /// what both it and the method share.
    fn ioClose(vm: *VM, args: []const Value) Error![]Value {
        const file: Value = if (args.len >= 1) args[0] else .{ .table = vm.default_output orelse try vm.standardFile(false) };
        return vm.fileClose(&.{file}, "io.close");
    }

    fn ioLines(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0 or args[0] == .nil) {
            const table = vm.default_input orelse try vm.standardFile(true);
            var file_args: std.ArrayList(Value) = .empty;
            defer file_args.deinit(vm.allocator);
            file_args.append(vm.allocator, .{ .table = table }) catch return error.OutOfMemory;
            if (args.len > 0) file_args.appendSlice(vm.allocator, args[1..]) catch return error.OutOfMemory;
            return vm.fileLines(file_args.items);
        }
        const name = try vm.checkString(args, 1, "lines", "io.lines");
        const opened_table = try vm.openChecked(name, "r");
        var file_args: std.ArrayList(Value) = .empty;
        defer file_args.deinit(vm.allocator);
        file_args.append(vm.allocator, .{ .table = opened_table }) catch return error.OutOfMemory;
        file_args.appendSlice(vm.allocator, args[1..]) catch return error.OutOfMemory;
        const results = try vm.fileLines(file_args.items);
        errdefer vm.allocator.free(results);
        if (results.len == 0 or results[0] != .function) return error.RuntimeError;
        // `io.lines` opens the file itself, so the iterator closes it when it
        // runs out of lines, and the file comes back as the fourth answer for
        // the generic for to keep hold of
        const handle = try vm.fileHandle(.{ .table = opened_table });
        handle.owns_file = true;
        handle.auto_close = true;
        const answers = vm.allocator.alloc(Value, 4) catch return error.OutOfMemory;
        answers[0] = results[0];
        answers[1] = .nil;
        answers[2] = .nil;
        answers[3] = .{ .table = opened_table };
        vm.allocator.free(results);
        return answers;
    }

    /// `f:lines`: the formats are remembered on the handle, and the answer is
    /// the iterator alone — a function with the file bound in front of
    /// whatever the generic for passes it.
    fn fileLines(vm: *VM, args: []const Value) Error![]Value {
        const short = "lines";
        const long = "?";
        if (args.len == 0) return vm.typeError(1, short, long, "FILE*", null);
        const file = args[0];
        _ = try vm.fileHandleArgument(file, 1, short, long);
        const handle = try vm.fileHandle(file);
        if (handle.line_formats) |old_formats| vm.allocator.free(old_formats);
        handle.line_formats = null;
        // The formats are not looked at here at all: anything goes into the
        // iterator and is only checked when a line is actually read
        if (args.len > 1) {
            handle.line_formats = vm.allocator.dupe(Value, args[1..]) catch return error.OutOfMemory;
        }
        return vm.boundNative(.file_lines_iterator, file);
    }

    /// `f:setvbuf`: the buffering mode is asked for and the size checked,
    /// but lualite's files already decide their own buffering, so only the
    /// arguments and the success answer are real.
    fn fileSetvbuf(vm: *VM, args: []const Value) Error![]Value {
        const short = "setvbuf";
        const long = "?";
        if (args.len == 0) return vm.typeError(1, short, long, "FILE*", null);
        _ = try vm.fileHandleArgument(args[0], 1, short, long);
        if (args.len < 2 or args[1] == .nil) return vm.raiseArgument(2, short, long, "option expected", .{});
        const mode = switch (args[1]) {
            .string => |string| string.slice(),
            else => return vm.typeError(2, short, long, "string", args[1]),
        };
        if (!std.mem.eql(u8, mode, "no") and !std.mem.eql(u8, mode, "full") and !std.mem.eql(u8, mode, "line"))
            return vm.raiseArgument(2, short, long, "invalid option '{s}'", .{mode});
        _ = try vm.optInteger(args, 3, 8192, short, long);
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
    }

    fn fileLinesIterator(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const handle = try vm.fileHandle(args[0]);
        if (handle.closed) return vm.raise("file is already closed", .{});
        const formats = handle.line_formats orelse return vm.finishLine(vm.fileRead(&.{args[0]}));
        var read_args: std.ArrayList(Value) = .empty;
        defer read_args.deinit(vm.allocator);
        read_args.append(vm.allocator, args[0]) catch return error.OutOfMemory;
        read_args.appendSlice(vm.allocator, formats) catch return error.OutOfMemory;
        return vm.finishLine(vm.fileRead(read_args.items));
    }

    /// `io_readline`'s last step: an answer that starts with nil ends the
    /// iteration by returning nothing at all rather than that nil.
    fn finishLine(vm: *VM, results: Error![]Value) Error![]Value {
        const values = try results;
        defer vm.allocator.free(values);
        if (values.len == 0 or values[0] == .nil) return &.{};
        return vm.allocator.dupe(Value, values) catch return error.OutOfMemory;
    }

    /// A native function with one value bound in front of its arguments, the
    /// way `coroutine.wrap` and the line iterators are put together.
    fn boundNative(vm: *VM, native: ValueModule.NativeFunction, bound: Value) Error![]Value {
        const function = vm.tracker.alloc(ValueModule.Function, .function) catch return error.OutOfMemory;
        errdefer vm.tracker.free(function);
        function.semantics = vm.exec.semantics;
        function.body = &vm.wrapper_body;
        function.function_index = 0;
        function.captures = &.{};
        function.environment = vm.exec.active_environment;
        function.native = native;
        function.bound = bound;
        vm.owned_functions.append(vm.allocator, function) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .function = function }}) catch return error.OutOfMemory;
    }

    /// One of the three standard streams, set up the first time it is asked
    /// for: stdin reads, and stdout and stderr write through the VM's own
    /// writers rather than owning a file.
    const StandardStream = enum { stdin, stdout, stderr };

    fn standardFile(vm: *VM, input: bool) Error!*Table {
        return vm.standardFileStream(if (input) .stdin else .stdout);
    }

    fn standardFileStream(vm: *VM, stream: StandardStream) Error!*Table {
        const cached: ?*Table = switch (stream) {
            .stdin => vm.stdin_cache,
            .stdout => vm.stdout_cache,
            .stderr => vm.stderr_cache,
        };
        if (cached) |table| return table;
        const io = vm.io orelse return error.RuntimeError;
        const table = try vm.newTable();
        table.metatable = vm.file_metatable;
        const handle = vm.allocator.create(FileHandle) catch return error.OutOfMemory;
        errdefer vm.allocator.destroy(handle);
        handle.* = .{
            .allocator = vm.allocator,
            .io = io,
            .file = switch (stream) {
                .stdin => std.Io.File.stdin(),
                .stdout => std.Io.File.stdout(),
                .stderr => std.Io.File.stderr(),
            },
            .table = table,
            .readable = stream == .stdin,
            .writable = stream != .stdin,
            .owns_file = false,
        };
        switch (stream) {
            .stdin => handle.reader = handle.file.readerStreaming(io, &handle.reader_buffer),
            .stdout => handle.writer_interface = vm.writer orelse return error.RuntimeError,
            .stderr => handle.writer_interface = vm.stderr orelse return error.RuntimeError,
        }
        vm.owned_files.append(vm.allocator, handle) catch return error.OutOfMemory;
        // Until something says otherwise the defaults are the standard streams
        switch (stream) {
            .stdin => {
                vm.stdin_cache = table;
                if (vm.default_input == null) vm.default_input = table;
            },
            .stdout => {
                vm.stdout_cache = table;
                if (vm.default_output == null) vm.default_output = table;
            },
            .stderr => {
                vm.stderr_cache = table;
                if (vm.default_error == null) vm.default_error = table;
            },
        }
        return table;
    }

    /// `io.stdin`, `io.stdout` and `io.stderr` are handed out by name the
    /// first time they are asked for; every other field is left alone.
    fn ioIndex(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[1] != .string) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const name = args[1].string.slice();
        const stream: ?StandardStream = if (std.mem.eql(u8, name, "stdin"))
            .stdin
        else if (std.mem.eql(u8, name, "stdout"))
            .stdout
        else if (std.mem.eql(u8, name, "stderr"))
            .stderr
        else
            null;
        if (stream) |which| {
            const table = try vm.standardFileStream(which);
            return vm.allocator.dupe(Value, &.{.{ .table = table }}) catch return error.OutOfMemory;
        }
        return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
    }

    /// `f_tostring`: the handle's own address, which is all the C version
    /// prints as well.
    fn fileToString(vm: *VM, args: []const Value) Error![]Value {
        const handle = try vm.fileHandle(args[0]);
        const text = std.fmt.allocPrint(vm.allocator, "file (0x{x})", .{@intFromPtr(handle)}) catch return error.OutOfMemory;
        defer vm.allocator.free(text);
        const string = vm.interner.intern(text) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    /// `g_iofile`: a name opens a file in the given mode and refuses to go on
    /// when that fails, and a handle is taken as it stands; an absent or nil
    /// argument only asks for the current one.
    fn ioFileSetting(vm: *VM, args: []const Value, field: enum { input, output }) Error![]Value {
        const short: []const u8 = if (field == .input) "input" else "output";
        const long: []const u8 = if (field == .input) "io.input" else "io.output";
        const mode: []const u8 = if (field == .input) "r" else "w";
        if (args.len == 0 or args[0] == .nil) {
            const table = if (field == .input)
                vm.default_input orelse try vm.standardFile(true)
            else
                vm.default_output orelse try vm.standardFile(false);
            return vm.allocator.dupe(Value, &.{.{ .table = table }}) catch return error.OutOfMemory;
        }
        var table: *Table = undefined;
        if (args[0] == .string or args[0] == .number) {
            const name = try vm.checkString(args, 1, short, long);
            table = try vm.openChecked(name, mode);
        } else {
            _ = try vm.fileHandleArgument(args[0], 1, short, long);
            table = args[0].table;
        }
        if (field == .input) vm.default_input = table else vm.default_output = table;
        return vm.allocator.dupe(Value, &.{.{ .table = table }}) catch return error.OutOfMemory;
    }

    /// `opencheck`: an open that has to work, raising the way `luaL_error`
    /// does when it does not.
    fn openChecked(vm: *VM, path: []const u8, mode: []const u8) Error!*Table {
        const opened = try vm.ioOpen(&.{ .{ .string = vm.interner.intern(path) catch return error.OutOfMemory }, .{ .string = vm.interner.intern(mode) catch return error.OutOfMemory } });
        defer vm.allocator.free(opened);
        if (opened.len == 0 or opened[0] != .table) {
            // `ioOpen` answered with nil, `path: strerror` and the errno;
            // `opencheck` raises `cannot open file '%s' (%s)` with just the
            // strerror text, so the path prefix goes back off
            if (opened.len >= 2 and opened[1] == .string) {
                const text = opened[1].string.slice();
                const bare = if (std.mem.startsWith(u8, text, path) and text.len > path.len + 1 and text[path.len] == ':' and text[path.len + 1] == ' ')
                    text[path.len + 2 ..]
                else
                    text;
                return vm.raise("cannot open file '{s}' ({s})", .{ path, bare });
            }
            return error.RuntimeError;
        }
        return opened[0].table;
    }

    fn ioInput(vm: *VM, args: []const Value) Error![]Value {
        return vm.ioFileSetting(args, .input);
    }

    fn ioOutput(vm: *VM, args: []const Value) Error![]Value {
        return vm.ioFileSetting(args, .output);
    }

    /// `g_read`: the formats come one after another and the answers pile up
    /// until one of them fails, which leaves nil in its place.
    fn ioRead(vm: *VM, args: []const Value) Error![]Value {
        const short = "read";
        const long = "io.read";
        const table = vm.default_input orelse try vm.standardFile(true);
        const handle = try vm.fileHandleArgument(.{ .table = table }, 1, short, long);
        // A stream that cannot be read at all answers with `luaL_fileresult`'s
        // failure half: nil, the strerror text and the errno
        if (handle.reader == null) return vm.osFileFailure(error.BadFileDescriptor, null);
        if (args.len == 0) {
            const line = Value{ .string = vm.interner.intern("*l") catch return error.OutOfMemory };
            const value = try vm.readFormat(handle, line, 1, short, long);
            return vm.allocator.dupe(Value, &.{value}) catch return error.OutOfMemory;
        }
        var results: std.ArrayList(Value) = .empty;
        defer results.deinit(vm.allocator);
        for (args, 1..) |format, argument| {
            const value = try vm.readFormat(handle, format, argument, short, long);
            results.append(vm.allocator, value) catch return error.OutOfMemory;
            if (value == .nil) break;
        }
        return results.toOwnedSlice(vm.allocator) catch return error.OutOfMemory;
    }

    /// `tofile`: a file handle that is still open. Anything else is refused
    /// the way `luaL_checkudata` refuses it, and a closed one the way
    /// `luaL_error` spells it, from a C frame.
    fn fileHandleArgument(vm: *VM, value: Value, argument: usize, short: []const u8, long: []const u8) Error!*FileHandle {
        if (value != .table) return vm.typeError(argument, short, long, "FILE*", value);
        for (vm.owned_files.items) |handle| if (handle.table == value.table) {
            if (handle.closed) return vm.raise("attempt to use a closed file", .{});
            return handle;
        };
        return vm.typeError(argument, short, long, "FILE*", value);
    }

    fn fileHandle(vm: *VM, value: Value) Error!*FileHandle {
        if (value != .table) return error.RuntimeError;
        for (vm.owned_files.items) |handle| if (handle.table == value.table) return handle;
        return error.RuntimeError;
    }

    fn closeFileHandle(handle: *FileHandle) void {
        if (handle.closed) return;
        if (handle.writer_interface) |writer| {
            writer.flush() catch {};
        } else if (handle.writer) |*writer| {
            writer.interface.flush() catch {};
        }
        if (handle.owns_file) handle.file.close(handle.io);
        handle.closed = true;
        if (handle.temp_path) |path| {
            std.Io.Dir.cwd().deleteFile(handle.io, path) catch {};
            handle.allocator.free(path);
            handle.temp_path = null;
        }
        if (handle.line_formats) |formats| {
            handle.allocator.free(formats);
            handle.line_formats = null;
        }
    }

    /// `aux_close`: a standard file refuses to be closed and says why, and
    /// anything else flushes and shuts.
    fn fileClose(vm: *VM, args: []const Value, long: []const u8) Error![]Value {
        const short = "close";
        if (args.len == 0) return vm.typeError(1, short, long, "FILE*", null);
        const handle = try vm.fileHandleArgument(args[0], 1, short, long);
        if (!handle.owns_file) {
            const message = vm.interner.intern("cannot close standard file") catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{ .nil, .{ .string = message } }) catch return error.OutOfMemory;
        }
        closeFileHandle(handle);
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
    }

    fn fileSeek(vm: *VM, args: []const Value) Error![]Value {
        const short = "seek";
        const long = "?";
        if (args.len == 0) return vm.typeError(1, short, long, "FILE*", null);
        const handle = try vm.fileHandleArgument(args[0], 1, short, long);
        const whence = if (args.len >= 2) blk: {
            const text = try vm.checkString(args, 2, short, long);
            if (std.mem.eql(u8, text, "set")) break :blk @as(usize, 0) else if (std.mem.eql(u8, text, "cur")) break :blk @as(usize, 1) else if (std.mem.eql(u8, text, "end")) break :blk @as(usize, 2);
            return vm.raiseArgument(2, short, long, "invalid option '{s}'", .{text});
        } else 1;
        const offset: i64 = try vm.optInteger(args, 3, 0, short, long);
        // `File.Writer.pos` only moves as the buffer drains, so the position
        // the writes have reached is that plus what is still held back
        const current: i128 = if (handle.last_side == .write)
            if (handle.writer) |*writer| writer.pos + writer.interface.buffered().len else if (handle.reader) |*reader| reader.logicalPos() else 0
        else if (handle.reader) |*reader| reader.logicalPos() else if (handle.writer) |*writer| writer.pos + writer.interface.buffered().len else 0;
        const base: i128 = switch (whence) {
            0 => 0,
            1 => current,
            else => (handle.file.stat(handle.io) catch return error.RuntimeError).size,
        };
        const target = base + offset;
        // `fseeko` reports a target it cannot reach with EINVAL, which comes
        // back through `luaL_fileresult` as nil, the strerror text and the
        // errno rather than as an argument error
        if (target < 0 or target > std.math.maxInt(u64)) return vm.osFileFailure(error.InvalidArgument, null);
        const position: u64 = @intCast(target);
        if (handle.writer) |*writer| writer.seekTo(position) catch |err| return vm.osFileFailure(err, null);
        if (handle.reader) |*reader| reader.seekTo(position) catch |err| return vm.osFileFailure(err, null);
        if (handle.writer == null and handle.reader == null) {
            // A stream handle like `io.stdout` buffers nothing of its own, so
            // the seek has to reach the OS the way `fseek` reaches it: a pipe
            // refuses and answers nil, the strerror text and the errno through
            // `luaL_fileresult` rather than as an argument error
            if (handle.writer_interface) |writer| writer.flush() catch return error.RuntimeError;
            const io = handle.io;
            switch (whence) {
                1 => io.vtable.fileSeekBy(io.userdata, handle.file, offset) catch |err| return vm.osFileFailure(err, null),
                else => io.vtable.fileSeekTo(io.userdata, handle.file, position) catch |err| return vm.osFileFailure(err, null),
            }
        }
        handle.last_side = .read;
        return vm.singleNumber(.{ .int = @intCast(position) });
    }

    fn fileFlush(vm: *VM, args: []const Value) Error![]Value {
        const short = "flush";
        const long = "?";
        if (args.len == 0) return vm.typeError(1, short, long, "FILE*", null);
        const handle = try vm.fileHandleArgument(args[0], 1, short, long);
        // `fflush` on a read stream is a no-op that still succeeds; the
        // answer is the success flag, not the file the way `write` has it
        if (handle.writer_interface) |writer| {
            writer.flush() catch return error.RuntimeError;
        } else if (handle.writer) |*writer| {
            writer.interface.flush() catch return error.RuntimeError;
        }
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
    }

    fn fileWrite(vm: *VM, args: []const Value) Error![]Value {
        const short = "write";
        const long = "?";
        if (args.len == 0) return vm.typeError(1, short, long, "FILE*", null);
        const handle = try vm.fileHandleArgument(args[0], 1, short, long);
        if (args.len == 1) return vm.allocator.dupe(Value, &.{args[0]}) catch return error.OutOfMemory;
        try vm.writeValues(handle, args, 2, short, long);
        return vm.allocator.dupe(Value, &.{args[0]}) catch return error.OutOfMemory;
    }

    fn fileRead(vm: *VM, args: []const Value) Error![]Value {
        const short = "read";
        const long = "?";
        if (args.len == 0) return vm.typeError(1, short, long, "FILE*", null);
        const handle = try vm.fileHandleArgument(args[0], 1, short, long);
        if (handle.reader == null) return vm.osFileFailure(error.BadFileDescriptor, null);
        if (args.len == 1) {
            const line = Value{ .string = vm.interner.intern("*l") catch return error.OutOfMemory };
            const value = try vm.readFormat(handle, line, 2, short, long);
            return vm.allocator.dupe(Value, &.{value}) catch return error.OutOfMemory;
        }
        var results: std.ArrayList(Value) = .empty;
        defer results.deinit(vm.allocator);
        for (args[1..], 2..) |format, argument| {
            const value = try vm.readFormat(handle, format, argument, short, long);
            results.append(vm.allocator, value) catch return error.OutOfMemory;
            if (value == .nil) break;
        }
        return results.toOwnedSlice(vm.allocator) catch return error.OutOfMemory;
    }

    /// `g_read`'s body: one format, one answer. A count of zero looks at the
    /// next byte the way `test_eof` does — nil at the end of the file and the
    /// empty string anywhere before it, with the byte left in place.
    fn readFormat(vm: *VM, handle: *FileHandle, format: Value, argument: usize, short: []const u8, long: []const u8) Error!Value {
        // A buffered write stands between the reads and the bytes it has not
        // put down yet; flush it and bring the reader up to the same spot
        if (handle.last_side == .write) {
            if (handle.writer) |*writer| {
                writer.interface.flush() catch return error.RuntimeError;
                const position = writer.pos;
                if (handle.reader) |*reader| reader.seekTo(position) catch return error.RuntimeError;
            }
            handle.last_side = .read;
        }
        if (format == .number) {
            const count = format.number.toIntExact() orelse
                return vm.raiseArgument(argument, short, long, "number has no integer representation", .{});
            // A negative count wraps to a huge `size_t` in C, so the buffer
            // it asks for cannot be had
            if (count < 0) return vm.raisePlain("not enough memory", .{});
            const reader = &handle.reader.?.interface;
            if (count == 0) {
                _ = reader.peek(1) catch |err| switch (err) {
                    error.EndOfStream => {
                        if (handle.auto_close) closeFileHandle(handle);
                        return .nil;
                    },
                    else => return error.RuntimeError,
                };
                const empty = vm.interner.intern("") catch return error.OutOfMemory;
                return .{ .string = empty };
            }
            const buffer = vm.allocator.alloc(u8, @intCast(count)) catch return error.OutOfMemory;
            defer vm.allocator.free(buffer);
            const actual = reader.readSliceShort(buffer) catch return error.RuntimeError;
            if (actual == 0) {
                if (handle.auto_close) closeFileHandle(handle);
                return .nil;
            }
            const string = vm.interner.intern(buffer[0..actual]) catch return error.OutOfMemory;
            return .{ .string = string };
        }
        const text = switch (format) {
            .string => |string| string.slice(),
            .number => unreachable,
            else => return vm.typeError(argument, short, long, "string", format),
        };
        // `*l` and friends are spelled with an optional star in front
        const pattern = if (text.len > 0 and text[0] == '*') text[1..] else text;
        if (pattern.len == 0 or (pattern[0] != 'n' and pattern[0] != 'l' and pattern[0] != 'L' and pattern[0] != 'a'))
            return vm.raiseArgument(argument, short, long, "invalid format", .{});
        switch (pattern[0]) {
            'l', 'L' => {
                const keep_ends = pattern[0] == 'L';
                const reader = &handle.reader.?.interface;
                var line: std.ArrayList(u8) = .empty;
                defer line.deinit(vm.allocator);
                var ended = false;
                while (true) {
                    const byte = reader.take(1) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return error.RuntimeError,
                    };
                    ended = true;
                    if (byte[0] == '\n') {
                        if (keep_ends) line.append(vm.allocator, '\n') catch return error.OutOfMemory;
                        break;
                    }
                    line.append(vm.allocator, byte[0]) catch return error.OutOfMemory;
                }
                if (!ended and line.items.len == 0) {
                    if (handle.auto_close) closeFileHandle(handle);
                    return .nil;
                }
                const string = vm.interner.intern(line.items) catch return error.OutOfMemory;
                return .{ .string = string };
            },
            'n' => {
                const reader = &handle.reader.?.interface;
                while (true) {
                    const next = reader.peek(1) catch |err| switch (err) {
                        error.EndOfStream => {
                            if (handle.auto_close) closeFileHandle(handle);
                            return .nil;
                        },
                        else => return error.RuntimeError,
                    };
                    if (!std.ascii.isWhitespace(next[0])) break;
                    reader.toss(1);
                }
                var token: std.ArrayList(u8) = .empty;
                defer token.deinit(vm.allocator);
                while (true) {
                    const next = reader.peek(1) catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return error.RuntimeError,
                    };
                    const byte = next[0];
                    if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '-' or byte == '.')) break;
                    token.append(vm.allocator, byte) catch return error.OutOfMemory;
                    reader.toss(1);
                }
                const number = Number.parse(token.items) orelse {
                    if (token.items.len == 0 and handle.auto_close) closeFileHandle(handle);
                    return .nil;
                };
                return .{ .number = number };
            },
            else => {
                var output: std.ArrayList(u8) = .empty;
                defer output.deinit(vm.allocator);
                const reader = &handle.reader.?.interface;
                while (true) {
                    var chunk_buffer: [1024]u8 = undefined;
                    const chunk_len = reader.readSliceShort(&chunk_buffer) catch return error.RuntimeError;
                    if (chunk_len == 0) break;
                    output.appendSlice(vm.allocator, chunk_buffer[0..chunk_len]) catch return error.OutOfMemory;
                }
                if (handle.auto_close) closeFileHandle(handle);
                const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
                return .{ .string = string };
            },
        }
    }

    /// Which metamethods a value has to offer for `checktab` to accept it in
    /// place of a table.
    const TableNeed = struct { read: bool = false, write: bool = false, len: bool = false };

    /// `checktab`: a table, or any value whose metatable supplies every
    /// metamethod the operation needs. Anything else is refused the way
    /// `luaL_checktype(L, arg, LUA_TTABLE)` would have refused it.
    fn checkTableLike(vm: *VM, value: Value, need: TableNeed, argument: usize, short: []const u8, long: []const u8) Error!void {
        if (value == .table) return;
        if (need.read and (try vm.valueMetamethod(value, "__index")) == .nil)
            return vm.typeError(argument, short, long, "table", value);
        if (need.write and (try vm.valueMetamethod(value, "__newindex")) == .nil)
            return vm.typeError(argument, short, long, "table", value);
        if (need.len and (try vm.valueMetamethod(value, "__len")) == .nil)
            return vm.typeError(argument, short, long, "table", value);
    }

    /// `luaL_len`: the `__len` metamethod where there is one, the raw length
    /// of a table or a string otherwise, and a refusal to accept an answer
    /// that is not an integer. The length failure is `luaG_runerror` from a C
    /// frame, so it carries no position; `luaL_error`'s refusals do.
    fn objectLength(vm: *VM, value: Value) Error!i64 {
        if (value == .table) {
            const method = try vm.metamethod(value.table, "__len");
            if (method != .nil) return vm.lengthAnswer(method, value);
            return value.table.len();
        }
        if (value == .string) return std.math.cast(i64, value.string.slice().len) orelse return error.RuntimeError;
        const method = try vm.valueMetamethod(value, "__len");
        if (method != .nil) return vm.lengthAnswer(method, value);
        return vm.raisePlain("attempt to get length of a {s} value", .{value.typeName()});
    }

    /// `luaL_len`'s conversion of what `__len` answered: an integer, or a
    /// float or numeric string that names one, or a refusal.
    fn lengthAnswer(vm: *VM, method: Value, value: Value) Error!i64 {
        const results = try vm.invokeCallableValues(method, &.{value});
        defer vm.allocator.free(results);
        const answer = if (results.len == 0) Value.nil else results[0];
        return switch (answer) {
            .number => |number| if (number.toIntExact()) |integer| integer else return vm.raise("object length is not an integer", .{}),
            // `luaL_len` accepts a numeric string that names an integer too
            .string => |string| blk: {
                const parsed = Number.parse(string.slice()) orelse return vm.raise("object length is not an integer", .{});
                break :blk parsed.toIntExact() orelse return vm.raise("object length is not an integer", .{});
            },
            else => vm.raise("object length is not an integer", .{}),
        };
    }

    /// `lua_geti`.
    fn tableGetIndex(vm: *VM, receiver: Value, index: i64) Error!Value {
        return vm.getTableIndex(receiver, intKey(index), "");
    }

    /// `lua_seti`.
    fn tableSetIndex(vm: *VM, receiver: Value, index: i64, value: Value) Error!void {
        try vm.setTableIndex(receiver, intKey(index), value, "");
    }

    fn tableInsert(vm: *VM, args: []const Value) Error![]Value {
        const short = "insert";
        const long = "table.insert";
        if (args.len == 0) return vm.typeError(1, short, long, "table", null);
        try vm.checkTableLike(args[0], .{ .read = true, .write = true, .len = true }, 1, short, long);
        if (args.len == 2 or args.len == 3) {
            var length = try vm.objectLength(args[0]);
            // `luaL_intop(+, e, 1)` wraps the same way
            length = length +% 1;
            const position = if (args.len == 2) length else try vm.checkInteger(args, 2, short, long);
            if (@as(u64, @bitCast(position -% 1)) >= @as(u64, @bitCast(length)))
                return vm.raiseArgument(2, short, long, "position out of bounds", .{});
            if (args.len == 3) {
                var index = length;
                while (index > position) {
                    index -= 1;
                    const value = try vm.tableGetIndex(args[0], index);
                    try vm.tableSetIndex(args[0], index + 1, value);
                }
            }
            try vm.tableSetIndex(args[0], position, args[if (args.len == 2) 1 else 2]);
            return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        }
        return vm.raise("wrong number of arguments to 'insert'", .{});
    }

    fn tableRemove(vm: *VM, args: []const Value) Error![]Value {
        const short = "remove";
        const long = "table.remove";
        if (args.len == 0) return vm.typeError(1, short, long, "table", null);
        try vm.checkTableLike(args[0], .{ .read = true, .write = true, .len = true }, 1, short, long);
        const size = try vm.objectLength(args[0]);
        const position = try vm.optInteger(args, 2, size, short, long);
        if (position != size) {
            if (@as(u64, @bitCast(position -% 1)) > @as(u64, @bitCast(size)))
                return vm.raiseArgument(2, short, long, "position out of bounds", .{});
        }
        const removed = try vm.tableGetIndex(args[0], position);
        var index = position;
        while (index < size) {
            const value = try vm.tableGetIndex(args[0], index + 1);
            try vm.tableSetIndex(args[0], index, value);
            index += 1;
        }
        // the shift walks `index` up to `size`, which is the slot the reference
        // clears once the loop it shares with this one finishes
        try vm.tableSetIndex(args[0], index, .nil);
        return vm.allocator.dupe(Value, &.{removed}) catch return error.OutOfMemory;
    }

    fn tableConcat(vm: *VM, args: []const Value) Error![]Value {
        const short = "concat";
        const long = "table.concat";
        if (args.len == 0) return vm.typeError(1, short, long, "table", null);
        try vm.checkTableLike(args[0], .{ .read = true, .len = true }, 1, short, long);
        const separator = try vm.optString(args, 2, "", short, long);
        const first = try vm.optInteger(args, 3, 1, short, long);
        const last = try vm.optInteger(args, 4, try vm.objectLength(args[0]), short, long);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        if (first <= last) {
            var index = first;
            while (index < last) : (index += 1) {
                try vm.tick();
                try vm.appendConcatField(&output, args[0], index);
                output.appendSlice(vm.allocator, separator) catch return error.OutOfMemory;
            }
            if (index == last) try vm.appendConcatField(&output, args[0], index);
        }
        const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    /// `addfield`: one element of `table.concat`, which is a string or a
    /// number and refuses everything else by naming where it was found.
    fn appendConcatField(vm: *VM, output: *std.ArrayList(u8), receiver: Value, index: i64) Error!void {
        const value = try vm.tableGetIndex(receiver, index);
        const bytes = switch (value) {
            .string => |string| string.slice(),
            .number => |number| vm.scratchNumber(number),
            else => return vm.raise("invalid value ({s}) at index {d} in table for 'concat'", .{ value.typeName(), index }),
        };
        output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
    }

    /// `tunpack`: argument one is never checked as a table, because the
    /// bounds come first and the default for the last one is a length that
    /// fails on its own for whatever it was given, which is how `table.unpack()`
    /// and `table.unpack(nil)` both end in `attempt to get length of a nil value`.
    fn tableUnpack(vm: *VM, args: []const Value) Error![]Value {
        const short = "unpack";
        const long = "table.unpack";
        const table: Value = if (args.len >= 1) args[0] else .nil;
        const first = try vm.optInteger(args, 2, 1, short, long);
        const last: i64 = if (args.len >= 3 and args[2] != .nil)
            try vm.optInteger(args, 3, 1, short, long)
        else
            try vm.objectLength(table);
        if (first > last) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const distance = std.math.sub(i64, last, first) catch return error.RuntimeError;
        const count = std.math.add(i64, distance, 1) catch return error.RuntimeError;
        if (count > std.math.maxInt(i32)) return vm.raise("too many results to unpack", .{});
        const size = std.math.cast(usize, count) orelse return error.RuntimeError;
        if (size > vm.exec.steps_left) return error.StepLimit;
        const values = vm.allocator.alloc(Value, size) catch return error.OutOfMemory;
        for (values, 0..) |*value, offset| {
            value.* = try vm.tableGetIndex(table, first + @as(i64, @intCast(offset)));
        }
        return values;
    }

    fn tablePack(vm: *VM, args: []const Value) Error![]Value {
        const table = try vm.newTable();
        for (args, 0..) |value, index| {
            const key: Value = .{ .number = Number.Number.fromInt(std.math.cast(i64, index + 1) orelse return error.RuntimeError) };
            table.set(key, value) catch return error.OutOfMemory;
        }
        const n_key: Value = .{ .string = vm.interner.intern("n") catch return error.OutOfMemory };
        table.set(n_key, .{ .number = Number.Number.fromInt(std.math.cast(i64, args.len) orelse return error.RuntimeError) }) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .table = table }}) catch return error.OutOfMemory;
    }

    fn tableMove(vm: *VM, args: []const Value) Error![]Value {
        const short = "move";
        const long = "table.move";
        const first = try vm.checkInteger(args, 2, short, long);
        const last = try vm.checkInteger(args, 3, short, long);
        const target_first = try vm.checkInteger(args, 4, short, long);
        try vm.checkTableLike(args[0], .{ .read = true }, 1, short, long);
        const explicit_destination = args.len >= 5 and args[4] != .nil;
        const destination: Value = if (explicit_destination) blk: {
            try vm.checkTableLike(args[4], .{ .write = true }, 5, short, long);
            break :blk args[4];
        } else args[0];
        if (last >= first) {
            if (!(first > 0 or last < std.math.maxInt(i64) +% first))
                return vm.raiseArgument(3, short, long, "too many elements to move", .{});
            const count = @as(i128, last) - @as(i128, first) + 1;
            if (@as(i128, target_first) > @as(i128, std.math.maxInt(i64)) - count + 1)
                return vm.raiseArgument(4, short, long, "destination wrap around", .{});
            const forwards = target_first > last or target_first <= first or
                (explicit_destination and !(try vm.equalWithMetamethod(args[0], destination)));
            var offset: i128 = 0;
            while (offset < count) {
                const step: i64 = @intCast(if (forwards) offset else count - offset - 1);
                const value = try vm.tableGetIndex(args[0], first + step);
                try vm.tableSetIndex(destination, target_first + step, value);
                offset += 1;
                try vm.tick();
            }
        }
        return vm.allocator.dupe(Value, &.{destination}) catch return error.OutOfMemory;
    }

    fn tableSort(vm: *VM, args: []const Value) Error![]Value {
        const short = "sort";
        const long = "table.sort";
        if (args.len == 0) return vm.typeError(1, short, long, "table", null);
        try vm.checkTableLike(args[0], .{ .read = true, .write = true, .len = true }, 1, short, long);
        const length = try vm.objectLength(args[0]);
        if (length > 1) {
            if (length >= std.math.maxInt(i32)) return vm.raiseArgument(1, short, long, "array too big", .{});
            // only a non-trivial interval is checked for a comparator, which is
            // what makes `table.sort({}, 1)` succeed
            const comparator: ?Value = if (args.len > 1 and args[1] != .nil)
                try vm.checkFunction(args, 2, short, long)
            else
                null;
            const size: usize = @intCast(length);
            const values = vm.allocator.alloc(Value, size) catch return error.OutOfMemory;
            defer vm.allocator.free(values);
            for (values, 0..) |*value, i| value.* = try vm.tableGetIndex(args[0], @intCast(i + 1));
            try vm.auxSort(values, comparator, 1, size);
            for (values, 0..) |value, i| try vm.tableSetIndex(args[0], @intCast(i + 1), value);
        }
        return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
    }

    /// `auxsort`: the reference's quicksort over the copied range, indices
    /// one-based and inclusive on both ends the way `ltablib.c` writes them, so
    /// that the two `invalid order function for sorting` refusals land on the
    /// same comparisons.
    fn auxSort(vm: *VM, values: []Value, comparator: ?Value, start: usize, end: usize) Error!void {
        var lo = start;
        var up = end;
        while (lo < up) {
            try vm.tick();
            if (try vm.sortLess(comparator, values[up - 1], values[lo - 1])) sortSwap(values, lo, up);
            if (up - lo == 1) return;
            const middle = (lo + up) / 2;
            if (try vm.sortLess(comparator, values[middle - 1], values[lo - 1])) {
                sortSwap(values, middle, lo);
            } else if (try vm.sortLess(comparator, values[up - 1], values[middle - 1])) {
                sortSwap(values, middle, up);
            }
            if (up - lo == 2) return;
            // the pivot goes to `up - 1` so the partition can hold it there
            sortSwap(values, middle, up - 1);
            const cut = try vm.sortPartition(values, comparator, lo, up);
            if (cut - lo < up - cut) {
                try vm.auxSort(values, comparator, lo, cut - 1);
                lo = cut + 1;
            } else {
                try vm.auxSort(values, comparator, cut + 1, up);
                up = cut - 1;
            }
        }
    }

    fn sortPartition(vm: *VM, values: []Value, comparator: ?Value, lo: usize, up: usize) Error!usize {
        // the pivot sits at `up - 1` for the whole partition and is only moved
        // by the swap that returns
        const pivot = values[up - 2];
        var i = lo;
        var j = up - 1;
        while (true) {
            i += 1;
            while (true) {
                if (!try vm.sortLess(comparator, values[i - 1], pivot)) break;
                if (i == up - 1) return vm.raise("invalid order function for sorting", .{});
                i += 1;
            }
            j -= 1;
            while (true) {
                if (!try vm.sortLess(comparator, pivot, values[j - 1])) break;
                if (j < i) return vm.raise("invalid order function for sorting", .{});
                j -= 1;
            }
            if (j < i) {
                sortSwap(values, i, up - 1);
                return i;
            }
            sortSwap(values, i, j);
        }
    }

    fn sortSwap(values: []Value, a: usize, b: usize) void {
        const held = values[a - 1];
        values[a - 1] = values[b - 1];
        values[b - 1] = held;
    }

    fn sortLess(vm: *VM, comparator: ?Value, left: Value, right: Value) Error!bool {
        if (comparator) |function| {
            const results = try vm.invokeCallableValues(function, &.{ left, right });
            defer vm.allocator.free(results);
            return results.len != 0 and results[0].truthy();
        }
        return vm.lessThanValues(left, right);
    }

    /// The `<` operator without an AST to describe its operands with, which is
    /// what `table.sort` compares with when it is handed no function. The
    /// comparison failure reaches us through `lua_compare`, so it is
    /// `luaG_runerror` and carries no position of its own.
    fn lessThanValues(vm: *VM, left: Value, right: Value) Error!bool {
        if (left == .string and right == .string)
            return std.mem.order(u8, left.string.slice(), right.string.slice()) == .lt;
        if (left == .number and right == .number) return Number.less(left.number, right.number);
        const method = try vm.binaryMetamethod(left, right, "__lt");
        if (method == .nil) {
            const left_name = left.typeName();
            const right_name = right.typeName();
            if (std.mem.eql(u8, left_name, right_name))
                return vm.raisePlain("attempt to compare two {s} values", .{left_name});
            return vm.raisePlain("attempt to compare {s} with {s}", .{ left_name, right_name });
        }
        const results = try vm.invokeCallableValues(method, &.{ left, right });
        defer vm.allocator.free(results);
        return results.len != 0 and results[0].truthy();
    }

    fn intArgument(value: Value) Error!i64 {
        return switch (value) {
            .number => |number| number.toIntExact() orelse error.RuntimeError,
            else => error.RuntimeError,
        };
    }

    fn intKey(value: i64) Value {
        return .{ .number = Number.Number.fromInt(value) };
    }

    fn invokeManyExpr(vm: *VM, function: *@import("Value.zig").Function, args: []const Ast.Expression) Error![]Value {
        const values = try vm.evalList(args);
        defer vm.allocator.free(values);
        return vm.invokeValues(function, values);
    }

    fn invokeValues(vm: *VM, function: *@import("Value.zig").Function, argument_values: []const Value) Error![]Value {
        if (function.semantics.functions.len <= function.function_index) return error.RuntimeError;
        const old_locals = vm.exec.locals;
        const old_function_index = vm.exec.function_index;
        const old_returned = vm.exec.returned;
        const old_goto_name = vm.exec.goto_name;
        const old_upvalues = vm.exec.upvalues;
        const old_varargs = vm.exec.varargs;
        const old_environment = vm.exec.active_environment;
        const old_semantics = vm.exec.semantics;
        // `currentline` in the reference names the position of the caller's
        // own instruction, which stays put while the call runs; the offset the
        // call site left behind has to survive the callee's expressions.
        const caller_offset = vm.exec.error_offset;
        const saved_results = vm.exec.results;
        const locals_root_start = vm.exec.suspended_locals.items.len;
        const varargs_root_start = vm.exec.suspended_varargs.items.len;
        const results_root_start = vm.exec.suspended_results.items.len;
        const functions_root_start = vm.exec.active_functions.items.len;
        errdefer {
            vm.exec.suspended_locals.shrinkRetainingCapacity(locals_root_start);
            vm.exec.suspended_varargs.shrinkRetainingCapacity(varargs_root_start);
            vm.exec.suspended_results.shrinkRetainingCapacity(results_root_start);
            vm.exec.active_functions.shrinkRetainingCapacity(functions_root_start);
        }
        vm.exec.suspended_locals.append(vm.allocator, old_locals) catch return error.OutOfMemory;
        vm.exec.suspended_varargs.append(vm.allocator, old_varargs) catch return error.OutOfMemory;
        vm.exec.suspended_results.append(vm.allocator, saved_results.items) catch return error.OutOfMemory;
        vm.exec.active_functions.append(vm.allocator, function) catch return error.OutOfMemory;
        vm.exec.error_frames.append(vm.allocator, .{ .program = function.semantics, .call_offset = caller_offset }) catch return error.OutOfMemory;
        defer _ = vm.exec.error_frames.pop();
        const called_semantics = function.semantics;
        const frame_size = called_semantics.functions[function.function_index].frame_size;
        const new_locals = try vm.allocFrame(frame_size);
        const parameter_count = called_semantics.functions[function.function_index].parameters.len;
        vm.exec.semantics = called_semantics;
        vm.exec.results = .empty;
        vm.exec.returned = false;
        vm.exec.goto_name = null;
        vm.exec.function_index = function.function_index;
        vm.exec.locals = new_locals;
        vm.exec.upvalues = function.captures;
        vm.exec.active_environment = function.environment;
        vm.exec.varargs = if (vm.exec.semantics.functions[function.function_index].is_vararg and argument_values.len > parameter_count) argument_values[parameter_count..] else &.{};
        defer {
            vm.exec.results.deinit(vm.allocator);
            vm.exec.results = saved_results;
            vm.exec.locals = old_locals;
            vm.exec.function_index = old_function_index;
            vm.exec.returned = old_returned;
            vm.exec.goto_name = old_goto_name;
            vm.exec.upvalues = old_upvalues;
            vm.exec.varargs = old_varargs;
            vm.exec.active_environment = old_environment;
            vm.exec.semantics = old_semantics;
            vm.exec.error_offset = caller_offset;
            vm.exec.suspended_locals.shrinkRetainingCapacity(locals_root_start);
            vm.exec.suspended_varargs.shrinkRetainingCapacity(varargs_root_start);
            vm.exec.suspended_results.shrinkRetainingCapacity(results_root_start);
            vm.exec.active_functions.shrinkRetainingCapacity(functions_root_start);
        }
        for (0..parameter_count) |i| {
            vm.exec.locals[i].value = if (i < argument_values.len) argument_values[i] else .nil;
        }
        vm.gc_deferral_depth += 1;
        defer vm.gc_deferral_depth -= 1;
        try vm.execBlock(&function.body.block);
        return vm.allocator.dupe(Value, vm.exec.results.items) catch return error.OutOfMemory;
    }

    fn allocFrame(vm: *VM, count: usize) Error![]*@import("Value.zig").Cell {
        const cells = vm.allocator.alloc(@import("Value.zig").Cell, count) catch return error.OutOfMemory;
        errdefer vm.allocator.free(cells);
        const pointers = vm.allocator.alloc(*@import("Value.zig").Cell, count) catch return error.OutOfMemory;
        errdefer vm.allocator.free(pointers);
        for (cells, 0..) |*cell, i| {
            cell.value = .nil;
            pointers[i] = cell;
        }
        vm.owned_frames.append(vm.allocator, .{ .cells = cells, .pointers = pointers }) catch return error.OutOfMemory;
        return pointers;
    }

    fn installBaseLibrary(vm: *VM) Error!void {
        const names = .{
            .{ "print", ValueModule.NativeFunction.base_print },
            .{ "type", ValueModule.NativeFunction.base_type },
            .{ "tostring", ValueModule.NativeFunction.base_tostring },
            .{ "tonumber", ValueModule.NativeFunction.base_tonumber },
            .{ "assert", ValueModule.NativeFunction.base_assert },
            .{ "error", ValueModule.NativeFunction.base_error },
            .{ "pcall", ValueModule.NativeFunction.base_pcall },
            .{ "xpcall", ValueModule.NativeFunction.base_xpcall },
            .{ "select", ValueModule.NativeFunction.base_select },
            .{ "rawequal", ValueModule.NativeFunction.base_rawequal },
            .{ "rawget", ValueModule.NativeFunction.base_rawget },
            .{ "rawset", ValueModule.NativeFunction.base_rawset },
            .{ "rawlen", ValueModule.NativeFunction.base_rawlen },
            .{ "setmetatable", ValueModule.NativeFunction.base_setmetatable },
            .{ "getmetatable", ValueModule.NativeFunction.base_getmetatable },
            .{ "load", ValueModule.NativeFunction.base_load },
            .{ "loadfile", ValueModule.NativeFunction.base_loadfile },
            .{ "dofile", ValueModule.NativeFunction.base_dofile },
            .{ "warn", ValueModule.NativeFunction.base_warn },
            .{ "collectgarbage", ValueModule.NativeFunction.base_collectgarbage },
            .{ "next", ValueModule.NativeFunction.next },
            .{ "pairs", ValueModule.NativeFunction.pairs },
            .{ "ipairs", ValueModule.NativeFunction.ipairs },
        };
        inline for (names) |entry| try vm.putNative(vm.globals, entry.@"0", entry.@"1");
        vm.globals.set(.{ .string = vm.interner.intern("_G") catch return error.OutOfMemory }, .{ .table = vm.globals }) catch return error.OutOfMemory;
        vm.globals.set(.{ .string = vm.interner.intern("_VERSION") catch return error.OutOfMemory }, .{ .string = vm.interner.intern("Lua 5.4") catch return error.OutOfMemory }) catch return error.OutOfMemory;
    }

    fn installCoroutineLibrary(vm: *VM) Error!void {
        const library = try vm.newTable();
        try vm.putNative(library, "create", .coroutine_create);
        try vm.putNative(library, "resume", .coroutine_resume);
        try vm.putNative(library, "yield", .coroutine_yield);
        try vm.putNative(library, "status", .coroutine_status);
        try vm.putNative(library, "running", .coroutine_running);
        try vm.putNative(library, "isyieldable", .coroutine_isyieldable);
        try vm.putNative(library, "close", .coroutine_close);
        try vm.putNative(library, "wrap", .coroutine_wrap);
        vm.globals.set(.{ .string = vm.interner.intern("coroutine") catch return error.OutOfMemory }, .{ .table = library }) catch return error.OutOfMemory;
        // The main coroutine exists from the start so that `running` and
        // `status` have the thread object the reference calls `mainthread`.
        const object = vm.tracker.alloc(ValueModule.Thread, .thread) catch return error.OutOfMemory;
        const coroutine = vm.allocator.create(Coroutine) catch return error.OutOfMemory;
        coroutine.* = .{
            .vm = vm,
            .object = object,
            .thread_value = .{ .thread = object },
            .status = .running,
            .main = true,
        };
        object.coroutine = coroutine;
        vm.exec.coroutine = coroutine;
        vm.coroutines.append(vm.allocator, coroutine) catch return error.OutOfMemory;
    }

    fn basePrint(vm: *VM, args: []const Value) Error![]Value {
        const writer = vm.writer orelse return error.RuntimeError;
        for (args, 0..) |value, i| {
            if (i != 0) writer.writeByte('\t') catch return error.RuntimeError;
            try vm.writeValue(writer, value);
        }
        writer.writeByte('\n') catch return error.RuntimeError;
        return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
    }

    /// `luaB_warn`: a first argument has to be there and read as a string,
    /// and so does every argument after it. A control message is only a
    /// control message when it is the whole call, which is where the
    /// reference's `tocont` is zero on the first and only warning part.
    fn baseWarn(vm: *VM, args: []const Value) Error![]Value {
        const short = "warn";
        const long = "warn";
        const first = try vm.checkString(args, 1, short, long);
        for (2..args.len + 1) |index| _ = try vm.checkString(args, index, short, long);
        if (args.len == 1 and first.len > 0 and first[0] == '@') {
            if (std.mem.eql(u8, first, "@on")) vm.warn_state = .ready else if (std.mem.eql(u8, first, "@off")) vm.warn_state = .off;
            // an unknown control message is swallowed the way `checkcontrol`
            // swallows it: nothing is printed either way
            return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        }
        if (vm.warn_state == .off) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const writer = vm.stderr orelse return error.RuntimeError;
        writer.writeAll("Lua warning: ") catch return error.RuntimeError;
        for (args) |value| {
            const bytes = try vm.stringBytesInto(value, &vm.number_buffer);
            writer.writeAll(bytes) catch return error.RuntimeError;
        }
        writer.writeByte('\n') catch return error.RuntimeError;
        vm.warn_state = .ready;
        return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
    }

    /// `luaB_collectgarbage`. The option is read the way `luaL_checkoption`
    /// reads it: an absent or nil first argument means `"collect"`, anything
    /// else is a string once it has been coerced, and an unknown name is the
    /// refusal naming what it was given. The options this runtime has no
    /// knobs for are still accepted, so that the call succeeds as it does in
    /// the reference.
    fn baseCollectGarbage(vm: *VM, args: []const Value) Error![]Value {
        const short = "collectgarbage";
        const long = "collectgarbage";
        const option = try vm.optString(args, 1, "collect", short, long);
        const known = [_][]const u8{ "stop", "restart", "collect", "count", "step", "setpause", "setstepmul", "isrunning", "generational", "incremental" };
        var valid = false;
        for (known) |candidate| {
            if (std.mem.eql(u8, option, candidate)) {
                valid = true;
                break;
            }
        }
        if (!valid) return vm.raiseArgument(1, short, long, "invalid option '{s}'", .{option});
        if (std.mem.eql(u8, option, "collect")) {
            vm.gc_pending = true;
            // the reference hands back 0 after a full collection
            vm.gc_at_pause = true;
            return vm.singleNumber(Number.Number.fromInt(0));
        }
        if (std.mem.eql(u8, option, "stop")) {
            vm.gc_stopped = true;
            vm.gc_pending = false;
            return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        }
        if (std.mem.eql(u8, option, "restart")) {
            vm.gc_stopped = false;
            return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        }
        if (std.mem.eql(u8, option, "isrunning")) {
            return vm.allocator.dupe(Value, &.{.{ .boolean = !vm.gc_stopped }}) catch return error.OutOfMemory;
        }
        if (std.mem.eql(u8, option, "count")) {
            const kilobytes = @as(f64, @floatFromInt(vm.memoryEstimate())) / 1024.0;
            return vm.singleNumber(Number.Number.fromFloat(kilobytes));
        }
        if (std.mem.eql(u8, option, "step")) {
            if (args.len > 1 and args[1] != .nil) _ = try vm.checkInteger(args, 2, short, long);
            // a stopped collector does not step, so it never finishes a cycle
            if (vm.gc_stopped) return vm.allocator.dupe(Value, &.{.{ .boolean = false }}) catch return error.OutOfMemory;
            vm.gc_pending = true;
            // one basic step from pause begins a cycle and does not finish one,
            // which is what the reference answers straight after a collect; the
            // next finishes the outstanding cycle and answers true
            const finished = !vm.gc_at_pause;
            vm.gc_at_pause = !vm.gc_at_pause;
            return vm.allocator.dupe(Value, &.{.{ .boolean = finished }}) catch return error.OutOfMemory;
        }
        // `setpause`, `setstepmul`, `generational`, `incremental`: nothing to
        // adjust here, but the reference accepts them and answers something
        return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
    }

    fn collectAtSafePoint(vm: *VM) Error!void {
        // An interpreted call can be nested inside expression evaluation, where
        // callers still hold values only in Zig locals. Defer sweeping until the
        // outermost script statement has finished evaluating those temporaries.
        if (!vm.gc_pending or vm.gc_deferral_depth != 0) return;
        // A suspended coroutine keeps values alive that only exist in the Zig
        // frames parked on its host stack, which tracing cannot see. While one
        // is parked, no sweep is safe.
        for (vm.coroutines.items) |coroutine| {
            if (coroutine.started and coroutine.status == .suspended) return;
        }
        var roots: std.ArrayList(Value) = .empty;
        defer roots.deinit(vm.allocator);
        try roots.append(vm.allocator, .{ .table = vm.globals });
        try roots.append(vm.allocator, vm.global_environment.value);
        try roots.append(vm.allocator, vm.exec.active_environment.value);
        for (vm.coroutines.items) |coroutine| {
            try roots.append(vm.allocator, coroutine.thread_value);
            try roots.append(vm.allocator, coroutine.body);
            if (coroutine.error_value) |value| try roots.append(vm.allocator, value);
            for (coroutine.transfer) |value| try roots.append(vm.allocator, value);
        }
        if (vm.string_metatable) |metatable| try roots.append(vm.allocator, .{ .table = metatable });
        if (vm.file_metatable) |metatable| try roots.append(vm.allocator, .{ .table = metatable });
        if (vm.default_input) |table| try roots.append(vm.allocator, .{ .table = table });
        if (vm.default_output) |table| try roots.append(vm.allocator, .{ .table = table });
        if (vm.default_error) |table| try roots.append(vm.allocator, .{ .table = table });
        if (vm.stdin_cache) |table| try roots.append(vm.allocator, .{ .table = table });
        if (vm.stdout_cache) |table| try roots.append(vm.allocator, .{ .table = table });
        if (vm.stderr_cache) |table| try roots.append(vm.allocator, .{ .table = table });
        for (vm.exec.locals) |cell| try roots.append(vm.allocator, cell.value);
        for (vm.exec.suspended_locals.items) |frame| for (frame) |cell| try roots.append(vm.allocator, cell.value);
        for (vm.exec.upvalues) |cell| try roots.append(vm.allocator, cell.value);
        for (vm.exec.varargs) |value| try roots.append(vm.allocator, value);
        for (vm.exec.suspended_varargs.items) |values| for (values) |value| try roots.append(vm.allocator, value);
        for (vm.exec.results.items) |value| try roots.append(vm.allocator, value);
        for (vm.exec.suspended_results.items) |values| for (values) |value| try roots.append(vm.allocator, value);
        for (vm.exec.close_values.items) |value| try roots.append(vm.allocator, value);
        if (vm.exec.thrown_error) |value| try roots.append(vm.allocator, value);
        for (vm.exec.active_functions.items) |function| try roots.append(vm.allocator, .{ .function = function });
        const result = try vm.collector.collectWith(vm.tracker, roots.items, vm, forgetOwnedObject);
        vm.gc_threshold = @max(1024, std.math.mul(usize, result.live, 2) catch std.math.maxInt(usize));
        vm.gc_pending = false;
    }

    fn memoryEstimate(vm: *const VM) usize {
        var bytes = vm.tracker.memory_bytes;
        const Tables = struct {
            bytes: *usize,
            pub fn count(context: @This(), common: *@import("Object.zig").Common) void {
                if (common.kind != .table) return;
                const table: *Table = @fieldParentPtr("common", common);
                context.bytes.* +|= table.array.len * @sizeOf(Value) + table.nodes.len * @sizeOf(Table.Node);
            }
        };
        vm.tracker.walk(Tables{ .bytes = &bytes });
        for (vm.owned_frames.items) |frame| bytes +|= frame.cells.len * @sizeOf(@import("Value.zig").Cell) + frame.pointers.len * @sizeOf(*@import("Value.zig").Cell);
        for (vm.owned_captures.items) |captures| bytes +|= captures.len * @sizeOf(*@import("Value.zig").Cell);
        bytes +|= vm.owned_cells.items.len * @sizeOf(@import("Value.zig").Cell);
        return bytes;
    }

    fn forgetOwnedObject(vm: *VM, common: *@import("Object.zig").Common) void {
        switch (common.kind) {
            .table => {
                const table: *Table = @fieldParentPtr("common", common);
                for (vm.owned_files.items, 0..) |handle, i| if (handle.table == table) {
                    closeFileHandle(handle);
                    vm.allocator.destroy(handle);
                    _ = vm.owned_files.swapRemove(i);
                    break;
                };
                for (vm.owned_tables.items, 0..) |owned, i| if (owned == table) {
                    _ = vm.owned_tables.swapRemove(i);
                    break;
                };
            },
            .function => {
                const function: *@import("Value.zig").Function = @fieldParentPtr("common", common);
                for (vm.owned_functions.items, 0..) |owned, i| if (owned == function) {
                    _ = vm.owned_functions.swapRemove(i);
                    break;
                };
                // `coroutine.wrap`'s wrappers are functions too, but they own
                // no captures slice.
                if (function.native != null) return;
                for (vm.owned_captures.items, 0..) |captures, i| if (captures.ptr == function.captures.ptr) {
                    vm.allocator.free(captures);
                    _ = vm.owned_captures.swapRemove(i);
                    break;
                };
            },
            else => {},
        }
    }

    fn baseType(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1) return vm.raiseArgument(1, "type", "type", "value expected", .{});
        return vm.allocator.dupe(Value, &.{.{ .string = vm.interner.intern(args[0].typeName()) catch return error.OutOfMemory }}) catch return error.OutOfMemory;
    }

    /// `luaB_load`. A string — or a number, which `lua_tolstring` converts in
    /// place so `load(1)` compiles `"1"` — is the chunk to compile, and a
    /// function is called for its pieces; anything else is refused the way
    /// `luaL_checktype` refuses it. The chunk name defaults to the source
    /// itself for a string and to `=(load)` for a reader.
    fn baseLoad(vm: *VM, args: []const Value) Error![]Value {
        const short = "load";
        const long = "load";
        // `lua_tolstring` on arg 1: numbers are converted in place and
        // anything else leaves s NULL, which decides the path below.
        const is_text = args.len > 0 and (args[0] == .string or args[0] == .number);
        const mode = try vm.optString(args, 3, "bt", short, long);
        const chunk_name: []const u8 = if (args.len > 1 and args[1] != .nil)
            try vm.checkString(args, 2, short, long)
        else if (args.len > 0 and args[0] == .string)
            args[0].string.slice()
        else if (args.len > 0 and args[0] == .number)
            vm.numberBytes(args[0].number)
        else
            "=(load)";
        if (!is_text) {
            // a native function reads pieces the same way a Lua one does, so
            // `load(print)` is a load and not a type error
            if (args.len == 0) return vm.typeError(1, short, long, "function", null);
            switch (args[0]) {
                .function, .native_function => {},
                else => return vm.typeError(1, short, long, "function", args[0]),
            }
        }
        if (args.len > 0 and (args[0] == .function or args[0] == .native_function)) {
            var pieces: std.ArrayList(u8) = .empty;
            defer pieces.deinit(vm.allocator);
            // The reader's first piece alone decides the shape of the load:
            // its value type is checked before the mode is even consulted,
            // an empty or nil piece ends the chunk, and its first byte turns
            // the load binary or text, the way `f_parser`'s `zgetc` does.
            switch (try vm.pullLoadPiece(args[0], &pieces)) {
                .eof => {},
                .failed => |result| return result,
                .piece => if (pieces.items[0] == binary_chunk_intro) {
                    if (std.mem.indexOfScalar(u8, mode, 'b') == null)
                        return vm.loadModeRefusal("binary", mode);
                    // The header is checked with only the bytes pulled so
                    // far, pulling another piece just when a check still
                    // needs bytes: a reader that fails later never runs once
                    // a check has said no, and end of input is a truncation
                    while (true) {
                        switch (binaryLoadVerdict(pieces.items)) {
                            .valid => return vm.loadBinaryUnsupported(chunk_name),
                            .failed => |reason| return vm.loadBinaryFailure(chunk_name, reason),
                            .more => {},
                        }
                        switch (try vm.pullLoadPiece(args[0], &pieces)) {
                            .piece => {},
                            .failed => |result| return result,
                            .eof => break,
                        }
                    }
                    return vm.loadBinaryFailure(chunk_name, "truncated chunk");
                } else {
                    if (std.mem.indexOfScalar(u8, mode, 't') == null)
                        return vm.loadModeRefusal("text", mode);
                    // The reference parses as the pieces arrive, so a reader
                    // is asked for another piece only while its text could
                    // still use one: a failure whose token ends where the
                    // text does is the lexer starving, and more input may
                    // complete or confirm it, while a failure with text
                    // behind the token is the parser's answer. A parse that
                    // stands so far is no answer at all — only end of input
                    // confirms it.
                    var starving: ?[]Value = null;
                    while (true) {
                        switch (try vm.pullLoadPiece(args[0], &pieces)) {
                            .failed => |result| {
                                // the reader's own error supersedes whatever
                                // an earlier round kept
                                if (starving) |old| vm.allocator.free(old);
                                return result;
                            },
                            .eof => break,
                            .piece => {
                                var token_at_end = false;
                                const attempt = try vm.loadCompileProbe(pieces.items, chunk_name, args, &token_at_end);
                                if (attempt.len == 0 or attempt[0] != .nil) {
                                    // parses so far; the next round decides,
                                    // and a kept failure is answered by it
                                    vm.allocator.free(attempt);
                                    if (starving) |old| vm.allocator.free(old);
                                    starving = null;
                                } else if (!token_at_end) {
                                    if (starving) |old| vm.allocator.free(old);
                                    return attempt;
                                } else {
                                    if (starving) |old| vm.allocator.free(old);
                                    starving = attempt;
                                }
                            },
                        }
                    }
                    if (starving) |failure| return failure;
                    return vm.loadCompile(pieces.items, chunk_name, args);
                },
            }
            // an empty chunk is still a text chunk, and still owes the mode
            if (std.mem.indexOfScalar(u8, mode, 't') == null)
                return vm.loadModeRefusal("text", mode);
            return vm.loadCompile(pieces.items, chunk_name, args);
        }
        const source = if (args[0] == .number) vm.numberBytes(args[0].number) else args[0].string.slice();
        if (source.len > 0 and source[0] == binary_chunk_intro) {
            if (std.mem.indexOfScalar(u8, mode, 'b') == null)
                return vm.loadModeRefusal("binary", mode);
            return switch (binaryLoadVerdict(source)) {
                .valid => vm.loadBinaryUnsupported(chunk_name),
                .failed => |reason| vm.loadBinaryFailure(chunk_name, reason),
                .more => vm.loadBinaryFailure(chunk_name, "truncated chunk"),
            };
        }
        if (std.mem.indexOfScalar(u8, mode, 't') == null)
            return vm.loadModeRefusal("text", mode);
        return vm.loadCompile(source, chunk_name, args);
    }

    /// One `generic_reader` round: append the reader's next piece and report
    /// whether there is one. Nil — or nothing returned — ends the chunk, and
    /// so does an empty piece, which `luaZ_fill` reads as end of input. A
    /// number is a piece like any other, since `lua_isstring` accepts one.
    /// The two ways the round itself can fail come back as the load's
    /// failure half, the way the reference's protected parser hands them
    /// over: nil plus the message.
    const LoadPiece = union(enum) { piece, eof, failed: []Value };

    fn pullLoadPiece(vm: *VM, reader: Value, pieces: *std.ArrayList(u8)) Error!LoadPiece {
        const saved_error = vm.exec.thrown_error;
        vm.exec.thrown_error = null;
        const results = vm.invokeCallableValues(reader, &.{}) catch |err| switch (err) {
            // a reader that raises gives the load its error object, thrown
            // shape and position intact, rather than raising through it
            error.RuntimeError => {
                const thrown = vm.exec.thrown_error orelse .nil;
                vm.exec.thrown_error = saved_error;
                return .{ .failed = try vm.loadPair(thrown) };
            },
            else => {
                vm.exec.thrown_error = saved_error;
                return err;
            },
        };
        vm.exec.thrown_error = saved_error;
        defer vm.allocator.free(results);
        const piece = if (results.len == 0) .nil else results[0];
        switch (piece) {
            .nil => return .eof,
            .string => |string| {
                const slice = string.slice();
                if (slice.len == 0) return .eof;
                pieces.appendSlice(vm.allocator, slice) catch return error.OutOfMemory;
                return .piece;
            },
            .number => |number| {
                pieces.appendSlice(vm.allocator, vm.numberBytes(number)) catch return error.OutOfMemory;
                return .piece;
            },
            // The reference's `luaL_error` from inside the load:
            // `luaL_where` gives the load call's line, or nothing at all
            // where the caller is itself a native, as it is under `pcall`.
            // The traceback it appends where an error handler is installed
            // is a gap lualite shares with every other untraced error.
            else => {
                var buffer: [192]u8 = undefined;
                const message = if (try vm.errorPosition(1, &buffer)) |position|
                    std.fmt.allocPrint(vm.allocator, "{s}reader function must return a string", .{position}) catch return error.OutOfMemory
                else
                    vm.allocator.dupe(u8, "reader function must return a string") catch return error.OutOfMemory;
                defer vm.allocator.free(message);
                return .{ .failed = try vm.loadFailure(message) };
            },
        }
    }

    /// The failure half of a load that stopped on the reader's own error:
    /// nil plus the error object exactly as it was thrown.
    fn loadPair(vm: *VM, failure: Value) Error![]Value {
        return vm.allocator.dupe(Value, &.{ .nil, failure }) catch return error.OutOfMemory;
    }

    /// `checkmode`'s refusal: a bare raise from the parser, carrying the
    /// mode as written and no position of its own.
    fn loadModeRefusal(vm: *VM, kind: []const u8, mode: []const u8) Error![]Value {
        const message = std.fmt.allocPrint(vm.allocator, "attempt to load a {s} chunk (mode is '{s}')", .{ kind, mode }) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        return vm.loadFailure(message);
    }

    /// `luaU_undump` refusing the chunk: the name is shown the way the
    /// undumper shows it — an `=` or `@` intro dropped, a signature-named
    /// source reading as `binary string` — and the reason follows with no
    /// line, since a binary chunk has none.
    fn loadBinaryFailure(vm: *VM, chunk_name: []const u8, reason: []const u8) Error![]Value {
        const message = std.fmt.allocPrint(vm.allocator, "{s}: bad binary format ({s})", .{ binaryErrorPrefix(chunk_name), reason }) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        return vm.loadFailure(message);
    }

    /// A chunk whose header checks out, which the reference would happily
    /// execute and lualite cannot: there is no bytecode reader behind its
    /// tree-walking evaluator. The refusal stands where execution would.
    fn loadBinaryUnsupported(vm: *VM, chunk_name: []const u8) Error![]Value {
        const message = std.fmt.allocPrint(vm.allocator, "{s}: cannot load binary chunks", .{binaryErrorPrefix(chunk_name)}) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        return vm.loadFailure(message);
    }

    /// Compile `source` as the chunk `chunk_name`, with `args[3]` as the
    /// environment when present, and hand back the loaded function. Every
    /// compile failure is a `nil, message` pair, never a raise.
    fn loadCompile(vm: *VM, source: []const u8, chunk_name: []const u8, args: []const Value) Error![]Value {
        var token_at_end = false;
        return vm.loadCompileProbe(source, chunk_name, args, &token_at_end);
    }

    /// The same compile, also reporting whether a syntax failure's token
    /// ends where the text does: that is the lexer starving for input
    /// rather than objecting to it, and so the one sort of failure a
    /// reader's next piece could still change.
    fn loadCompileProbe(vm: *VM, source: []const u8, chunk_name: []const u8, args: []const Value, token_at_end: *bool) Error![]Value {
        var arena_ptr = vm.allocator.create(std.heap.ArenaAllocator) catch return error.OutOfMemory;
        arena_ptr.* = .init(vm.allocator);
        var arena_transferred = false;
        errdefer if (!arena_transferred) {
            arena_ptr.deinit();
            vm.allocator.destroy(arena_ptr);
        };
        const arena = arena_ptr.allocator();
        const owned_source = arena.dupe(u8, source) catch return error.OutOfMemory;
        _ = arena.dupe(u8, chunk_name) catch return error.OutOfMemory;
        var diagnostics: @import("Diagnostic.zig").Reporter = .{ .gpa = vm.allocator };
        defer diagnostics.deinit();
        var parser = @import("Parser.zig").fromSource(owned_source, arena_ptr, &diagnostics);
        const chunk = parser.parseChunk() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReportFailed, error.ParserFailed => {
                // the message is built while the arena still holds the source
                // it points into; freeing first is a use-after-free that reads
                // fine on a small chunk and faults on a large one
                noteStarvedToken(&diagnostics, owned_source, token_at_end);
                const failure = try vm.loadSyntaxFailure(&diagnostics, owned_source, chunk_name);
                arena_ptr.deinit();
                vm.allocator.destroy(arena_ptr);
                arena_transferred = true;
                return failure;
            },
        };
        const semantics = arena.create(Semantic.Program) catch return error.OutOfMemory;
        semantics.* = Semantic.analyze(arena, &diagnostics, &chunk) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReportFailed => {
                noteStarvedToken(&diagnostics, owned_source, token_at_end);
                const failure = try vm.loadSyntaxFailure(&diagnostics, owned_source, chunk_name);
                arena_ptr.deinit();
                vm.allocator.destroy(arena_ptr);
                arena_transferred = true;
                return failure;
            },
        };
        semantics.source = owned_source;
        semantics.chunk_name = arena.dupe(u8, chunk_name) catch return error.OutOfMemory;
        if (diagnostics.errors.items.len != 0) {
            noteStarvedToken(&diagnostics, owned_source, token_at_end);
            const failure = try vm.loadSyntaxFailure(&diagnostics, owned_source, chunk_name);
            arena_ptr.deinit();
            vm.allocator.destroy(arena_ptr);
            arena_transferred = true;
            return failure;
        }
        vm.owned_program_arenas.append(vm.allocator, arena_ptr) catch return error.OutOfMemory;
        arena_transferred = true;

        const closure_env = vm.allocator.create(@import("Value.zig").Cell) catch return error.OutOfMemory;
        closure_env.* = .{ .value = if (args.len > 3 and args[3] != .nil) args[3] else .{ .table = vm.globals } };
        vm.owned_cells.append(vm.allocator, closure_env) catch {
            vm.allocator.destroy(closure_env);
            return error.OutOfMemory;
        };
        const body = arena.create(Ast.FunctionBody) catch return error.OutOfMemory;
        body.* = .{
            .span = chunk.span,
            .open_paren_span = .{ .start = chunk.span.start, .end = chunk.span.start },
            .parameters = &.{},
            .vararg = null,
            .close_paren_span = .{ .start = chunk.span.start, .end = chunk.span.start },
            .block = chunk.block,
            .end_span = .{ .start = chunk.span.end, .end = chunk.span.end },
        };
        const function = vm.tracker.alloc(@import("Value.zig").Function, .function) catch return error.OutOfMemory;
        function.semantics = semantics;
        function.body = body;
        function.function_index = 0;
        function.captures = &.{};
        function.environment = closure_env;
        function.native = null;
        function.bound = .nil;
        vm.owned_functions.append(vm.allocator, function) catch {
            vm.tracker.free(function);
            return error.OutOfMemory;
        };
        return vm.allocator.dupe(Value, &.{.{ .function = function }}) catch return error.OutOfMemory;
    }

    /// A compile failure as the reference words one: the chunk name as
    /// `luaO_chunkid` abbreviates it, the line, the message, and the token
    /// the parser stopped on — `[string "s"]:1: syntax error near <eof>`.
    ///
    /// The message and the token come from the two places the reference builds
    /// them: `luaX_syntaxerror` appends `near` the current token, and
    /// `luaK_semerror` clears that token so no `near` is appended at all,
    /// which is the whole shape of a semantic refusal.
    fn loadSyntaxFailure(vm: *VM, diagnostics: *@import("Diagnostic.zig").Reporter, source: []const u8, chunk_name: []const u8) Error![]Value {
        const Diagnostic = @import("Diagnostic.zig");
        var name_buffer: [61]u8 = undefined;
        const short_name = shortSource(&name_buffer, chunk_name);
        if (diagnostics.errors.items.len == 0) {
            const message = std.fmt.allocPrint(vm.allocator, "{s}: syntax error", .{short_name}) catch return error.OutOfMemory;
            defer vm.allocator.free(message);
            return vm.loadFailure(message);
        }
        const err: Diagnostic.Error = diagnostics.errors.items[0];
        const line = lineAt(source, err.span.start);
        // the line a semantic message names inside itself, which is the goto
        // or the `break` rather than the position the check stopped at
        const subject_line = if (err.name_span) |span| lineAt(source, span.start) else line;

        // what goes between the position and the end: a semantic refusal with
        // nothing after it, or a parser or lexer one with `near` behind it
        const without_near = switch (err.kind) {
            .break_outside_loop, .undefined_label, .duplicate_label, .goto_into_local_scope,
            .assign_to_const, .vararg_outside_function, .unknown_attribute,
            .multiple_close_variables, .too_many_locals, .too_many_upvalues,
            => true,
            else => false,
        };

        var what_buffer: [96]u8 = undefined;
        const what: []const u8 = switch (err.kind) {
            .break_outside_loop => std.fmt.bufPrint(&what_buffer, "break outside loop at line {d}", .{subject_line}) catch "syntax error",
            .undefined_label => std.fmt.bufPrint(&what_buffer, "no visible label '{s}' for <goto> at line {d}", .{ err.name, subject_line }) catch "syntax error",
            .duplicate_label => std.fmt.bufPrint(&what_buffer, "label '{s}' already defined on line {d}", .{
                err.name,
                if (err.opened_at) |at| lineAt(source, at.start) else line,
            }) catch "syntax error",
            .goto_into_local_scope => std.fmt.bufPrint(&what_buffer, "<goto {s}> at line {d} jumps into the scope of local '{s}'", .{ err.name, subject_line, err.opened_name }) catch "syntax error",
            .assign_to_const => std.fmt.bufPrint(&what_buffer, "attempt to assign to const variable '{s}'", .{err.name}) catch "syntax error",
            .vararg_outside_function => "cannot use '...' outside a vararg function",
            .unknown_attribute => std.fmt.bufPrint(&what_buffer, "unknown attribute '{s}'", .{err.name}) catch "syntax error",
            .multiple_close_variables => "multiple to-be-closed variables in local list",
            // `errorlimit`'s wording, with the `where` the reference looks up
            // from the function being compiled
            .too_many_locals => limitWhat(&what_buffer, "local variables", 200, err, source),
            .too_many_upvalues => limitWhat(&what_buffer, "upvalues", 255, err, source),
            // what ran out of input too early, which the span lexeme says
            .unexpected_eof => unfinishedWhat(&what_buffer, source, err.span.start),
            .unexpected_newline => "unfinished string",
            .invalid_char => "unexpected symbol",
            .malformed_number => "malformed number",
            // a stray closer at chunk level goes missing against the end of
            // the file; a refused call is `exprstat`'s `syntax error`
            .unexpected_token => if (err.found != null) closerWhat(&what_buffer, .eof) else "syntax error",
            .invalid_assignment_target => "syntax error",
            // `check_match` words the straggler against the closer the
            // construct waits for: `<eof>` at chunk level, `end`, or `until`
            .statement_after_return => closerWhat(&what_buffer, err.closer orelse .eof),
            .expected_token => expectedWhat(&what_buffer, err.expected),
            else => "syntax error",
        };

        var near_buffer: [64]u8 = undefined;
        const near: []const u8 = near: {
            if (without_near) break :near "";

            // which span the quoted lexeme comes from, and when the token is
            // end of file rather than a span at all
            var lexeme_span = err.span;
            var at_eof = err.found == .eof;
            switch (err.kind) {
                // the input ran out inside a string or a long bracket
                .unexpected_eof => at_eof = true,
                // a refused call or assignment target names the token after
                // the expression, which is recorded rather than covered
                .unexpected_token, .invalid_assignment_target => if (err.stopped) |at| {
                    lexeme_span = at.span;
                    at_eof = at.kind == .eof;
                },
                else => {},
            }
            if (at_eof) break :near "<eof>";
            const lexeme = source[lexeme_span.start..@min(lexeme_span.end, source.len)];
            if (lexeme.len == 0) break :near "<eof>";
            break :near std.fmt.bufPrint(&near_buffer, "'{s}'", .{lexeme}) catch "<eof>";
        };

        const message: []const u8 = if (without_near)
            std.fmt.allocPrint(vm.allocator, "{s}:{d}: {s}", .{ short_name, line, what }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(vm.allocator, "{s}:{d}: {s} near {s}", .{ short_name, line, what, near }) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        return vm.loadFailure(message);
    }

    // `errorlimit`'s `too many %s (limit is %d) in %s`, where the reference's
    // `%s` is `main function` or `function at line N`
    fn limitWhat(buffer: []u8, what: []const u8, limit: u32, err: @import("Diagnostic.zig").Error, source: []const u8) []const u8 {
        if (err.opened_at) |body| return std.fmt.bufPrint(buffer, "too many {s} (limit is {d}) in {s} at line {d}", .{
            what,
            limit,
            err.opened_name,
            lineAt(source, body.start),
        }) catch "syntax error";
        return std.fmt.bufPrint(buffer, "too many {s} (limit is {d}) in {s}", .{ what, limit, err.opened_name }) catch "syntax error";
    }

    // what ran out of input too early, which the span lexeme says: a quote is
    // a short string; `[[` is a long string and `--[[` the comment form, since
    // the long-bracket scan starts at the `[` either way
    fn unfinishedWhat(buffer: []u8, source: []const u8, start: u32) []const u8 {
        const at: usize = start;
        if (at >= source.len) return "syntax error";
        return switch (source[at]) {
            '"', '\'' => "unfinished string",
            '[' => std.fmt.bufPrint(buffer, "unfinished long {s} (starting at line {d})", .{
                if (at >= 2 and std.mem.eql(u8, source[at - 2 .. at], "--")) "comment" else "string",
                lineAt(source, start),
            }) catch "syntax error",
            else => "syntax error",
        };
    }

    // a closer named as itself, except the tokens whose text stands for a
    // whole class, which `luaX_token2str` leaves bare: `<eof>`, `<name>`,
    // `<integer>`, `<number>` and `<string>`
    fn closerWhat(buffer: []u8, kind: @import("Token.zig").Kind) []const u8 {
        const class: ?[]const u8 = switch (kind) {
            .eof => "<eof>",
            .ident => "<name>",
            .decimal => "<integer>",
            .float => "<number>",
            .str, .long_str => "<string>",
            else => null,
        };
        if (class) |text| return std.fmt.bufPrint(buffer, "{s} expected", .{text}) catch "syntax error";
        const text = @import("Token.zig").luaText(kind) orelse "token";
        return std.fmt.bufPrint(buffer, "'{s}' expected", .{text}) catch "syntax error";
    }

    // `error_expected`'s `'{X}' expected`, with the classes that stand for a
    // run of tokens worded as the reference words them
    fn expectedWhat(buffer: []u8, expected: ?@import("Diagnostic.zig").Error.Expected) []const u8 {
        if (expected) |wanted| switch (wanted) {
            .token => |kind| return closerWhat(buffer, kind),
            .expression, .statement => return "unexpected symbol",
            .arguments => return "function arguments expected",
        };
        return "syntax error";
    }

    fn loadFailure(vm: *VM, message: []const u8) Error![]Value {
        const text = vm.interner.intern(message) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{ .nil, .{ .string = text } }) catch return error.OutOfMemory;
    }

    fn loadFailureIn(vm: *VM, chunk_name: []const u8) Error![]Value {
        const message = std.fmt.allocPrint(vm.allocator, "{s}: syntax error", .{chunk_name}) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        return vm.loadFailure(message);
    }

    fn baseLoadFile(vm: *VM, args: []const Value) Error![]Value {
        if (args.len > 3 or (args.len > 0 and args[0] != .string and args[0] != .nil)) return vm.loadFailure("bad argument #1 to 'loadfile' (string expected)");
        const io = vm.io orelse return vm.loadFailure("file loading is unavailable");
        const path: ?[]const u8 = if (args.len > 0 and args[0] == .string) args[0].string.slice() else null;
        const source = if (path) |filename| std.Io.Dir.cwd().readFileAlloc(io, filename, vm.allocator, .unlimited) catch |err| {
            const message = std.fmt.allocPrint(vm.allocator, "cannot open {s}: {s}", .{ filename, fileErrorMessage(@errorName(err)) }) catch return error.OutOfMemory;
            defer vm.allocator.free(message);
            return vm.loadFailure(message);
        } else blk: {
            var buffer: [4096]u8 = undefined;
            var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
            break :blk reader.interface.allocRemaining(vm.allocator, .unlimited) catch return vm.loadFailure("cannot read stdin");
        };
        defer vm.allocator.free(source);
        // `luaL_loadfilex` names the chunk after the file behind an `@`,
        // which is what makes its positions read `file:line: ` rather than
        // `[string "file"]:line: `
        const name = if (path) |filename| blk: {
            const with_intro = std.fmt.allocPrint(vm.allocator, "@{s}", .{filename}) catch return error.OutOfMemory;
            defer vm.allocator.free(with_intro);
            break :blk vm.interner.intern(with_intro) catch return error.OutOfMemory;
        } else vm.interner.intern("=stdin") catch return error.OutOfMemory;
        const mode: Value = if (args.len > 1) args[1] else .nil;
        const environment: Value = if (args.len > 2) args[2] else .nil;
        return vm.baseLoad(&.{ .{ .string = vm.interner.intern(source) catch return error.OutOfMemory }, .{ .string = name }, mode, environment });
    }

    fn baseDoFile(vm: *VM, args: []const Value) Error![]Value {
        const loaded = try vm.baseLoadFile(args);
        defer vm.allocator.free(loaded);
        if (loaded.len == 0 or loaded[0] == .nil) {
            vm.exec.thrown_error = if (loaded.len > 1) loaded[1] else .{ .string = vm.interner.intern("cannot load file") catch return error.OutOfMemory };
            return error.RuntimeError;
        }
        return vm.invokeCallableValues(loaded[0], &.{});
    }

    fn baseToString(vm: *VM, args: []const Value) Error![]Value {
        try vm.checkAny(args, 1, "tostring", "tostring");
        const value = args[0];
        if (value == .string) return vm.allocator.dupe(Value, &.{value}) catch return error.OutOfMemory;
        if (value == .table) {
            const method = try vm.metamethod(value.table, "__tostring");
            if (method != .nil) {
                const returned = try vm.invokeCallableValues(method, &.{value});
                defer vm.allocator.free(returned);
                // `lua_isstring` lets a number through, so only a value with
                // no string reading at all is refused
                const outcome: Value = if (returned.len == 0) .nil else returned[0];
                return switch (outcome) {
                    .string => |string| vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory,
                    .number => |number| vm.allocator.dupe(Value, &.{.{ .string = vm.interner.intern(vm.scratchNumber(number)) catch return error.OutOfMemory }}) catch return error.OutOfMemory,
                    else => vm.raise("'__tostring' must return a string", .{}),
                };
            }
        }
        var buffer: [64]u8 = undefined;
        const bytes = try vm.defaultBytes(value, &buffer);
        return vm.allocator.dupe(Value, &.{.{ .string = vm.interner.intern(bytes) catch return error.OutOfMemory }}) catch return error.OutOfMemory;
    }

    /// What `tostring` falls back to with no `__tostring` in the way. Objects
    /// print as `<type>: 0x<address>`, the same shape `lua_pushfstring` gives
    /// with `%s: %p`; the address itself differs run to run, so anything
    /// comparing output has to scrub it either way.
    fn defaultBytes(vm: *VM, value: Value, buffer: *[64]u8) Error![]const u8 {
        return switch (value) {
            .nil => "nil",
            .boolean => |boolean| if (boolean) "true" else "false",
            .number => |number| Number.toBytes(number, buffer) catch return error.RuntimeError,
            .string => |string| string.slice(),
            // `luaL_tolstring` names an object by its metatable's `__name` when
            // there is one, so `tostring` on a table that declares one reads
            // `Zed: 0x...` rather than `table: 0x...`
            .table => |table| blk: {
                const named = try vm.metamethod(table, "__name");
                const kind = if (named == .string) named.string.slice() else "table";
                break :blk std.fmt.bufPrint(buffer, "{s}: 0x{x}", .{ kind, @intFromPtr(table) }) catch return error.RuntimeError;
            },
            .function => |function| std.fmt.bufPrint(buffer, "function: 0x{x}", .{@intFromPtr(function)}) catch return error.RuntimeError,
            // a native function has no pointer of its own, so its ordinal
            // stands in for the C function address `%p` would print
            .native_function => |native| std.fmt.bufPrint(buffer, "function: 0x{d}", .{@intFromEnum(native) + 1}) catch return error.RuntimeError,
            .thread => |thread| std.fmt.bufPrint(buffer, "thread: 0x{x}", .{@intFromPtr(thread)}) catch return error.RuntimeError,
        };
    }

    /// `luaB_tonumber`. The two-argument form wants a string and refuses a
    /// number outright, and its base is checked before the string is.
    fn baseToNumber(vm: *VM, args: []const Value) Error![]Value {
        const short = "tonumber";
        const long = "tonumber";
        const result: Value = if (args.len < 2 or args[1] == .nil) blk: {
            if (args.len == 0) return vm.raiseArgument(1, short, long, "value expected", .{});
            if (args[0] == .number) break :blk args[0];
            if (args[0] == .string) {
                const bytes = std.mem.trim(u8, args[0].string.slice(), " \t\r\n\x0b\x0c");
                break :blk if (Number.parse(bytes)) |number| .{ .number = number } else .nil;
            }
            // something that cannot convert still has to have been passed
            try vm.checkAny(args, 1, short, long);
            break :blk .nil;
        } else blk: {
            const base = try vm.checkInteger(args, 2, short, long);
            if (args.len < 1 or args[0] != .string) return vm.typeError(1, short, long, "string", if (args.len >= 1) args[0] else null);
            if (base < 2 or base > 36) return vm.raiseArgument(2, short, long, "base out of range", .{});
            const bytes = std.mem.trim(u8, args[0].string.slice(), " \t\r\n\x0b\x0c");
            const integer = std.fmt.parseInt(i64, bytes, @intCast(base)) catch break :blk Value.nil;
            break :blk Value{ .number = Number.Number.fromInt(integer) };
        };
        return vm.allocator.dupe(Value, &.{result}) catch return error.OutOfMemory;
    }

    /// `luaB_assert`: a true first argument hands everything back, and a
    /// failing one has to have been given at all before it can be blamed.
    fn baseAssert(vm: *VM, args: []const Value) Error![]Value {
        if (args.len > 0 and args[0].truthy()) return vm.allocator.dupe(Value, args) catch return error.OutOfMemory;
        try vm.checkAny(args, 1, "assert", "assert");
        // the message follows `error(msg, 1)`: a string gains the position of
        // the call it came through, anything else is thrown whole
        const message: Value = if (args.len > 1) args[1] else .{ .string = vm.interner.intern("assertion failed!") catch return error.OutOfMemory };
        if (message == .string) return vm.raise("{s}", .{message.string.slice()});
        vm.exec.thrown_error = message;
        return error.RuntimeError;
    }

    /// Raises a runtime error the way `luaG_runerror` does: the message gains
    /// the current `chunk:line: ` prefix and becomes the value `pcall` hands
    /// back. `raisePlain` is for the API-style errors (`bad argument #1 ...`)
    /// that the reference reports without a position.
    fn raise(vm: *VM, comptime fmt: []const u8, args: anytype) Error {
        var detail_buffer: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buffer, fmt, args) catch fmt;
        var position_buffer: [192]u8 = undefined;
        const raised_by_native = vm.exec.error_frames.items.len != 0 and vm.exec.error_frames.items[vm.exec.error_frames.items.len - 1].program == null;
        const position = if (raised_by_native)
            vm.nativeRaisePosition(&position_buffer) catch null
        else
            vm.currentLuaPosition(&position_buffer) catch null;
        const message = if (position) |p|
            std.fmt.allocPrint(vm.allocator, "{s}{s}", .{ p, detail }) catch return error.OutOfMemory
        else
            vm.allocator.dupe(u8, detail) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        vm.exec.thrown_error = .{ .string = vm.interner.intern(message) catch return error.OutOfMemory };
        return error.RuntimeError;
    }

    /// The arithmetic failure wording follows the string metatable: when a
    /// string is involved the reference names both operands, otherwise it
    /// blames whichever operand is not a number.
    fn raiseArithmetic(vm: *VM, op: Ast.BinaryOperator, left: Value, right: Value, descriptions: OperatorDescriptions) Error {
        const operation: []const u8 = switch (op) {
            .add => "add",
            .subtract => "sub",
            .multiply => "mul",
            .divide => "div",
            .floor_divide => "idiv",
            .modulo => "mod",
            .power => "pow",
            else => return error.RuntimeError,
        };
        if (left == .string or right == .string)
            return vm.raise("attempt to {s} a '{s}' with a '{s}'", .{ operation, left.typeName(), right.typeName() });
        const left_to_blame = left != .number;
        const blame = if (left_to_blame) left else right;
        const description = if (left_to_blame) descriptions.left else descriptions.right;
        return vm.raise("attempt to perform arithmetic on a {s} value{s}", .{ blame.typeName(), description });
    }

    fn raisePlain(vm: *VM, comptime fmt: []const u8, args: anytype) Error {
        var detail_buffer: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buffer, fmt, args) catch fmt;
        vm.exec.thrown_error = .{ .string = vm.interner.intern(detail) catch return error.OutOfMemory };
        return error.RuntimeError;
    }

    /// `luaL_argerror`. The name comes from the calling instruction when there
    /// is one: the short name for a syntactic call (`string.sub(...)` reads
    /// `sub`) and the qualified one when the call went through a value, which
    /// is when the reference's `lua_getinfo` comes back empty and
    /// `pushglobalfuncname` looks the function up in the loaded libraries. A
    /// method call counts its receiver as argument zero, so the index moves
    /// down one and an error about the receiver itself reads
    /// `calling 'sub' on bad self (...)`.
    fn argError(vm: *VM, argument: usize, short: []const u8, long: []const u8, detail: []const u8) Error {
        var index = argument;
        var bad_self: ?[]const u8 = null;
        const frames = vm.exec.error_frames.items;
        if (frames.len != 0) {
            const frame = frames[frames.len - 1];
            if (frame.method) |method| {
                index -= 1;
                if (index == 0) bad_self = method;
            }
        }
        const name = if (frames.len != 0 and frames[frames.len - 1].from_call_site) short else long;
        const shape = if (bad_self) |method|
            std.fmt.allocPrint(vm.allocator, "calling '{s}' on bad self ({s})", .{ method, detail }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(vm.allocator, "bad argument #{d} to '{s}' ({s})", .{ index, name, detail }) catch return error.OutOfMemory;
        defer vm.allocator.free(shape);
        var position_buffer: [192]u8 = undefined;
        const position = vm.nativeRaisePosition(&position_buffer) catch null;
        const message = if (position) |p|
            std.fmt.allocPrint(vm.allocator, "{s}{s}", .{ p, shape }) catch return error.OutOfMemory
        else
            vm.allocator.dupe(u8, shape) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        vm.exec.thrown_error = .{ .string = vm.interner.intern(message) catch return error.OutOfMemory };
        return error.RuntimeError;
    }

    /// `luaL_argerror` with the detail still a format string.
    fn raiseArgument(vm: *VM, argument: usize, short: []const u8, long: []const u8, comptime fmt: []const u8, args: anytype) Error {
        var detail_buffer: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buffer, fmt, args) catch fmt;
        return vm.argError(argument, short, long, detail);
    }

    /// `luaL_typeerror`: `"{expected} expected, got {actual}"`. An argument that
    /// was never passed reads `no value`, and an object whose metatable names a
    /// type through `__name` is reported under that name, which is how a named
    /// table or a userdata describes itself.
    fn typeError(vm: *VM, argument: usize, short: []const u8, long: []const u8, expected: []const u8, got: ?Value) Error {
        const actual = if (got) |value| try vm.messageTypeName(value) else "no value";
        return vm.raiseArgument(argument, short, long, "{s} expected, got {s}", .{ expected, actual });
    }

    fn messageTypeName(vm: *VM, value: Value) Error![]const u8 {
        if (value == .table) {
            const name = try vm.metamethod(value.table, "__name");
            if (name == .string) return name.string.slice();
        }
        return value.typeName();
    }

    /// `luaL_checkany`: only an argument that was never passed is a failure.
    fn checkAny(vm: *VM, args: []const Value, argument: usize, short: []const u8, long: []const u8) Error!void {
        if (argument > args.len) return vm.raiseArgument(argument, short, long, "value expected", .{});
    }

    /// Where a number that has to be read as a string is written. Rotating, so
    /// one call holding several of them at once does not clobber the earlier
    /// one, and never freed, since the bytes outlive only the call that is
    /// reading them.
    fn scratchNumber(vm: *VM, number: Number.Number) []const u8 {
        const slot = &vm.text_scratch[vm.text_scratch_slot];
        vm.text_scratch_slot +%= 1;
        return Number.toBytes(number, slot) catch "0";
    }

    /// `luaL_checklstring`: a string, or a number written out the way
    /// `luaV_tostring` writes it.
    fn checkString(vm: *VM, args: []const Value, argument: usize, short: []const u8, long: []const u8) Error![]const u8 {
        const value = if (argument <= args.len) args[argument - 1] else return vm.typeError(argument, short, long, "string", null);
        return switch (value) {
            .string => |string| string.slice(),
            .number => |number| vm.scratchNumber(number),
            else => vm.typeError(argument, short, long, "string", value),
        };
    }

    /// `luaL_optlstring`.
    fn optString(vm: *VM, args: []const Value, argument: usize, comptime default: []const u8, short: []const u8, long: []const u8) Error![]const u8 {
        if (argument > args.len or args[argument - 1] == .nil) return default;
        return vm.checkString(args, argument, short, long);
    }

    /// `luaL_checknumber`, which always hands back a double: a string arrives as
    /// the float it names, and `lua_isinteger` on the original argument is what
    /// lets a function keep an integer path for an integer written as one.
    fn checkNumber(vm: *VM, args: []const Value, argument: usize, short: []const u8, long: []const u8) Error!Number.Number {
        const value = if (argument <= args.len) args[argument - 1] else return vm.typeError(argument, short, long, "number", null);
        return switch (value) {
            .number => |number| number,
            .string => |string| blk: {
                const parsed = Number.parse(string.slice()) orelse return vm.typeError(argument, short, long, "number", value);
                break :blk switch (parsed) {
                    .int => |integer| Number.Number.fromFloat(@floatFromInt(integer)),
                    .float => |float| Number.Number.fromFloat(float),
                };
            },
            else => vm.typeError(argument, short, long, "number", value),
        };
    }

    /// `luaL_optnumber`.
    fn optNumber(vm: *VM, args: []const Value, argument: usize, default: Number.Number, short: []const u8, long: []const u8) Error!Number.Number {
        if (argument > args.len or args[argument - 1] == .nil) return default;
        return vm.checkNumber(args, argument, short, long);
    }

    /// `luaL_checkinteger`, which reads a numeric string too and refuses a
    /// number that has no integer representation by saying so.
    fn checkInteger(vm: *VM, args: []const Value, argument: usize, short: []const u8, long: []const u8) Error!i64 {
        const value = if (argument <= args.len) args[argument - 1] else return vm.typeError(argument, short, long, "number", null);
        return switch (value) {
            .number => |number| number.toIntExact() orelse
                vm.raiseArgument(argument, short, long, "number has no integer representation", .{}),
            .string => |string| blk: {
                const parsed = Number.parse(string.slice()) orelse return vm.typeError(argument, short, long, "number", value);
                break :blk switch (parsed) {
                    .int => |integer| integer,
                    .float => |float| blk2: {
                        const truncated = @trunc(float);
                        if (truncated != float or std.math.isNan(float) or std.math.isInf(float))
                            return vm.raiseArgument(argument, short, long, "number has no integer representation", .{});
                        break :blk2 @as(i64, @intFromFloat(truncated));
                    },
                };
            },
            else => vm.typeError(argument, short, long, "number", value),
        };
    }

    /// `luaL_optinteger`.
    fn optInteger(vm: *VM, args: []const Value, argument: usize, default: i64, short: []const u8, long: []const u8) Error!i64 {
        if (argument > args.len or args[argument - 1] == .nil) return default;
        return vm.checkInteger(args, argument, short, long);
    }

    fn checkTable(vm: *VM, args: []const Value, argument: usize, short: []const u8, long: []const u8) Error!*Table {
        const value = if (argument <= args.len) args[argument - 1] else return vm.typeError(argument, short, long, "table", null);
        return switch (value) {
            .table => |table| table,
            else => vm.typeError(argument, short, long, "table", value),
        };
    }

    fn checkFunction(vm: *VM, args: []const Value, argument: usize, short: []const u8, long: []const u8) Error!Value {
        const value = if (argument <= args.len) args[argument - 1] else return vm.typeError(argument, short, long, "function", null);
        return switch (value) {
            .function, .native_function => value,
            else => vm.typeError(argument, short, long, "function", value),
        };
    }

    fn baseError(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) {
            vm.exec.thrown_error = .nil;
            return error.RuntimeError;
        }
        var message = args[0];
        const level: i64 = if (args.len > 1) try intArgument(args[1]) else 1;
        // `luaL_error` prefixes a string message with where the function that
        // called error was, which is `chunk:line: `. Anything else, a
        // non-string or level 0, is passed through as it is.
        if (message == .string and level > 0) {
            var buffer: [192]u8 = undefined;
            if (try vm.errorPosition(level, &buffer)) |position| {
                const bytes = std.fmt.allocPrint(vm.allocator, "{s}{s}", .{ position, message.string.slice() }) catch return error.OutOfMemory;
                defer vm.allocator.free(bytes);
                message = .{ .string = vm.interner.intern(bytes) catch return error.OutOfMemory };
            }
        }
        vm.exec.thrown_error = message;
        return error.RuntimeError;
    }

    /// `chunk:line: ` for the function `level` frames up, or null where the
    /// reference would push the empty string. Levels count Lua functions only;
    /// a native caller has no position to give.
    fn errorPosition(vm: *VM, level: i64, buffer: *[192]u8) Error!?[]const u8 {
        if (level < 1) return null;
        const depth = std.math.cast(usize, level) orelse return null;
        const count = vm.exec.error_frames.items.len;
        if (count == 0 or depth >= count) return null;
        // level counts activations above the one raising the error, and the
        // activation above frame `index` is what holds its call site
        const index = count - 1 - depth;
        const frame = vm.exec.error_frames.items[index];
        const program = frame.program orelse return null;
        const offset = vm.exec.error_frames.items[index + 1].call_offset;
        if (offset == null or program.source.len == 0) return null;
        const line = lineAt(program.source, offset.?);
        var name_buffer: [61]u8 = undefined;
        const name = shortSource(&name_buffer, program.chunk_name);
        return std.fmt.bufPrint(buffer, "{s}:{d}: ", .{ name, line }) catch return error.RuntimeError;
    }

    /// `chunk:line: ` for the Lua function whose evaluation is raising:
    /// `luaG_runerror` points at the instruction being executed, which is the
    /// expression offset the walker last recorded.
    /// `luaL_where(L, 1)` for a native that raises: the position of the Lua
    /// function that called it, and nothing when that caller is another
    /// native, the way a C caller leaves `luaL_where` empty.
    fn nativeRaisePosition(vm: *VM, buffer: *[192]u8) Error!?[]const u8 {
        const frames = vm.exec.error_frames.items;
        if (frames.len < 2) return null;
        const program = frames[frames.len - 2].program orelse return null;
        const offset = frames[frames.len - 1].call_offset orelse return null;
        if (program.source.len == 0) return null;
        const line = lineAt(program.source, offset);
        var name_buffer: [61]u8 = undefined;
        const name = shortSource(&name_buffer, program.chunk_name);
        return std.fmt.bufPrint(buffer, "{s}:{d}: ", .{ name, line }) catch return error.RuntimeError;
    }

    fn currentLuaPosition(vm: *VM, buffer: *[192]u8) Error!?[]const u8 {
        var index: usize = vm.exec.error_frames.items.len;
        while (index > 0) {
            index -= 1;
            const program = vm.exec.error_frames.items[index].program orelse continue;
            if (vm.exec.error_offset == null or program.source.len == 0) return null;
            const line = lineAt(program.source, vm.exec.error_offset.?);
            var name_buffer: [61]u8 = undefined;
            const name = shortSource(&name_buffer, program.chunk_name);
            return std.fmt.bufPrint(buffer, "{s}:{d}: ", .{ name, line }) catch return error.RuntimeError;
        }
        return null;
    }

    /// `luaB_select`: a first argument starting with `'#'` counts the rest,
    /// otherwise the index is clipped to `n` the way `luaB_select` clips it,
    /// and only an index below one is out of range.
    fn baseSelect(vm: *VM, args: []const Value) Error![]Value {
        const short = "select";
        const long = "select";
        if (args.len > 0 and args[0] == .string and args[0].string.slice()[0] == '#') {
            const count = std.math.cast(i64, args.len - 1) orelse return error.RuntimeError;
            return vm.allocator.dupe(Value, &.{.{ .number = Number.Number.fromInt(count) }}) catch return error.OutOfMemory;
        }
        const n = std.math.cast(i64, args.len) orelse return error.RuntimeError;
        const selector = try vm.checkInteger(args, 1, short, long);
        const chosen = if (selector < 0)
            n + selector
        else if (selector > n)
            n
        else
            selector;
        if (chosen < 1) return vm.raiseArgument(1, short, long, "index out of range", .{});
        const start = std.math.cast(usize, chosen) orelse return error.RuntimeError;
        return vm.allocator.dupe(Value, args[start..]) catch return error.OutOfMemory;
    }

    fn baseRawequal(vm: *VM, args: []const Value) Error![]Value {
        const short = "rawequal";
        const long = "rawequal";
        try vm.checkAny(args, 1, short, long);
        try vm.checkAny(args, 2, short, long);
        return vm.allocator.dupe(Value, &.{.{ .boolean = args[0].equal(args[1]) }}) catch return error.OutOfMemory;
    }

    fn baseRawGet(vm: *VM, args: []const Value) Error![]Value {
        const table = try vm.checkTable(args, 1, "rawget", "rawget");
        try vm.checkAny(args, 2, "rawget", "rawget");
        return vm.allocator.dupe(Value, &.{table.get(if (args.len > 1) args[1] else .nil)}) catch return error.OutOfMemory;
    }

    fn baseRawSet(vm: *VM, args: []const Value) Error![]Value {
        const table = try vm.checkTable(args, 1, "rawset", "rawset");
        try vm.checkAny(args, 2, "rawset", "rawset");
        try vm.checkAny(args, 3, "rawset", "rawset");
        try vm.checkStorableKey(if (args.len > 1) args[1] else .nil, true);
        table.set(if (args.len > 1) args[1] else .nil, if (args.len > 2) args[2] else .nil) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{args[0]}) catch return error.OutOfMemory;
    }

    fn baseRawLen(vm: *VM, args: []const Value) Error![]Value {
        const short = "rawlen";
        const long = "rawlen";
        if (args.len == 0) return vm.typeError(1, short, long, "table or string", null);
        const length: i64 = switch (args[0]) {
            .string => |string| std.math.cast(i64, string.slice().len) orelse return error.RuntimeError,
            .table => |table| table.len(),
            else => return vm.typeError(1, short, long, "table or string", args[0]),
        };
        return vm.allocator.dupe(Value, &.{.{ .number = Number.Number.fromInt(length) }}) catch return error.OutOfMemory;
    }

    fn baseSetMetatable(vm: *VM, args: []const Value) Error![]Value {
        const short = "setmetatable";
        const long = "setmetatable";
        if (args.len == 0) return vm.typeError(1, short, long, "table", null);
        if (args[0] != .table) return vm.typeError(1, short, long, "table", args[0]);
        // an omitted second argument is `no value`, not the `nil` that clears
        if (args.len < 2) return vm.typeError(2, short, long, "nil or table", null);
        const replacement = args[1];
        if (replacement != .nil and replacement != .table)
            return vm.typeError(2, short, long, "nil or table", replacement);
        const table = args[0].table;
        if (table.metatable) |metatable| if (metatable.get(.{ .string = vm.interner.intern("__metatable") catch return error.OutOfMemory }) != .nil)
            return vm.raise("cannot change a protected metatable", .{});
        table.metatable = switch (replacement) {
            .table => |inner| inner,
            else => null,
        };
        return vm.allocator.dupe(Value, &.{args[0]}) catch return error.OutOfMemory;
    }

    fn baseGetMetatable(vm: *VM, args: []const Value) Error![]Value {
        try vm.checkAny(args, 1, "getmetatable", "getmetatable");
        const metatable = switch (args[0]) {
            .table => |table| table.metatable orelse return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory,
            .string => vm.string_metatable orelse return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory,
            else => return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory,
        };
        const protected = metatable.get(.{ .string = vm.interner.intern("__metatable") catch return error.OutOfMemory });
        const result: Value = if (protected != .nil) protected else .{ .table = metatable };
        return vm.allocator.dupe(Value, &.{result}) catch return error.OutOfMemory;
    }

    fn installTableLibrary(vm: *VM) Error!void {
        const library = try vm.newTable();
        try vm.putNative(library, "insert", .table_insert);
        try vm.putNative(library, "remove", .table_remove);
        try vm.putNative(library, "concat", .table_concat);
        try vm.putNative(library, "unpack", .table_unpack);
        try vm.putNative(library, "pack", .table_pack);
        try vm.putNative(library, "move", .table_move);
        try vm.putNative(library, "sort", .table_sort);
        const key = Value{ .string = vm.interner.intern("table") catch return error.OutOfMemory };
        vm.globals.set(key, .{ .table = library }) catch return error.OutOfMemory;
    }

    fn putNative(vm: *VM, table: *Table, name: []const u8, function: ValueModule.NativeFunction) Error!void {
        const key = Value{ .string = vm.interner.intern(name) catch return error.OutOfMemory };
        table.set(key, .{ .native_function = function }) catch return error.OutOfMemory;
    }

    fn installStringLibrary(vm: *VM) Error!void {
        const library = try vm.newTable();
        try vm.putNative(library, "len", .string_len);
        try vm.putNative(library, "sub", .string_sub);
        try vm.putNative(library, "rep", .string_rep);
        try vm.putNative(library, "reverse", .string_reverse);
        try vm.putNative(library, "upper", .string_upper);
        try vm.putNative(library, "lower", .string_lower);
        try vm.putNative(library, "byte", .string_byte);
        try vm.putNative(library, "char", .string_char);
        try vm.putNative(library, "find", .string_find);
        try vm.putNative(library, "match", .string_match);
        try vm.putNative(library, "gmatch", .string_gmatch);
        try vm.putNative(library, "gsub", .string_gsub);
        try vm.putNative(library, "format", .string_format);
        try vm.putNative(library, "pack", .string_pack);
        try vm.putNative(library, "packsize", .string_packsize);
        try vm.putNative(library, "unpack", .string_unpack);
        try vm.putNative(library, "dump", .string_dump);
        const metatable = try vm.newTable();
        metatable.set(.{ .string = vm.interner.intern("__index") catch return error.OutOfMemory }, .{ .table = library }) catch return error.OutOfMemory;
        vm.string_metatable = metatable;
        const key = Value{ .string = vm.interner.intern("string") catch return error.OutOfMemory };
        vm.globals.set(key, .{ .table = library }) catch return error.OutOfMemory;
    }

    fn installUtf8Library(vm: *VM) Error!void {
        const library = try vm.newTable();
        try vm.putNative(library, "char", .utf8_char);
        try vm.putNative(library, "len", .utf8_len);
        try vm.putNative(library, "codepoint", .utf8_codepoint);
        try vm.putNative(library, "offset", .utf8_offset);
        try vm.putNative(library, "codes", .utf8_codes);
        const char_pattern = "[\x00-\x7f\xc2-\xfd][\x80-\xbf]*";
        library.set(.{ .string = vm.interner.intern("charpattern") catch return error.OutOfMemory }, .{ .string = vm.interner.intern(char_pattern) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        vm.globals.set(.{ .string = vm.interner.intern("utf8") catch return error.OutOfMemory }, .{ .table = library }) catch return error.OutOfMemory;
    }

    fn installMathLibrary(vm: *VM) Error!void {
        const library = try vm.newTable();
        try vm.putNative(library, "abs", .math_abs);
        try vm.putNative(library, "floor", .math_floor);
        try vm.putNative(library, "ceil", .math_ceil);
        try vm.putNative(library, "sqrt", .math_sqrt);
        try vm.putNative(library, "fmod", .math_fmod);
        try vm.putNative(library, "max", .math_max);
        try vm.putNative(library, "min", .math_min);
        try vm.putNative(library, "tointeger", .math_tointeger);
        try vm.putNative(library, "type", .math_type);
        try vm.putNative(library, "sin", .math_sin);
        try vm.putNative(library, "cos", .math_cos);
        try vm.putNative(library, "tan", .math_tan);
        try vm.putNative(library, "asin", .math_asin);
        try vm.putNative(library, "acos", .math_acos);
        try vm.putNative(library, "atan", .math_atan);
        try vm.putNative(library, "exp", .math_exp);
        try vm.putNative(library, "log", .math_log);
        try vm.putNative(library, "deg", .math_deg);
        try vm.putNative(library, "rad", .math_rad);
        try vm.putNative(library, "modf", .math_modf);
        try vm.putNative(library, "ult", .math_ult);
        try vm.putNative(library, "random", .math_random);
        try vm.putNative(library, "randomseed", .math_randomseed);
        try vm.putNumber(library, "pi", .{ .float = std.math.pi });
        try vm.putNumber(library, "huge", .{ .float = std.math.inf(f64) });
        try vm.putNumber(library, "maxinteger", .{ .int = std.math.maxInt(i64) });
        try vm.putNumber(library, "mininteger", .{ .int = std.math.minInt(i64) });
        const key = Value{ .string = vm.interner.intern("math") catch return error.OutOfMemory };
        vm.globals.set(key, .{ .table = library }) catch return error.OutOfMemory;
    }

    fn installOsLibrary(vm: *VM) Error!void {
        const library = try vm.newTable();
        try vm.putNative(library, "clock", .os_clock);
        try vm.putNative(library, "time", .os_time);
        try vm.putNative(library, "difftime", .os_difftime);
        try vm.putNative(library, "getenv", .os_getenv);
        try vm.putNative(library, "date", .os_date);
        try vm.putNative(library, "execute", .os_execute);
        try vm.putNative(library, "remove", .os_remove);
        try vm.putNative(library, "rename", .os_rename);
        try vm.putNative(library, "setlocale", .os_setlocale);
        try vm.putNative(library, "exit", .os_exit);
        try vm.putNative(library, "tmpname", .os_tmpname);
        vm.globals.set(.{ .string = vm.interner.intern("os") catch return error.OutOfMemory }, .{ .table = library }) catch return error.OutOfMemory;
    }

    fn installIoLibrary(vm: *VM) Error!void {
        const metatable = try vm.newTable();
        const methods = try vm.newTable();
        try vm.putNative(methods, "read", .file_read);
        try vm.putNative(methods, "write", .file_write);
        try vm.putNative(methods, "flush", .file_flush);
        try vm.putNative(methods, "close", .file_close);
        try vm.putNative(methods, "seek", .file_seek);
        try vm.putNative(methods, "lines", .file_lines);
        try vm.putNative(methods, "setvbuf", .file_setvbuf);
        metatable.set(.{ .string = vm.interner.intern("__index") catch return error.OutOfMemory }, .{ .table = methods }) catch return error.OutOfMemory;
        try vm.putNative(metatable, "__close", .file_close);
        try vm.putNative(metatable, "__gc", .file_close);
        try vm.putNative(metatable, "__tostring", .file_tostring);
        metatable.set(.{ .string = vm.interner.intern("__name") catch return error.OutOfMemory }, .{ .string = vm.interner.intern("FILE*") catch return error.OutOfMemory }) catch return error.OutOfMemory;
        metatable.set(.{ .string = vm.interner.intern("__metatable") catch return error.OutOfMemory }, .{ .boolean = true }) catch return error.OutOfMemory;
        vm.file_metatable = metatable;
        const library = try vm.newTable();
        try vm.putNative(library, "open", .io_open);
        try vm.putNative(library, "write", .io_write);
        try vm.putNative(library, "flush", .io_flush);
        try vm.putNative(library, "type", .io_type);
        try vm.putNative(library, "close", .io_close);
        try vm.putNative(library, "lines", .io_lines);
        try vm.putNative(library, "input", .io_input);
        try vm.putNative(library, "output", .io_output);
        try vm.putNative(library, "read", .io_read);
        try vm.putNative(library, "tmpfile", .io_tmpfile);
        // `io.stdin` and friends are handed out by name, which is the only
        // thing the library's own `__index` is for
        const io_metatable = try vm.newTable();
        try vm.putNative(io_metatable, "__index", .io_index);
        library.metatable = io_metatable;
        vm.globals.set(.{ .string = vm.interner.intern("io") catch return error.OutOfMemory }, .{ .table = library }) catch return error.OutOfMemory;
    }

    fn putNumber(vm: *VM, table: *Table, name: []const u8, number: Number.Number) Error!void {
        const key = Value{ .string = vm.interner.intern(name) catch return error.OutOfMemory };
        table.set(key, .{ .number = number }) catch return error.OutOfMemory;
    }

    fn writeValue(vm: *VM, writer: *std.Io.Writer, value: Value) Error!void {
        if (value == .table) {
            const method = try vm.metamethod(value.table, "__tostring");
            if (method != .nil) {
                const values = try vm.invokeCallableValues(method, &.{value});
                defer vm.allocator.free(values);
                if (values.len == 0 or values[0] != .string) return error.RuntimeError;
                writer.writeAll(values[0].string.slice()) catch return error.RuntimeError;
                return;
            }
        }
        var buffer: [64]u8 = undefined;
        writer.writeAll(try vm.defaultBytes(value, &buffer)) catch return error.RuntimeError;
    }

    fn numberBytes(vm: *VM, number: Number.Number) []const u8 {
        return Number.toBytes(number, &vm.number_buffer) catch "?";
    }

    /// `g_write`'s format for a number, which leaves the `.0` off a whole float
    /// where `tostring` keeps it
    fn writeNumberBytes(vm: *VM, number: Number.Number) []const u8 {
        return Number.toWriteBytes(number, &vm.number_buffer) catch "?";
    }

    fn newTable(vm: *VM) Error!*Table {
        const table = Table.create(vm.allocator, vm.tracker) catch return error.OutOfMemory;
        vm.owned_tables.append(vm.allocator, table) catch {
            table.deinit(vm.tracker);
            return error.OutOfMemory;
        };
        return table;
    }

    fn evalTable(vm: *VM, expr: Ast.Expression) Error!*Table {
        return switch (try vm.eval(expr)) {
            .table => |table| table,
            else => error.RuntimeError,
        };
    }

    fn metamethod(vm: *VM, table: *Table, name: []const u8) Error!Value {
        const meta = table.metatable orelse return .nil;
        return meta.get(.{ .string = vm.interner.intern(name) catch return error.OutOfMemory });
    }

    fn valueMetamethod(vm: *VM, value: Value, name: []const u8) Error!Value {
        const meta = switch (value) {
            .table => |table| return vm.metamethod(table, name),
            .string => vm.string_metatable orelse return .nil,
            else => return .nil,
        };
        return meta.get(.{ .string = vm.interner.intern(name) catch return error.OutOfMemory });
    }

    /// `MAXTAGLOOP`
    const max_tag_loop = 2000;

    fn getTableIndex(vm: *VM, receiver: Value, key: Value, note: []const u8) Error!Value {
        return vm.getTableIndexDepth(receiver, key, 0, note);
    }

    /// `luaV_finishget`: a receiver with no `__index` is a type error rather
    /// than a missing value — only a table reads nil. The `note` is the
    /// receiver's `varinfo` tail, which can describe the value at the head of
    /// the chain but not one the walk itself reached.
    fn getTableIndexDepth(vm: *VM, receiver: Value, key: Value, depth: usize, note: []const u8) Error!Value {
        if (depth >= max_tag_loop) return vm.raise("'__index' chain too long; possible loop", .{});
        if (receiver == .table) {
            const value = receiver.table.get(key);
            if (value != .nil) return value;
        }
        const index = try vm.valueMetamethod(receiver, "__index");
        if (index == .nil) {
            if (receiver == .table) return .nil;
            return vm.raiseIndexFailure(receiver, note);
        }
        return switch (index) {
            .function, .native_function => blk: {
                const values = try vm.invokeCallableValues(index, &.{ receiver, key });
                defer vm.allocator.free(values);
                break :blk if (values.len == 0) .nil else values[0];
            },
            else => vm.getTableIndexDepth(index, key, depth + 1, ""),
        };
    }

    fn setTableIndex(vm: *VM, receiver: Value, key: Value, value: Value, note: []const u8) Error!void {
        return vm.setTableIndexDepth(receiver, key, value, 0, note);
    }

    /// `luaH_newkey` refuses the keys nothing can be stored under. The
    /// assignment site and the constructor report the refusal with the
    /// running chunk's position; an API call like `rawset` has no Lua frame
    /// to point at, so its message comes through bare.
    fn checkStorableKey(vm: *VM, key: Value, plain: bool) Error!void {
        if (key == .nil) {
            if (plain) return vm.raisePlain("table index is nil", .{});
            return vm.raise("table index is nil", .{});
        }
        if (key == .number and key.number == .float and std.math.isNan(key.number.float)) {
            if (plain) return vm.raisePlain("table index is NaN", .{});
            return vm.raise("table index is NaN", .{});
        }
    }

    fn setTableIndexDepth(vm: *VM, receiver: Value, key: Value, value: Value, depth: usize, note: []const u8) Error!void {
        if (depth >= max_tag_loop) return vm.raise("'__newindex' chain too long; possible loop", .{});
        if (receiver == .table) {
            if (receiver.table.get(key) != .nil) {
                receiver.table.set(key, value) catch return error.OutOfMemory;
                return;
            }
        }
        const newindex = try vm.valueMetamethod(receiver, "__newindex");
        if (newindex == .nil) {
            if (receiver != .table) return vm.raiseIndexFailure(receiver, note);
            try vm.checkStorableKey(key, false);
            receiver.table.set(key, value) catch return error.OutOfMemory;
        } else {
            switch (newindex) {
                .function, .native_function => {
                    const values = try vm.invokeCallableValues(newindex, &.{ receiver, key, value });
                    vm.allocator.free(values);
                },
                else => try vm.setTableIndexDepth(newindex, key, value, depth + 1, ""),
            }
        }
    }

    fn evalTableConstructor(vm: *VM, constructor: *const Ast.TableConstructor) Error!Value {
        const table = try vm.newTable();

        // `OP_NEWTABLE` sizes both parts up front from what the parser counted:
        // the array to the list fields — minus a trailing multi-result field,
        // which `lastlistfield` does not count because its length is unknown —
        // and the hash part to `2^ceillog2(nrec)` nodes. Both sizes are
        // observable: a keyed integer field inside the static count lands in
        // the (still empty) array instead of the hash, and the record fields
        // take the pre-sized hash without a rehash.
        var static_count: u32 = 0;
        var records: u32 = 0;
        for (constructor.fields) |field| switch (field) {
            .expression => static_count += 1,
            .named, .indexed => records += 1,
        };
        if (constructor.fields.len != 0) switch (constructor.fields[constructor.fields.len - 1]) {
            .expression => |item| switch (item.expression) {
                .vararg, .function_call => static_count -= 1,
                else => {},
            },
            else => {},
        };
        table.prealloc(
            static_count,
            if (records == 0) 0 else @as(u32, 1) << @intCast(Table.ceillog2(records)),
        ) catch return error.OutOfMemory;

        var list_values: std.ArrayList(Value) = .empty;
        defer list_values.deinit(vm.allocator);
        for (constructor.fields, 0..) |field, field_index| switch (field) {
            .expression => |item| {
                const is_last = field_index + 1 == constructor.fields.len;
                if (is_last) switch (item.expression) {
                    .vararg => {
                        for (vm.exec.varargs) |value| {
                            list_values.append(vm.allocator, value) catch return error.OutOfMemory;
                        }
                        continue;
                    },
                    .function_call => |call| {
                        const values = try vm.evalCallMany(call);
                        defer vm.allocator.free(values);
                        for (values) |value| {
                            list_values.append(vm.allocator, value) catch return error.OutOfMemory;
                        }
                        continue;
                    },
                    else => {},
                };
                list_values.append(vm.allocator, try vm.eval(item.expression)) catch return error.OutOfMemory;
            },
            .named => |item| {
                const key = Value{ .string = vm.interner.intern(item.name.name) catch return error.OutOfMemory };
                table.set(key, try vm.eval(item.value)) catch return error.OutOfMemory;
            },
            .indexed => |item| {
                const key = try vm.eval(item.key);
                const value = try vm.eval(item.value);
                try vm.checkStorableKey(key, false);
                table.set(key, value) catch return error.OutOfMemory;
            },
        };

        // `OP_SETLIST`: grow the array to exactly the run's last index when it
        // does not fit — exact, not to a power of two — and then write the run
        // straight into the array part, which is why a keyed field that moved
        // into the array during the grow is overwritten by the list value that
        // lands on it.
        table.resizeArrayTo(@intCast(list_values.items.len)) catch return error.OutOfMemory;
        for (list_values.items, 0..) |value, index| {
            table.array[index] = value;
        }
        return .{ .table = table };
    }

    fn evalUnary(vm: *VM, op: Ast.UnaryOperator, expr: Ast.Expression) Error!Value {
        const value = try vm.eval(expr);
        var description_buffer: [192]u8 = undefined;
        const description = vm.operandDescription(expr, &description_buffer);
        return switch (op) {
            .not => .{ .boolean = !value.truthy() },
            .negation => switch (value) {
                .number => |n| .{ .number = Number.neg(n) },
                .string => |string| if (Number.parse(string.slice())) |number|
                    .{ .number = Number.neg(number) }
                else
                    return vm.raise("attempt to unm a 'string' with a 'string'", .{}),
                .table => try vm.invokeUnaryMetamethod(value, "__unm", description),
                else => return vm.raise("attempt to perform arithmetic on a {s} value{s}", .{ value.typeName(), description }),
            },
            .bitwise_not => switch (value) {
                .number => |n| .{ .number = Number.bitNot(n) catch return vm.raise("number has no integer representation{s}", .{description}) },
                .table, .string => try vm.invokeUnaryMetamethod(value, "__bnot", description),
                else => return vm.raise("attempt to perform bitwise operation on a {s} value{s}", .{ value.typeName(), description }),
            },
            .length => switch (value) {
                .string => |s| .{ .number = Number.Number.fromInt(s.len) },
                .table => |table| blk: {
                    const method = try vm.metamethod(table, "__len");
                    if (method != .nil) {
                        const results = try vm.invokeCallableValues(method, &.{value});
                        defer vm.allocator.free(results);
                        break :blk if (results.len == 0) .nil else results[0];
                    }
                    break :blk .{ .number = Number.Number.fromInt(table.len()) };
                },
                else => return vm.raise("attempt to get length of a {s} value", .{value.typeName()}),
            },
        };
    }

    fn arithmeticNumber(value: Value) ?Number.Number {
        return switch (value) {
            .number => |number| number,
            .string => |string| Number.parse(string.slice()),
            else => null,
        };
    }

    fn stringConvertible(value: Value) bool {
        return value == .string or value == .number;
    }

    /// The ` (local 'x')` tail `luaG_typeerror` builds by tracing where the
    /// offending value was loaded from: literals describe themselves, names
    /// carry their kind, and indexed reads are fields.
    fn operandDescription(vm: *VM, expression: Ast.Expression, buffer: []u8) []const u8 {
        switch (expression) {
            // parens are transparent to where a value came from: the register
            // behind `("x")` holds the constant the same as `"x"` does
            .parenthesized => |node| return vm.operandDescription(node.expression, buffer),
            .string => |node| return std.fmt.bufPrint(buffer, " (constant '{s}')", .{node.value}) catch "",
            .variable => |variable| switch (variable.*) {
                .name => |name| return vm.identifierDescription(name, buffer),
                .field => |field| {
                    switch (field.object) {
                        .variable => |object| switch (object.*) {
                            .name => |object_name| if (std.mem.eql(u8, object_name.name, "_ENV"))
                                return std.fmt.bufPrint(buffer, " (global '{s}')", .{field.name.name}) catch "",
                            else => {},
                        },
                        else => {},
                    }
                    return std.fmt.bufPrint(buffer, " (field '{s}')", .{field.name.name}) catch "";
                },
                .index => |index| switch (index.index) {
                    .string => |node| return std.fmt.bufPrint(buffer, " (field '{s}')", .{node.value}) catch "",
                    .number => return " (field 'integer index')",
                    else => {},
                },
            },
            else => {},
        }
        return "";
    }

    /// The ` (local 'x')` half of `varinfo` for a name, told from the
    /// resolution the semantic pass settled on
    fn identifierDescription(vm: *VM, name: Ast.Identifier, buffer: []u8) []const u8 {
        const kind: []const u8 = switch (vm.exec.semantics.resolutions.get(name.span.start) orelse .global) {
            .local => "local",
            .upvalue => "upvalue",
            .global => "global",
        };
        return std.fmt.bufPrint(buffer, " ({s} '{s}')", .{ kind, name.name }) catch "";
    }

    /// `luaG_typeerror`'s refusal for a receiver that nothing can be read
    /// through or written to
    fn raiseIndexFailure(vm: *VM, receiver: Value, note: []const u8) Error {
        return vm.raise("attempt to index a {s} value{s}", .{ receiver.typeName(), note });
    }

    fn isCallable(vm: *VM, value: Value) Error!bool {
        return switch (value) {
            .function, .native_function => true,
            .table => |table| (try vm.metamethod(table, "__call")) != .nil,
            else => false,
        };
    }

    fn callFailure(vm: *VM, callable: Value, description: []const u8) Error {
        return vm.raise("attempt to call a {s} value{s}", .{ callable.typeName(), description });
    }

    fn binaryMetamethod(vm: *VM, left: Value, right: Value, name: []const u8) Error!Value {
        const method = try vm.valueMetamethod(left, name);
        return if (method != .nil) method else vm.valueMetamethod(right, name);
    }

    fn invokeUnaryMetamethod(vm: *VM, operand: Value, name: []const u8, description: []const u8) Error!Value {
        const method = try vm.valueMetamethod(operand, name);
        if (method == .nil) {
            if (std.mem.eql(u8, name, "__unm"))
                return vm.raise("attempt to perform arithmetic on a {s} value{s}", .{ operand.typeName(), description });
            return vm.raise("attempt to perform bitwise operation on a {s} value{s}", .{ operand.typeName(), description });
        }
        const results = try vm.invokeCallableValues(method, &.{ operand, operand });
        defer vm.allocator.free(results);
        return if (results.len == 0) .nil else results[0];
    }

    fn equalWithMetamethod(vm: *VM, left: Value, right: Value) Error!bool {
        if (left.equal(right)) return true;
        // `__eq` runs between two tables only, and is looked up on the first
        // operand then the second: the reference no longer requires both
        // sides to resolve to the same method
        if (left != .table or right != .table) return false;
        var method = try vm.metamethod(left.table, "__eq");
        if (method == .nil) method = try vm.metamethod(right.table, "__eq");
        if (method == .nil) return false;
        const results = try vm.invokeCallableValues(method, &.{ left, right });
        defer vm.allocator.free(results);
        return results.len != 0 and results[0].truthy();
    }

    const OperatorDescriptions = struct { left: []const u8, right: []const u8 };

    fn applyBinaryMetamethod(vm: *VM, op: Ast.BinaryOperator, left: Value, right: Value, descriptions: OperatorDescriptions) Error!Value {
        const name: []const u8 = switch (op) {
            .add => "__add",
            .subtract => "__sub",
            .multiply => "__mul",
            .divide => "__div",
            .floor_divide => "__idiv",
            .modulo => "__mod",
            .power => "__pow",
            .bitwise_and => "__band",
            .bitwise_or => "__bor",
            .bitwise_xor => "__bxor",
            .shift_left => "__shl",
            .shift_right => "__shr",
            .less_than => "__lt",
            .less_equal => "__le",
            .greater_than => "__lt",
            .greater_equal => "__le",
            else => return error.RuntimeError,
        };
        const first = if (op == .greater_than or op == .greater_equal) right else left;
        const second = if (op == .greater_than or op == .greater_equal) left else right;
        var method = try vm.binaryMetamethod(first, second, name);
        var negate_result = false;
        if ((op == .less_equal or op == .greater_equal) and method == .nil) {
            method = try vm.binaryMetamethod(second, first, "__lt");
            negate_result = true;
        }
        if (method == .nil) {
            switch (op) {
                .add, .subtract, .multiply, .divide, .floor_divide, .modulo, .power => return vm.raiseArithmetic(op, left, right, descriptions),
                .bitwise_and, .bitwise_or, .bitwise_xor, .shift_left, .shift_right => {
                    const left_to_blame = left != .number;
                    const blame = if (left_to_blame) left else right;
                    const description = if (left_to_blame) descriptions.left else descriptions.right;
                    return vm.raise("attempt to perform bitwise operation on a {s} value{s}", .{ blame.typeName(), description });
                },
                .less_than, .less_equal, .greater_than, .greater_equal => {
                    const left_name = left.typeName();
                    const right_name = right.typeName();
                    if (std.mem.eql(u8, left_name, right_name))
                        return vm.raise("attempt to compare two {s} values", .{left_name});
                    return vm.raise("attempt to compare {s} with {s}", .{ left_name, right_name });
                },
                else => return error.RuntimeError,
            }
        }
        const results = try vm.invokeCallableValues(method, &.{ first, second });
        defer vm.allocator.free(results);
        const result = if (results.len == 0) .nil else results[0];
        // order comparisons answer a boolean, the way `luaT_callorderTM`
        // takes the truthiness of the metamethod's result; arithmetic and
        // the rest hand back whatever the metamethod returned
        return switch (op) {
            .less_than, .less_equal, .greater_than, .greater_equal => .{ .boolean = if (negate_result) !result.truthy() else result.truthy() },
            else => result,
        };
    }

    fn evalBinary(vm: *VM, node: *const Ast.BinaryExpression) Error!Value {
        const left = try vm.eval(node.left);
        if (node.operator == .@"and") return if (left.truthy()) vm.eval(node.right) else left;
        if (node.operator == .@"or") return if (left.truthy()) left else vm.eval(node.right);
        const right = try vm.eval(node.right);
        if (node.operator == .equal or node.operator == .not_equal) {
            const equal = try vm.equalWithMetamethod(left, right);
            return .{ .boolean = if (node.operator == .equal) equal else !equal };
        }
        if (node.operator == .concat) {
            if (!stringConvertible(left) or !stringConvertible(right)) {
                const method = try vm.binaryMetamethod(left, right, "__concat");
                if (method == .nil) {
                    var description_buffer: [192]u8 = undefined;
                    const left_to_blame = !stringConvertible(left);
                    const blame = if (left_to_blame) left else right;
                    const blame_expression = if (left_to_blame) node.left else node.right;
                    return vm.raise("attempt to concatenate a {s} value{s}", .{
                        blame.typeName(),
                        vm.operandDescription(blame_expression, &description_buffer),
                    });
                }
                const results = try vm.invokeCallableValues(method, &.{ left, right });
                defer vm.allocator.free(results);
                return if (results.len == 0) .nil else results[0];
            }
            var left_buffer: [64]u8 = undefined;
            var right_buffer: [64]u8 = undefined;
            const a_bytes = try vm.stringBytesInto(left, &left_buffer);
            const b_bytes = try vm.stringBytesInto(right, &right_buffer);
            const joined = vm.allocator.alloc(u8, a_bytes.len + b_bytes.len) catch return error.OutOfMemory;
            defer vm.allocator.free(joined);
            @memcpy(joined[0..a_bytes.len], a_bytes);
            @memcpy(joined[a_bytes.len..], b_bytes);
            return .{ .string = vm.interner.intern(joined) catch return error.OutOfMemory };
        }
        if (left == .string and right == .string and switch (node.operator) {
            .less_than, .less_equal, .greater_than, .greater_equal => true,
            else => false,
        }) {
            const order = std.mem.order(u8, left.string.slice(), right.string.slice());
            return switch (node.operator) {
                .less_than => .{ .boolean = order == .lt },
                .less_equal => .{ .boolean = order != .gt },
                .greater_than => .{ .boolean = order == .gt },
                .greater_equal => .{ .boolean = order != .lt },
                else => unreachable,
            };
        }
        const string_coercion = switch (node.operator) {
            .add, .subtract, .multiply, .divide, .floor_divide, .modulo, .power => true,
            else => false,
        };
        const a = if (string_coercion) arithmeticNumber(left) else if (left == .number) left.number else null;
        const b = if (string_coercion) arithmeticNumber(right) else if (right == .number) right.number else null;
        var left_description_buffer: [192]u8 = undefined;
        var right_description_buffer: [192]u8 = undefined;
        if (a == null or b == null) {
            return vm.applyBinaryMetamethod(node.operator, left, right, .{
                .left = vm.operandDescription(node.left, &left_description_buffer),
                .right = vm.operandDescription(node.right, &right_description_buffer),
            });
        }
        // Bitwise operators need integers, and the reference names the operand
        // that lacks the representation when it can be traced.
        switch (node.operator) {
            .bitwise_and, .bitwise_or, .bitwise_xor, .shift_left, .shift_right => {
                if (a.?.toIntExact() == null)
                    return vm.raise("number has no integer representation{s}", .{vm.operandDescription(node.left, &left_description_buffer)});
                if (b.?.toIntExact() == null)
                    return vm.raise("number has no integer representation{s}", .{vm.operandDescription(node.right, &right_description_buffer)});
            },
            else => {},
        }
        const result: Number.Number = switch (node.operator) {
            .add => Number.add(a.?, b.?),
            .subtract => Number.sub(a.?, b.?),
            .multiply => Number.mul(a.?, b.?),
            .divide => Number.div(a.?, b.?),
            .floor_divide => Number.floorDiv(a.?, b.?) catch return vm.raise("attempt to divide by zero", .{}),
            .modulo => Number.mod(a.?, b.?) catch return vm.raise("attempt to perform 'n%0'", .{}),
            .power => Number.pow(a.?, b.?),
            .bitwise_and => Number.bitAnd(a.?, b.?) catch return vm.raise("number has no integer representation", .{}),
            .bitwise_or => Number.bitOr(a.?, b.?) catch return vm.raise("number has no integer representation", .{}),
            .bitwise_xor => Number.bitXor(a.?, b.?) catch return vm.raise("number has no integer representation", .{}),
            .shift_left => Number.shiftLeft(a.?, b.?) catch return vm.raise("number has no integer representation", .{}),
            .shift_right => Number.shiftRight(a.?, b.?) catch return vm.raise("number has no integer representation", .{}),
            .less_than => return .{ .boolean = Number.less(a.?, b.?) },
            .less_equal => return .{ .boolean = Number.lessEq(a.?, b.?) },
            .greater_than => return .{ .boolean = Number.less(b.?, a.?) },
            .greater_equal => return .{ .boolean = Number.lessEq(b.?, a.?) },
            else => return error.UnsupportedExpression,
        };
        return .{ .number = result };
    }

    fn stringBytesInto(_: *VM, value: Value, buffer: *[64]u8) Error![]const u8 {
        return switch (value) {
            .string => |s| s.slice(),
            .number => |n| Number.toBytes(n, buffer) catch return error.RuntimeError,
            else => error.RuntimeError,
        };
    }
};

pub const Environment = struct {
    tracker: *@import("Object.zig").Tracker,
    table: *Table,

    pub fn init(allocator: std.mem.Allocator, tracker: *@import("Object.zig").Tracker) !Environment {
        return .{ .tracker = tracker, .table = try Table.create(allocator, tracker) };
    }

    pub fn deinit(env: *Environment) void {
        env.table.deinit(env.tracker);
    }
};

test "lexical _ENV redirects globals and is captured by nested closures" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("local original_environment = _ENV; local original_global = _G; local set_meta = setmetatable; local initial, fallback, captured, captured_same, env_x; do local _ENV = set_meta({x = 41}, {__index = function(t, k) if k == 'missing' then return 7 end end}); initial = x; fallback = missing; local function make_reader() local function read() return x, _ENV end; return read end; local reader = make_reader(); x = 42; local captured_environment; captured, captured_environment = reader(); captured_same = captured_environment == _ENV; env_x = _ENV.x end; _ENV = {x = 11}; local default_reader = function() return x, _ENV end; _ENV = {x = 12}; local rebound, rebound_environment = default_reader(); return initial, fallback, captured, captured_same, env_x, original_environment == original_global, rebound, rebound_environment == _ENV", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    try testing.expectEqual(@as(usize, 0), reporter.errors.items.len);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();
    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 8), values.len);
    try testing.expectEqual(@as(i64, 41), values[0].number.int);
    try testing.expectEqual(@as(i64, 7), values[1].number.int);
    try testing.expectEqual(@as(i64, 42), values[2].number.int);
    try testing.expect(values[3].boolean);
    try testing.expectEqual(@as(i64, 42), values[4].number.int);
    try testing.expect(values[5].boolean);
    try testing.expectEqual(@as(i64, 12), values[6].number.int);
    try testing.expect(values[7].boolean);
}

test "AST VM evaluates locals, arithmetic and structured control flow" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("local function identity(...) return ... end; local function bad() error(\"boom\") end; local ok_call, call_a, call_b = pcall(identity, 71, 72); local bad_call, bad_message = pcall(bad); local function twice(n) return n * 2 end; local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end; local function make(x) return function(y) x = x + y; return x end end; local add = make(10); local a, b, c = identity(31, 32, 33); local expanded = {identity(51, 52, 53)}; local function iter(state, control) control = control + 1; if control <= state then return control, control * 10 end end; local generic_sum = 0; for k, v in iter, 3, 0 do generic_sum = generic_sum + k + v end; local jump = 0; goto entered; jump = 100; ::entered:: jump = jump + 1; ::again:: jump = jump + 1; if jump < 3 then goto again end; for i = 1, 3 do if i == 2 then goto escaped end end; ::escaped:: jump = jump + 1; local select_a, select_b = select(2, 55, 56, 57); local select_count = select(\"#\", 5, 6, 7); local paren_a, paren_b = (identity(71, 72)); local assert_a, assert_b = assert(true, 81); local next_key, next_value = next({91, 92}); local next_sum = 0; for k, v in next, {11, 12}, nil do next_sum = next_sum + k + v end; local iter_pairs, state_pairs, control_pairs = pairs({17, 18}); local pair_key, pair_value = iter_pairs(state_pairs, control_pairs); local iter_ipairs, state_ipairs, control_ipairs = ipairs({19, 20}); local ipairs_key, ipairs_value = iter_ipairs(state_ipairs, control_ipairs); local list = {2, 4}; table.insert(list, 2, 3); table.insert(list, 5); local tail = table.remove(list); local removed = table.remove(list, 1); local joined = table.concat(list, \"-\"); local unpack_a, unpack_b = table.unpack(list); local sorting = {3, 1, 2}; table.sort(sorting); local sort_a, sort_b, sort_c = table.unpack(sorting); local descending = {1, 3, 2}; table.sort(descending, function(a, b) return a > b end); local desc_a = descending[1]; local total = 10; local function inc(d) total = total + d; return total end; local x = 0; while x < 3 do x = x + 1 end; local t = {x = 7, 4}; t[2] = 8; local sum = 0; local ipairs_fn = ipairs; local pairs_fn = pairs; for i = 1, 3 do sum = sum + i end; for _, v in ipairs_fn({2, 3, 4}) do sum = sum + v end; for _, v in pairs_fn({left = 2, right = 3}) do sum = sum + v end; ::final_again:: jump = jump + 1; if jump < 6 then goto final_again end; if x == 3 then return x, twice(x), t.x + t[1] + t[2], inc(3), inc(2), total, sum, #\"abc\", \"a\" .. 2, fact(5), add(1), add(2), a, b, c, expanded[1], expanded[2], expanded[3], generic_sum, jump, select_a, select_b, assert_a, assert_b, next_key, next_value, next_sum, select_count, paren_a, paren_b, ok_call, call_a, call_b, bad_call, bad_message, pair_key, pair_value, ipairs_key, ipairs_value, tail, removed, joined, unpack_a, unpack_b, sort_a, sort_b, sort_c, desc_a, identity(41, 42, 43) end", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();

    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 51), values.len);
    try testing.expectEqual(@as(i64, 3), values[0].number.int);
    try testing.expectEqual(@as(i64, 6), values[1].number.int);
    try testing.expectEqual(@as(i64, 19), values[2].number.int);
    try testing.expectEqual(@as(i64, 13), values[3].number.int);
    try testing.expectEqual(@as(i64, 15), values[4].number.int);
    try testing.expectEqual(@as(i64, 15), values[5].number.int);
    try testing.expectEqual(@as(i64, 20), values[6].number.int);
    try testing.expectEqual(@as(i64, 3), values[7].number.int);
    try testing.expectEqualStrings("a2", values[8].string.slice());
    try testing.expectEqual(@as(i64, 120), values[9].number.int);
    try testing.expectEqual(@as(i64, 11), values[10].number.int);
    try testing.expectEqual(@as(i64, 13), values[11].number.int);
    try testing.expectEqual(@as(i64, 31), values[12].number.int);
    try testing.expectEqual(@as(i64, 32), values[13].number.int);
    try testing.expectEqual(@as(i64, 33), values[14].number.int);
    try testing.expectEqual(@as(i64, 51), values[15].number.int);
    try testing.expectEqual(@as(i64, 52), values[16].number.int);
    try testing.expectEqual(@as(i64, 53), values[17].number.int);
    try testing.expectEqual(@as(i64, 66), values[18].number.int);
    try testing.expectEqual(@as(i64, 6), values[19].number.int);
    try testing.expectEqual(@as(i64, 56), values[20].number.int);
    try testing.expectEqual(@as(i64, 57), values[21].number.int);
    try testing.expect(values[22].boolean);
    try testing.expectEqual(@as(i64, 81), values[23].number.int);
    try testing.expectEqual(@as(i64, 1), values[24].number.int);
    try testing.expectEqual(@as(i64, 91), values[25].number.int);
    try testing.expectEqual(@as(i64, 26), values[26].number.int);
    try testing.expectEqual(@as(i64, 3), values[27].number.int);
    try testing.expectEqual(@as(i64, 71), values[28].number.int);
    try testing.expect(values[29] == .nil);
    try testing.expect(values[30].boolean);
    try testing.expectEqual(@as(i64, 71), values[31].number.int);
    try testing.expectEqual(@as(i64, 72), values[32].number.int);
    try testing.expect(!values[33].boolean);
    try testing.expectEqualStrings("boom", values[34].string.slice());
    try testing.expectEqual(@as(i64, 1), values[35].number.int);
    try testing.expectEqual(@as(i64, 17), values[36].number.int);
    try testing.expectEqual(@as(i64, 1), values[37].number.int);
    try testing.expectEqual(@as(i64, 19), values[38].number.int);
    try testing.expectEqual(@as(i64, 5), values[39].number.int);
    try testing.expectEqual(@as(i64, 2), values[40].number.int);
    try testing.expectEqualStrings("3-4", values[41].string.slice());
    try testing.expectEqual(@as(i64, 3), values[42].number.int);
    try testing.expectEqual(@as(i64, 4), values[43].number.int);
    try testing.expectEqual(@as(i64, 1), values[44].number.int);
    try testing.expectEqual(@as(i64, 2), values[45].number.int);
    try testing.expectEqual(@as(i64, 3), values[46].number.int);
    try testing.expectEqual(@as(i64, 3), values[47].number.int);
    try testing.expectEqual(@as(i64, 41), values[48].number.int);
    try testing.expectEqual(@as(i64, 42), values[49].number.int);
    try testing.expectEqual(@as(i64, 43), values[50].number.int);
}

test "byte string library operations" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("local n = string.len('hé'); local sub = string.sub('abcdef', -3, -2); local rep = string.rep('ab', 3, '-'); local rev = string.reverse('abc'); local upper = string.upper('aBc'); local upper_method = ('aBc'):upper(); local lower = string.lower('AbC'); local b1, b2 = string.byte('Az', 1, 2); local chars = string.char(65, 66); local fstart, fend = string.find('abcabc', 'bc', -4, true); local fmiss = string.find('abc', 'z'); local ps, pe, pc1, pc2 = string.find('abc 123!', '(%a+)%s+(%d+)'); local mc1, mc2 = string.match('abc 123!', '(%a+)%s+(%d+)'); local words = {}; for word in string.gmatch('one two 3', '%a+') do words[#words + 1] = word end; local substituted, sub_count = string.gsub('abc 12 and 34', '(%d+)', '[%1]'); local mapped, map_count = string.gsub('a1 b2', '%a', {a = 'A', b = 'B'}); local doubled, double_count = string.gsub('1 2', '%d+', function(x) return tonumber(x) * 2 end, 1); local empty, empty_count = string.gsub('abc', '', '-'); return n, sub, rep, rev, upper, upper_method, lower, b1, b2, chars, fstart, fend, fmiss, ps, pe, pc1, pc2, mc1, mc2, words[1], words[2], #words, substituted, sub_count, mapped, map_count, doubled, double_count, empty, empty_count", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();

    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 30), values.len);
    try testing.expectEqual(@as(i64, 3), values[0].number.int);
    try testing.expectEqualStrings("de", values[1].string.slice());
    try testing.expectEqualStrings("ab-ab-ab", values[2].string.slice());
    try testing.expectEqualStrings("cba", values[3].string.slice());
    try testing.expectEqualStrings("ABC", values[4].string.slice());
    try testing.expectEqualStrings("ABC", values[5].string.slice());
    try testing.expectEqualStrings("abc", values[6].string.slice());
    try testing.expectEqual(@as(i64, 65), values[7].number.int);
    try testing.expectEqual(@as(i64, 122), values[8].number.int);
    try testing.expectEqualStrings("AB", values[9].string.slice());
    try testing.expectEqual(@as(i64, 5), values[10].number.int);
    try testing.expectEqual(@as(i64, 6), values[11].number.int);
    try testing.expect(values[12] == .nil);
    try testing.expectEqual(@as(i64, 1), values[13].number.int);
    try testing.expectEqual(@as(i64, 7), values[14].number.int);
    try testing.expectEqualStrings("abc", values[15].string.slice());
    try testing.expectEqualStrings("123", values[16].string.slice());
    try testing.expectEqualStrings("abc", values[17].string.slice());
    try testing.expectEqualStrings("123", values[18].string.slice());
    try testing.expectEqualStrings("one", values[19].string.slice());
    try testing.expectEqualStrings("two", values[20].string.slice());
    try testing.expectEqual(@as(i64, 2), values[21].number.int);
    try testing.expectEqualStrings("abc [12] and [34]", values[22].string.slice());
    try testing.expectEqual(@as(i64, 2), values[23].number.int);
    try testing.expectEqualStrings("A1 B2", values[24].string.slice());
    try testing.expectEqual(@as(i64, 2), values[25].number.int);
    try testing.expectEqualStrings("2 2", values[26].string.slice());
    try testing.expectEqual(@as(i64, 1), values[27].number.int);
    try testing.expectEqualStrings("-a-b-c-", values[28].string.slice());
    try testing.expectEqual(@as(i64, 4), values[29].number.int);
}

test "string format supports conversions, width, precision, quoting and methods" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("return string.format('%s:%04d %.2f %X %q %%', 'id', 7, 3.14159, 255, 'a\\n'), string.format('%-5s|%08.2f|%c', 'ok', 3.5, 65), ('%d'):format(9)", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();
    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 3), values.len);
    try testing.expectEqualStrings("id:0007 3.14 FF \"a\\\n\" %", values[0].string.slice());
    try testing.expectEqualStrings("ok   |00003.50|A", values[1].string.slice());
    try testing.expectEqualStrings("9", values[2].string.slice());
}

test "math library numeric functions and constants" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("local whole, fraction = math.modf(-3.25); local safe, absolute = pcall(math.abs, -13); local handled, message = xpcall(function() error('failure') end, function(problem) return 'handled: ' .. problem end); local type_fn = _G.type; local selected = select(2, 'a', 'b'); local assert_fn = assert; assert_fn(true); _G.type = nil; local missing = pcall(function() return type('y') end); return math.abs(-7), math.floor(3.8), math.ceil(-3.8), math.sqrt(81), math.fmod(-7, 3), math.max(1, 9, 4), math.min(1, 9, 4), math.tointeger(4.0), math.tointeger(4.2), math.type(2.0), math.type('x'), math.pi, math.maxinteger, math.sin(math.pi / 2), math.log(8, 2), whole, fraction, math.ult(-1, 1), safe, absolute, handled, message, type_fn('x'), selected, not missing", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();
    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 25), values.len);
    try testing.expectEqual(@as(i64, 7), values[0].number.int);
    try testing.expectEqual(@as(i64, 3), values[1].number.int);
    try testing.expectEqual(@as(i64, -3), values[2].number.int);
    try testing.expectEqual(@as(f64, 9), values[3].number.float);
    try testing.expectEqual(@as(i64, -1), values[4].number.int);
    try testing.expectEqual(@as(i64, 9), values[5].number.int);
    try testing.expectEqual(@as(i64, 1), values[6].number.int);
    try testing.expectEqual(@as(i64, 4), values[7].number.int);
    try testing.expect(values[8] == .nil);
    try testing.expectEqualStrings("float", values[9].string.slice());
    try testing.expect(values[10] == .nil);
    try testing.expectApproxEqAbs(std.math.pi, values[11].number.float, 0.0000001);
    try testing.expectEqual(std.math.maxInt(i64), values[12].number.int);
    try testing.expectApproxEqAbs(@as(f64, 1), values[13].number.float, 0.0000001);
    try testing.expectApproxEqAbs(@as(f64, 3), values[14].number.float, 0.0000001);
    try testing.expectEqual(@as(i64, -3), values[15].number.int);
    try testing.expectApproxEqAbs(@as(f64, -0.25), values[16].number.float, 0.0000001);
    try testing.expect(values[17] == .boolean and !values[17].boolean);
    try testing.expect(values[18] == .boolean and values[18].boolean);
    try testing.expectEqual(@as(i64, 13), values[19].number.int);
    try testing.expect(values[20] == .boolean and !values[20].boolean);
    try testing.expectEqualStrings("handled: failure", values[21].string.slice());
    try testing.expectEqualStrings("string", values[22].string.slice());
    try testing.expectEqualStrings("b", values[23].string.slice());
    try testing.expect(values[24] == .boolean and values[24].boolean);
}

test "math random supports seeded repeatability and integer ranges" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("math.randomseed(123, 456); local a = math.random(); local x = math.random(10); local y = math.random(-5, 5); math.randomseed(123, 456); local b = math.random(); local seed1, seed2 = math.randomseed(); local full = math.random(0); local wide = math.random(-9223372036854775808, 9223372036854775807); return a == b, x >= 1 and x <= 10, y >= -5 and y <= 5, a >= 0 and a < 1, math.type(seed1) == 'integer', math.type(seed2) == 'integer', math.type(full) == 'integer', math.type(wide) == 'integer'", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();
    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 8), values.len);
    for (values) |value| try testing.expect(value == .boolean and value.boolean);
}

test "rawlen and table pack and move follow base sequence behavior" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("local packed = table.pack(7, nil, 9); local t = {1, 2, 3, 4}; table.move(t, 1, 3, 2); local k, v = 1, 2; local fields = {k, named = k, [k] = v}; local from_table = (function(v) return v.answer end){answer = 42}; local from_string = string.upper'abc'; local string_upper = ('abc').upper; local string_meta = getmetatable('x'); local string_write = 0; string_meta.__newindex = function(value, key, assigned) string_write = assigned end; ('x').marker = 42; local module = {sub = {base = 1}}; function module.sub:answer(x) return self.base + x end; local closed = 0; local resource = setmetatable({}, {__close = function(v, e) closed = closed + 1 end}); do local scoped <close> = resource end; repeat local repeated <close> = resource until closed == 2; local text = utf8.char(65, 0x1f642, 233); local utf_len = utf8.len(text); local cp1, cp2, cp3 = utf8.codepoint(text, 1, 7); local off2 = utf8.offset(text, 2); local offlast = utf8.offset(text, -1); local current = utf8.offset(text, 0, 4); local total = 0; for pos, cp in utf8.codes(text) do total = total + cp end; local invalid, invalid_pos = utf8.len(string.char(0xc0, 0x80)); local pattern_match = string.match(text, utf8.charpattern); local coerced = '12' + 3; local negated = -'0x4'; local bitwise_ok = pcall(function() return '2' & 1 end); local fallback = 'bad' + setmetatable({}, {__add = function(a, b) return 77 end}); return packed.n, packed[1], packed[2], packed[3], t[1], t[2], t[3], t[4], rawlen('abc'), rawlen(t), from_table, from_string, module.sub:answer(41), closed, utf_len, cp1, cp2, cp3, off2, offlast, current, total, invalid, invalid_pos, pattern_match, fields[1], fields.named, fields[k], string_upper('def'), string_meta.__index == string, string_write, coerced, negated, bitwise_ok, fallback", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();
    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 35), values.len);
    try testing.expectEqual(@as(i64, 3), values[0].number.int);
    try testing.expectEqual(@as(i64, 7), values[1].number.int);
    try testing.expect(values[2] == .nil);
    try testing.expectEqual(@as(i64, 9), values[3].number.int);
    try testing.expectEqual(@as(i64, 1), values[4].number.int);
    try testing.expectEqual(@as(i64, 1), values[5].number.int);
    try testing.expectEqual(@as(i64, 2), values[6].number.int);
    try testing.expectEqual(@as(i64, 3), values[7].number.int);
    try testing.expectEqual(@as(i64, 3), values[8].number.int);
    try testing.expectEqual(@as(i64, 4), values[9].number.int);
    try testing.expectEqual(@as(i64, 42), values[10].number.int);
    try testing.expectEqualStrings("ABC", values[11].string.slice());
    try testing.expectEqual(@as(i64, 42), values[12].number.int);
    try testing.expectEqual(@as(i64, 3), values[13].number.int);
    try testing.expectEqual(@as(i64, 3), values[14].number.int);
    try testing.expectEqual(@as(i64, 65), values[15].number.int);
    try testing.expectEqual(@as(i64, 128578), values[16].number.int);
    try testing.expectEqual(@as(i64, 233), values[17].number.int);
    try testing.expectEqual(@as(i64, 2), values[18].number.int);
    try testing.expectEqual(@as(i64, 6), values[19].number.int);
    try testing.expectEqual(@as(i64, 2), values[20].number.int);
    try testing.expectEqual(@as(i64, 128876), values[21].number.int);
    try testing.expect(values[22] == .nil);
    try testing.expectEqual(@as(i64, 1), values[23].number.int);
    try testing.expectEqualStrings("A", values[24].string.slice());
    try testing.expectEqual(@as(i64, 1), values[25].number.int);
    try testing.expectEqual(@as(i64, 1), values[26].number.int);
    try testing.expectEqual(@as(i64, 1), values[27].number.int);
    try testing.expectEqualStrings("DEF", values[28].string.slice());
    try testing.expect(values[29].boolean);
    try testing.expectEqual(@as(i64, 42), values[30].number.int);
    try testing.expectEqual(@as(i64, 15), values[31].number.int);
    try testing.expectEqual(@as(i64, -4), values[32].number.int);
    try testing.expect(values[33] == .boolean and !values[33].boolean);
    try testing.expectEqual(@as(i64, 77), values[34].number.int);
}

test "table metatables support protected access and index fallbacks" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("local backing = {answer = 42}; local inherited = setmetatable({}, {__index = backing}); local proxy = setmetatable({}, {__index = function(t, k) return k .. '!' end}); local writes = {}; local sink = setmetatable({}, {__newindex = function(t, k, v) writes[k] = v end, __metatable = 'locked'}); sink.x = 9; local ops = {__len = function(t) return 77 end, __add = function(a, b) return 88 end, __eq = function(a, b) return true end, __lt = function(a, b) return true end, __unm = function(a) return 66 end, __bnot = function(a) return 55 end}; local a = setmetatable({}, ops); local b = setmetatable({}, ops); local callable = setmetatable({}, {__call = function(self, n) return n + 1 end, __tostring = function(self) return 'callable' end}); local iter, state = pairs(setmetatable({}, {__pairs = function(t) return next, {tag = 1}, nil end})); return inherited.answer, proxy.answer, proxy.other, writes.x, getmetatable(proxy).__index ~= nil, getmetatable(sink), #a, a + b, a == b, a < b, -a, ~a, callable(8), tostring(callable), type(iter), state.tag", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();
    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 16), values.len);
    try testing.expectEqual(@as(i64, 42), values[0].number.int);
    try testing.expectEqualStrings("answer!", values[1].string.slice());
    try testing.expectEqualStrings("other!", values[2].string.slice());
    try testing.expectEqual(@as(i64, 9), values[3].number.int);
    try testing.expect(values[4] == .boolean and values[4].boolean);
    try testing.expectEqualStrings("locked", values[5].string.slice());
    try testing.expectEqual(@as(i64, 77), values[6].number.int);
    try testing.expectEqual(@as(i64, 88), values[7].number.int);
    try testing.expect(values[8] == .boolean and values[8].boolean);
    try testing.expect(values[9] == .boolean and values[9].boolean);
    try testing.expectEqual(@as(i64, 66), values[10].number.int);
    try testing.expectEqual(@as(i64, 55), values[11].number.int);
    try testing.expectEqual(@as(i64, 9), values[12].number.int);
    try testing.expectEqualStrings("callable", values[13].string.slice());
    try testing.expectEqualStrings("function", values[14].string.slice());
    try testing.expectEqual(@as(i64, 1), values[15].number.int);
}

test "os.exit stops the chunk and carries its requested status" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource("local marker = 0; os.exit(7); marker = 1", &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    defer vm.deinit();
    try testing.expectError(error.ExitRequested, vm.run(&chunk));
    try testing.expectEqual(@as(?u8, 7), vm.exit_status);
}

test "io files support formats, seeking, append, and automatic line iteration" {
    const Diagnostic = @import("Diagnostic.zig");
    const Parser = @import("Parser.zig");
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/io.txt", .{temp.sub_path});
    defer testing.allocator.free(path);
    const source = try std.fmt.allocPrint(testing.allocator,
        \\local path = "{s}"
        \\local f = assert(io.open(path, "w"))
        \\f:write("123 alpha\n456 beta")
        \\f:close()
        \\f = assert(io.open(path, "r+"))
        \\local number, rest = f:read("*n", "*l")
        \\assert(number == 123 and rest == " alpha")
        \\assert(f:seek("end", -4) == 14)
        \\assert(f:read("*L") == "beta")
        \\f:close()
        \\f = assert(io.open(path, "a"))
        \\f:write("!")
        \\f:close()
        \\f = assert(io.open(path, "r"))
        \\local lines = ""
        \\for number, rest in f:lines("*n", "*l") do lines = lines .. number .. rest end
        \\assert(io.type(f) == "file")
        \\assert(f:close())
        \\local temp = assert(io.tmpfile())
        \\temp:write("temporary")
        \\temp:seek("set", 0)
        \\assert(temp:read("*a") == "temporary")
        \\temp:close()
        \\return lines
    , .{path});
    defer testing.allocator.free(source);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var reporter: Diagnostic.Reporter = .{ .gpa = testing.allocator };
    defer reporter.deinit();
    var parser = Parser.fromSource(source, &arena, &reporter);
    const chunk = try parser.parseChunk();
    const semantics = try Semantic.analyze(arena.allocator(), &reporter, &chunk);
    var tracker: @import("Object.zig").Tracker = .init(testing.allocator);
    defer tracker.deinit();
    var interner = try Str.Interner.init(testing.allocator, &tracker);
    defer interner.deinit();
    var environment = try Environment.init(testing.allocator, &tracker);
    defer environment.deinit();
    var vm = try VM.init(testing.allocator, &interner, &semantics, &tracker, environment.table);
    vm.io = testing.io;
    defer vm.deinit();
    const values = try vm.run(&chunk);
    try testing.expectEqual(@as(usize, 1), values.len);
    try testing.expectEqualStrings("123 alpha456 beta!", values[0].string.slice());
}
