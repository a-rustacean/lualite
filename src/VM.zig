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

pub const Error = error{ OutOfMemory, MissingResolution, UnsupportedExpression, UnsupportedStatement, RuntimeError, StepLimit, ExitRequested };
const Frame = struct { cells: []@import("Value.zig").Cell, pointers: []*@import("Value.zig").Cell };
const ErrorFrame = struct { program: ?*const Semantic.Program, call_offset: ?u32 };
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
fn shortSource(buffer: *[64]u8, name: []const u8) []const u8 {
    const limit = buffer.len - 1;
    if (name.len == 0) return "?";
    if (name[0] == '=') {
        const literal = name[1..];
        if (literal.len <= limit) {
            @memcpy(buffer[0..literal.len], literal);
            return buffer[0..literal.len];
        }
        @memcpy(buffer[0..limit], literal[0..limit]);
        return buffer[0..limit];
    }
    if (name[0] == '@') {
        const file = name[1..];
        if (file.len <= limit) {
            @memcpy(buffer[0..file.len], file);
            return buffer[0..file.len];
        }
        buffer[0] = '.';
        buffer[1] = '.';
        buffer[2] = '.';
        @memcpy(buffer[3..], file[file.len - (limit - 3) ..]);
        return buffer[0..limit];
    }
    // a string chunk, which reads as [string "..."]
    var text = name;
    if (std.mem.indexOfScalar(u8, text, '\n')) |at| text = text[0..at];
    const room = limit - ("[string \"\"]".len + 3);
    const piece = text[0..@min(text.len, room)];
    const suffix: []const u8 = if (piece.len == text.len) "\"]" else "...\"]";
    const prefix = "[string \"";
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + piece.len], piece);
    @memcpy(buffer[prefix.len + piece.len .. prefix.len + piece.len + suffix.len], suffix);
    return buffer[0 .. prefix.len + piece.len + suffix.len];
}

/// Simple tree-walking runtime over the resolved AST. Keep it direct for now;
/// introduce an IR only when a concrete optimization or backend needs one.
pub const VM = struct {
    allocator: std.mem.Allocator,
    interner: *Str.Interner,
    semantics: *const Semantic.Program,
    owned_program_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    owned_cells: std.ArrayList(*@import("Value.zig").Cell) = .empty,
    tracker: *@import("Object.zig").Tracker,
    collector: Collector,
    locals: []*@import("Value.zig").Cell,
    globals: *Table,
    global_environment: *@import("Value.zig").Cell,
    active_environment: *@import("Value.zig").Cell,
    string_metatable: ?*Table = null,
    writer: ?*std.Io.Writer = null,
    stderr: ?*std.Io.Writer = null,
    io: ?std.Io = null,
    environ_map: ?*std.process.Environ.Map = null,
    warn_state: enum { off, ready } = .off,
    owned_tables: std.ArrayList(*Table) = .empty,
    owned_files: std.ArrayList(*FileHandle) = .empty,
    file_metatable: ?*Table = null,
    default_input: ?*Table = null,
    default_output: ?*Table = null,
    owned_functions: std.ArrayList(*@import("Value.zig").Function) = .empty,
    owned_frames: std.ArrayList(Frame) = .empty,
    owned_captures: std.ArrayList([]*@import("Value.zig").Cell) = .empty,
    suspended_locals: std.ArrayList([]*@import("Value.zig").Cell) = .empty,
    suspended_varargs: std.ArrayList([]const Value) = .empty,
    suspended_results: std.ArrayList([]Value) = .empty,
    // One entry per running Lua function, innermost last. `call_offset` is
    // where that function was called from in the frame below it, which is what
    // `error` level 2 and up point at. Natives do not get a frame: a native has
    // no position of its own to report.
    error_frames: std.ArrayList(ErrorFrame) = .empty,
    active_functions: std.ArrayList(*@import("Value.zig").Function) = .empty,
    upvalues: []*@import("Value.zig").Cell = &.{},
    varargs: []const Value = &.{},
    function_index: u32 = 0,
    results: std.ArrayList(Value) = .empty,
    close_values: std.ArrayList(Value) = .empty,
    returned: bool = false,
    breaking: bool = false,
    goto_name: ?[]const u8 = null,
    thrown_error: ?Value = null,
    steps_left: usize = 1_000_000,
    number_buffer: [64]u8 = undefined,
    error_offset: ?u32 = null,
    rng_state: [4]u64 = seedRandomState(0x6c75616c697465, 0x72616e646f6d),
    gc_stopped: bool = false,
    gc_pending: bool = false,
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
            .semantics = semantics,
            .tracker = tracker,
            .collector = .init(allocator),
            .locals = &.{},
            .globals = globals,
            .global_environment = global_environment,
            .active_environment = global_environment,
        };
        vm.locals = try vm.allocFrame(semantics.functions[0].frame_size);
        try vm.installTableLibrary();
        try vm.installStringLibrary();
        try vm.installUtf8Library();
        try vm.installMathLibrary();
        try vm.installOsLibrary();
        try vm.installIoLibrary();
        try vm.installBaseLibrary();
        return vm;
    }

    pub fn deinit(vm: *VM) void {
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
        vm.suspended_locals.deinit(vm.allocator);
        vm.suspended_varargs.deinit(vm.allocator);
        vm.suspended_results.deinit(vm.allocator);
        vm.error_frames.deinit(vm.allocator);
        vm.active_functions.deinit(vm.allocator);
        vm.results.deinit(vm.allocator);
        vm.close_values.deinit(vm.allocator);
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
        vm.error_frames.append(vm.allocator, .{ .program = vm.semantics, .call_offset = null }) catch return error.OutOfMemory;
        errdefer _ = vm.error_frames.pop();
        try vm.execBlock(&chunk.block);
        _ = vm.error_frames.pop();
        try vm.collectAtSafePoint();
        return vm.results.items;
    }

    fn tick(vm: *VM) Error!void {
        if (!vm.gc_stopped and vm.tracker.count >= vm.gc_threshold) vm.gc_pending = true;
        if (vm.steps_left == 0) return error.StepLimit;
        vm.steps_left -= 1;
    }

    fn execBlock(vm: *VM, block: *const Ast.Block) Error!void {
        const close_start = vm.close_values.items.len;
        vm.execBlockBody(block) catch |err| {
            const original_error = vm.thrown_error;
            vm.closeScope(close_start) catch return error.RuntimeError;
            vm.thrown_error = original_error;
            return err;
        };
        try vm.closeScope(close_start);
    }

    fn execBlockBody(vm: *VM, block: *const Ast.Block) Error!void {
        var statement_index: usize = 0;
        while (true) {
            if (vm.returned or vm.breaking) return;
            if (vm.goto_name) |target| {
                if (findLabelStatement(block, target)) |label_index| {
                    vm.goto_name = null;
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
        if (vm.goto_name != null) return;
        if (!vm.returned) if (block.ret_statement) |ret| {
            try vm.execReturn(ret);
            try vm.collectAtSafePoint();
        };
    }

    fn closeScope(vm: *VM, start: usize) Error!void {
        var close_error: ?Error = null;
        while (vm.close_values.items.len > start) {
            const value = vm.close_values.pop().?;
            if (value == .nil or (value == .boolean and !value.boolean)) continue;
            const method = if (value == .table) try vm.metamethod(value.table, "__close") else .nil;
            if (method == .nil) {
                close_error = error.RuntimeError;
                continue;
            }
            const error_value = vm.thrown_error orelse Value.nil;
            const returned = vm.invokeCallableValues(method, &.{ value, error_value }) catch |err| {
                close_error = err;
                continue;
            };
            vm.allocator.free(returned);
        }
        if (close_error) |err| return err;
    }

    fn execRepeatIteration(vm: *VM, node: *const Ast.RepeatStatement) Error!bool {
        const close_start = vm.close_values.items.len;
        vm.execBlockBody(&node.block) catch |err| {
            const original_error = vm.thrown_error;
            vm.closeScope(close_start) catch return error.RuntimeError;
            vm.thrown_error = original_error;
            return err;
        };
        var should_stop = vm.returned or vm.goto_name != null;
        if (vm.breaking) {
            vm.breaking = false;
            should_stop = true;
        } else if (!should_stop) {
            const condition = vm.eval(node.condition) catch |err| {
                const original_error = vm.thrown_error;
                vm.closeScope(close_start) catch return error.RuntimeError;
                vm.thrown_error = original_error;
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
        vm.error_offset = statementSpan(statement).start;
        try vm.tick();
        switch (statement) {
            .empty, .label => {},
            .goto => |node| vm.goto_name = node.name.name,
            .@"break" => vm.breaking = true,
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
                            if (method == .nil) return error.RuntimeError;
                        }
                        vm.close_values.append(vm.allocator, value) catch return error.OutOfMemory;
                    };
                }
            },
            .local_function_definition => |definition| {
                // the name is in scope in its own body, so the cell the closure
                // captures has to be the one the declaration installs
                const slot = try vm.localSlot(definition.name);
                try vm.declareCell(slot, .nil);
                const value = try vm.makeFunction(&definition.body);
                vm.locals[slot].value = .{ .function = value };
            },
            .function_definition => |definition| {
                const function: Value = .{ .function = try vm.makeFunction(&definition.body) };
                if (definition.name.fields.len == 0 and definition.name.method == null) {
                    try vm.setName(definition.name.first, function);
                } else {
                    var receiver = try vm.getName(definition.name.first);
                    const traversed_fields = if (definition.name.method != null) definition.name.fields.len else definition.name.fields.len - 1;
                    for (definition.name.fields[0..traversed_fields]) |field| {
                        receiver = try vm.getTableIndex(receiver, .{ .string = vm.interner.intern(field.name) catch return error.OutOfMemory });
                    }
                    const table = switch (receiver) {
                        .table => |table| table,
                        else => return error.RuntimeError,
                    };
                    const final_name = if (definition.name.method) |method|
                        method.name
                    else
                        definition.name.fields[definition.name.fields.len - 1].name;
                    try vm.setTableIndex(.{ .table = table }, .{ .string = vm.interner.intern(final_name) catch return error.OutOfMemory }, function);
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
                        .index => |index| try vm.setTableIndex(index.receiver, index.key, value),
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
                if (vm.returned or vm.goto_name != null) break;
                if (vm.breaking) {
                    vm.breaking = false;
                    break;
                }
            },
            .repeat => |node| while (true) {
                try vm.tick();
                if (try vm.execRepeatIteration(node)) break;
            },
            .numeric_for => |node| {
                const initial = try vm.numberValue(node.initial);
                const limit = try vm.numberValue(node.limit);
                const step = if (node.step) |expr| try vm.numberValue(expr) else Number.Number.fromInt(1);
                const slot = try vm.localSlot(node.name);
                var current = initial;
                while (if (Number.less(step, Number.Number.fromInt(0))) !Number.less(current, limit) else !Number.less(limit, current)) {
                    try vm.tick();
                    try vm.declareCell(slot, .{ .number = current });
                    try vm.execBlock(&node.block);
                    if (vm.returned or vm.goto_name != null) break;
                    if (vm.breaking) {
                        vm.breaking = false;
                        break;
                    }
                    current = Number.add(current, step);
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
                    if (vm.returned or vm.goto_name != null) break;
                    if (vm.breaking) {
                        vm.breaking = false;
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
        vm.results.appendSlice(vm.allocator, values) catch return error.OutOfMemory;
        vm.returned = true;
    }

    fn evalList(vm: *VM, expressions: []const Ast.Expression) Error![]Value {
        var values: std.ArrayList(Value) = .empty;
        errdefer values.deinit(vm.allocator);
        for (expressions, 0..) |expr, i| {
            const is_last = i + 1 == expressions.len;
            if (is_last) switch (expr) {
                .vararg => {
                    values.appendSlice(vm.allocator, vm.varargs) catch return error.OutOfMemory;
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
            vm.locals[slot].value = value;
            return;
        }
        const cell = vm.allocator.create(@import("Value.zig").Cell) catch return error.OutOfMemory;
        cell.* = .{ .value = value };
        vm.owned_cells.append(vm.allocator, cell) catch {
            vm.allocator.destroy(cell);
            return error.OutOfMemory;
        };
        vm.locals[slot] = cell;
    }

    fn slotIsCaptured(vm: *VM, slot: usize) bool {
        const function = vm.semantics.functions[vm.function_index];
        return slot < function.captured_slots.len and function.captured_slots[slot];
    }

    fn localSlot(vm: *VM, name: Ast.Identifier) Error!usize {
        return switch (vm.semantics.resolutions.get(name.span.start) orelse return error.MissingResolution) {
            .local => |slot| if (slot < vm.locals.len) slot else error.MissingResolution,
            else => error.UnsupportedExpression,
        };
    }

    fn setName(vm: *VM, name: Ast.Identifier, value: Value) Error!void {
        switch (vm.semantics.resolutions.get(name.span.start) orelse return error.MissingResolution) {
            .local => |slot| vm.locals[slot].value = value,
            .upvalue => |slot| if (slot < vm.upvalues.len) {
                vm.upvalues[slot].value = value;
            } else return error.MissingResolution,
            .global => {
                if (std.mem.eql(u8, name.name, "_ENV")) {
                    vm.active_environment.value = value;
                    return;
                }
                const key = Value{ .string = vm.interner.intern(name.name) catch return error.OutOfMemory };
                const environment = try vm.environmentValue(name);
                try vm.setTableIndex(environment, key, value);
            },
        }
    }

    fn getName(vm: *VM, name: Ast.Identifier) Error!Value {
        return switch (vm.semantics.resolutions.get(name.span.start) orelse return error.MissingResolution) {
            .local => |slot| vm.locals[slot].value,
            .global => if (std.mem.eql(u8, name.name, "_ENV"))
                vm.active_environment.value
            else
                try vm.getTableIndex(
                    try vm.environmentValue(name),
                    .{ .string = vm.interner.intern(name.name) catch return error.OutOfMemory },
                ),
            .upvalue => |slot| if (slot < vm.upvalues.len) vm.upvalues[slot].value else error.MissingResolution,
        };
    }

    fn environmentValue(vm: *VM, name: Ast.Identifier) Error!Value {
        return switch (vm.semantics.environment_resolutions.get(name.span.start) orelse .global) {
            .local => |slot| if (slot < vm.locals.len) vm.locals[slot].value else error.MissingResolution,
            .upvalue => |slot| if (slot < vm.upvalues.len) vm.upvalues[slot].value else error.MissingResolution,
            .global => vm.active_environment.value,
        };
    }

    fn eval(vm: *VM, expr: Ast.Expression) Error!Value {
        vm.error_offset = expressionSpan(expr).start;
        try vm.tick();
        return switch (expr) {
            .nil => .nil,
            .boolean => |node| .{ .boolean = node.value },
            .number => |node| .{ .number = node.value },
            .string => |node| .{ .string = vm.interner.intern(node.value) catch return error.OutOfMemory },
            .variable => |variable| switch (variable.*) {
                .name => |name| try vm.getName(name),
                .field => |field| try vm.getTableIndex(try vm.eval(field.object), .{ .string = vm.interner.intern(field.name.name) catch return error.OutOfMemory }),
                .index => |index| try vm.getTableIndex(try vm.eval(index.object), try vm.eval(index.index)),
            },
            .parenthesized => |node| try vm.eval(node.expression),
            .unary => |node| try vm.evalUnary(node.operator, node.expression),
            .binary => |node| try vm.evalBinary(node),
            .table => |table| try vm.evalTableConstructor(table),
            .function => |function| .{ .function = try vm.makeFunction(&function.body) },
            .function_call => |call| try vm.evalCall(call),
            .vararg => if (vm.varargs.len == 0) .nil else vm.varargs[0],
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
        const definition = vm.semantics.definitions.get(body.span.start) orelse return error.MissingResolution;
        const semantic_function = vm.semantics.functions[definition.function];
        const captures = vm.allocator.alloc(*@import("Value.zig").Cell, semantic_function.upvalues.len) catch return error.OutOfMemory;
        errdefer vm.allocator.free(captures);
        for (semantic_function.upvalues, 0..) |upvalue, i| captures[i] = switch (upvalue) {
            .parent_local => |slot| if (slot < vm.locals.len) vm.locals[slot] else return error.MissingResolution,
            .parent_upvalue => |slot| if (slot < vm.upvalues.len) vm.upvalues[slot] else return error.MissingResolution,
        };
        const function = vm.tracker.alloc(@import("Value.zig").Function, .function) catch return error.OutOfMemory;
        errdefer vm.tracker.free(function);
        function.semantics = vm.semantics;
        function.body = body;
        function.function_index = definition.function;
        function.captures = captures;
        function.environment = vm.active_environment;
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
            const method_value = try vm.getTableIndex(receiver, key);
            vm.error_offset = call.span.start;
            if (!try vm.isCallable(method_value)) {
                var description_buffer: [192]u8 = undefined;
                const description = std.fmt.bufPrint(&description_buffer, " (method '{s}')", .{method.name}) catch "";
                return vm.callFailure(method_value, description);
            }
            const arguments = vm.allocator.alloc(Value, explicit_values.len + 1) catch return error.OutOfMemory;
            defer vm.allocator.free(arguments);
            arguments[0] = receiver;
            @memcpy(arguments[1..], explicit_values);
            break :blk try vm.invokeCallableValues(method_value, arguments);
        } else blk: {
            const function = try vm.eval(call.expression);
            vm.error_offset = call.span.start;
            if (!try vm.isCallable(function)) {
                var description_buffer: [192]u8 = undefined;
                return vm.callFailure(function, vm.operandDescription(call.expression, &description_buffer));
            }
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
            const method_value = try vm.getTableIndex(receiver, .{ .string = vm.interner.intern(method.name) catch return error.OutOfMemory });
            vm.error_offset = call.span.start;
            if (!try vm.isCallable(method_value)) {
                var description_buffer: [192]u8 = undefined;
                const description = std.fmt.bufPrint(&description_buffer, " (method '{s}')", .{method.name}) catch "";
                return vm.callFailure(method_value, description);
            }
            break :blk try vm.invokeCallableValues(method_value, &.{ receiver, argument });
        } else blk: {
            const function = try vm.eval(call.expression);
            vm.error_offset = call.span.start;
            if (!try vm.isCallable(function)) {
                var description_buffer: [192]u8 = undefined;
                return vm.callFailure(function, vm.operandDescription(call.expression, &description_buffer));
            }
            break :blk try vm.invokeCallableValues(function, &.{argument});
        };
        defer vm.allocator.free(results);
        return if (results.len == 0) .nil else results[0];
    }

    fn protectedCall(vm: *VM, args: []const Value, has_handler: bool) Error![]Value {
        if (args.len < (if (has_handler) @as(usize, 2) else 1)) return error.RuntimeError;
        const function = args[0];
        const handler = if (has_handler) args[1] else .nil;
        const call_args = args[if (has_handler) 2 else 1..];
        const saved_error = vm.thrown_error;
        vm.thrown_error = null;
        const results = vm.invokeCallableValues(function, call_args) catch |err| {
            const thrown = vm.thrown_error orelse Value{ .string = vm.interner.intern("runtime error") catch return error.OutOfMemory };
            vm.thrown_error = saved_error;
            if (err != error.RuntimeError) return err;
            var handled = thrown;
            if (has_handler) {
                vm.thrown_error = null;
                const message = vm.invokeCallableValues(handler, &.{thrown}) catch {
                    vm.thrown_error = saved_error;
                    const fallback = Value{ .string = vm.interner.intern("error in error handling") catch return error.OutOfMemory };
                    return vm.allocator.dupe(Value, &.{ .{ .boolean = false }, fallback }) catch return error.OutOfMemory;
                };
                handled = if (message.len == 0) .nil else message[0];
                vm.allocator.free(message);
                vm.thrown_error = saved_error;
            }
            return vm.allocator.dupe(Value, &.{ .{ .boolean = false }, handled }) catch return error.OutOfMemory;
        };
        defer vm.allocator.free(results);
        vm.thrown_error = saved_error;
        const values = vm.allocator.alloc(Value, results.len + 1) catch return error.OutOfMemory;
        values[0] = .{ .boolean = true };
        @memcpy(values[1..], results);
        return values;
    }

    fn invokeCallableValues(vm: *VM, callable: Value, args: []const Value) Error![]Value {
        return vm.invokeCallableDepth(callable, args, 0);
    }

    fn invokeCallableDepth(vm: *VM, callable: Value, args: []const Value, depth: usize) Error![]Value {
        if (depth >= 200) return error.RuntimeError;
        return switch (callable) {
            .function => |function| vm.invokeValues(function, args),
            .native_function => |function| vm.invokeNativeValues(function, args),
            .table => |table| blk: {
                const method = try vm.metamethod(table, "__call");
                if (method == .nil) return vm.raisePlain("attempt to call a {s} value", .{callable.typeName()});
                const arguments = vm.allocator.alloc(Value, args.len + 1) catch return error.OutOfMemory;
                defer vm.allocator.free(arguments);
                arguments[0] = callable;
                @memcpy(arguments[1..], args);
                break :blk try vm.invokeCallableDepth(method, arguments, depth + 1);
            },
            else => return vm.raisePlain("attempt to call a {s} value", .{callable.typeName()}),
        };
    }

    fn invokeNativeValues(vm: *VM, function: ValueModule.NativeFunction, args: []const Value) Error![]Value {
        // Natives get a position-less frame so that `error` levels count them,
        // the way the reference counts C calls: asking for a level that lands
        // on a native yields no position rather than the Lua frame below it.
        vm.error_frames.append(vm.allocator, .{ .program = null, .call_offset = vm.error_offset }) catch return error.OutOfMemory;
        defer _ = vm.error_frames.pop();
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
                if (args.len < 1) return error.RuntimeError;
                if (args[0] != .table) return error.RuntimeError;
                if (function == .pairs) {
                    const method = try vm.metamethod(args[0].table, "__pairs");
                    if (method != .nil) return vm.invokeCallableValues(method, &.{args[0]});
                }
                const iterator: Value = .{ .native_function = if (function == .pairs) .next else .ipairs_iterator };
                return vm.allocator.dupe(Value, &.{ iterator, args[0], .nil }) catch return error.OutOfMemory;
            },
            .next => {
                if (args.len == 0 or args[0] != .table) return error.RuntimeError;
                const key = if (args.len == 1 or args[1] == .nil) null else args[1];
                const pair = args[0].table.next(key);
                if (pair) |entry| return vm.allocator.dupe(Value, &.{ entry.key, entry.value }) catch return error.OutOfMemory;
                return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
            },
            .ipairs_iterator => {
                if (args.len < 2 or args[0] != .table) return error.RuntimeError;
                const previous = switch (args[1]) {
                    .nil => @as(i64, 0),
                    .number => |number| number.toIntExact() orelse return error.RuntimeError,
                    else => return error.RuntimeError,
                };
                const index = std.math.add(i64, previous, 1) catch return error.RuntimeError;
                const key: Value = .{ .number = Number.Number.fromInt(index) };
                const value = args[0].table.get(key);
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
            .utf8_char => return vm.utf8Char(args),
            .utf8_len => return vm.utf8Len(args),
            .utf8_codepoint => return vm.utf8Codepoint(args),
            .utf8_offset => return vm.utf8Offset(args),
            .utf8_codes => return vm.utf8Codes(args),
            .utf8_codes_iterator => return vm.utf8CodesIterator(args),
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
            .os_exit => return vm.osExit(args),
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
            .file_read => return vm.fileRead(args),
            .file_write => return vm.fileWrite(args),
            .file_flush => return vm.fileFlush(args),
            .file_close => return vm.fileClose(args),
            .file_seek => return vm.fileSeek(args),
            .file_lines => return vm.fileLines(args),
            .file_lines_iterator => return vm.fileLinesIterator(args),
        }
    }

    fn stringLen(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .string) return error.RuntimeError;
        const len = std.math.cast(i64, args[0].string.slice().len) orelse return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{.{ .number = Number.Number.fromInt(len) }}) catch return error.OutOfMemory;
    }

    fn stringSub(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .string) return error.RuntimeError;
        const bytes = args[0].string.slice();
        const len = std.math.cast(i64, bytes.len) orelse return error.RuntimeError;
        const raw_first = try intArgument(args[1]);
        const raw_last = if (args.len == 3) try intArgument(args[2]) else -1;
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
        if (args.len < 2 or args[0] != .string) return error.RuntimeError;
        const count = try intArgument(args[1]);
        if (count < 0) return error.RuntimeError;
        const separator = if (args.len == 3) switch (args[2]) {
            .string => |string| string.slice(),
            else => return error.RuntimeError,
        } else "";
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        const bytes = args[0].string.slice();
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
        if (args.len < 1 or args[0] != .string) return error.RuntimeError;
        const bytes = args[0].string.slice();
        const reversed = vm.allocator.alloc(u8, bytes.len) catch return error.OutOfMemory;
        defer vm.allocator.free(reversed);
        for (bytes, 0..) |byte, i| reversed[bytes.len - i - 1] = byte;
        const string = vm.interner.intern(reversed) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringCase(vm: *VM, args: []const Value, uppercase: bool) Error![]Value {
        if (args.len < 1 or args[0] != .string) return error.RuntimeError;
        const bytes = args[0].string.slice();
        const changed = vm.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        defer vm.allocator.free(changed);
        for (changed) |*byte| byte.* = if (uppercase) std.ascii.toUpper(byte.*) else std.ascii.toLower(byte.*);
        const string = vm.interner.intern(changed) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringByte(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0 or args[0] != .string) return error.RuntimeError;
        const bytes = args[0].string.slice();
        const len = std.math.cast(i64, bytes.len) orelse return error.RuntimeError;
        const raw_first = if (args.len > 1) try intArgument(args[1]) else 1;
        const raw_last = if (args.len > 2) try intArgument(args[2]) else raw_first;
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
        const bytes = vm.allocator.alloc(u8, args.len) catch return error.OutOfMemory;
        defer vm.allocator.free(bytes);
        for (args, 0..) |arg, i| {
            const code = try intArgument(arg);
            if (code < 0 or code > 255) return error.RuntimeError;
            bytes[i] = @intCast(code);
        }
        const string = vm.interner.intern(bytes) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringFind(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .string or args[1] != .string) return error.RuntimeError;
        const source = args[0].string.slice();
        const pattern = args[1].string.slice();
        const source_len = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const raw_init = if (args.len > 2) try intArgument(args[2]) else 1;
        const start_index = if (raw_init < 0) @max(1, @addWithOverflow(raw_init, source_len + 1)[0]) else raw_init;
        const plain = args.len > 3 and args[3] == .boolean and args[3].boolean;
        const start: usize = @intCast(@min(@max(start_index, 1) - 1, source_len));
        if (start_index <= source_len + 1) {
            const found = if (plain) blk: {
                if (std.mem.indexOfPos(u8, source, start, pattern)) |position| break :blk Pattern.Result{
                    .start = position,
                    .end = position + pattern.len,
                    .captures = undefined,
                    .capture_count = 0,
                };
                break :blk null;
            } else Pattern.find(source, pattern, start) catch return error.RuntimeError;
            if (found) |result| {
                const extra = if (result.capture_count == 0) 0 else result.capture_count;
                const values = vm.allocator.alloc(Value, 2 + extra) catch return error.OutOfMemory;
                values[0] = .{ .number = Number.Number.fromInt(@intCast(result.start + 1)) };
                values[1] = .{ .number = Number.Number.fromInt(@intCast(result.end)) };
                for (result.captures[0..result.capture_count], 0..) |capture, i| values[i + 2] = try vm.patternCapture(source, capture);
                return values;
            }
        }
        return vm.allocator.dupe(Value, &.{.{ .boolean = false }}) catch return error.OutOfMemory;
    }

    fn stringMatch(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .string or args[1] != .string) return error.RuntimeError;
        const source = args[0].string.slice();
        const len = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const raw_init = if (args.len == 3) try intArgument(args[2]) else 1;
        const start_index = if (raw_init < 0) @max(1, @addWithOverflow(raw_init, len + 1)[0]) else raw_init;
        if (start_index > len + 1) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const start: usize = @intCast(@min(@max(start_index, 1) - 1, len));
        const result = Pattern.find(source, args[1].string.slice(), start) catch return error.RuntimeError;
        const found = result orelse return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        if (found.capture_count == 0) {
            const matched = vm.interner.intern(source[found.start..found.end]) catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = matched }}) catch return error.OutOfMemory;
        }
        const values = vm.allocator.alloc(Value, found.capture_count) catch return error.OutOfMemory;
        for (found.captures[0..found.capture_count], 0..) |capture, i| values[i] = try vm.patternCapture(source, capture);
        return values;
    }

    fn stringGmatch(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .string or args[1] != .string) return error.RuntimeError;
        const state = try vm.newTable();
        try vm.setStringField(state, "source", args[0]);
        try vm.setStringField(state, "pattern", args[1]);
        try vm.setStringField(state, "position", .{ .number = Number.Number.fromInt(0) });
        return vm.allocator.dupe(Value, &.{ .{ .native_function = .string_gmatch_iterator }, .{ .table = state }, .nil }) catch return error.OutOfMemory;
    }

    fn stringGmatchIterator(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .table) return error.RuntimeError;
        const state = args[0].table;
        const source_value = try vm.getStringField(state, "source");
        const pattern_value = try vm.getStringField(state, "pattern");
        const position_value = try vm.getStringField(state, "position");
        if (source_value != .string or pattern_value != .string or position_value != .number) return error.RuntimeError;
        const source = source_value.string.slice();
        const position = try intArgument(position_value);
        if (position < 0 or position > source.len) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const found = Pattern.find(source, pattern_value.string.slice(), @intCast(position)) catch return error.RuntimeError;
        const result = found orelse return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
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
        if (args.len < 3 or args[0] != .string or args[1] != .string) return error.RuntimeError;
        const source = args[0].string.slice();
        const pattern = args[1].string.slice();
        const max_replacements = if (args.len == 4) @max(0, try intArgument(args[3])) else std.math.maxInt(i64);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        var search: usize = 0;
        var copied: usize = 0;
        var replacements: i64 = 0;
        while (search <= source.len and replacements < max_replacements) {
            try vm.tick();
            const found = Pattern.find(source, pattern, search) catch return error.RuntimeError;
            const result = found orelse break;
            output.appendSlice(vm.allocator, source[copied..result.start]) catch return error.OutOfMemory;
            try vm.appendGsubReplacement(&output, source, result, args[2]);
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

        var value: Value = .nil;
        if (replacement == .table) {
            const key = if (captures.len != 0) try vm.patternCapture(source, captures[0]) else Value{ .string = vm.interner.intern(whole) catch return error.OutOfMemory };
            value = try vm.getTableIndex(replacement, key);
        } else if (replacement == .function or replacement == .native_function or replacement == .table) {
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
        } else try vm.appendReplacementValue(output, value);
    }

    fn appendGsubTemplate(vm: *VM, output: *std.ArrayList(u8), source: []const u8, result: Pattern.Result, template: []const u8) Error!void {
        var i: usize = 0;
        while (i < template.len) {
            if (template[i] != '%') {
                output.append(vm.allocator, template[i]) catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            if (i + 1 >= template.len) return error.RuntimeError;
            const replacement = template[i + 1];
            if (replacement == '%') {
                output.append(vm.allocator, '%') catch return error.OutOfMemory;
            } else if (replacement == '0') {
                output.appendSlice(vm.allocator, source[result.start..result.end]) catch return error.OutOfMemory;
            } else if (replacement >= '1' and replacement <= '9') {
                const capture_index: usize = replacement - '1';
                if (capture_index >= result.capture_count) return error.RuntimeError;
                const value = try vm.patternCapture(source, result.captures[capture_index]);
                try vm.appendReplacementValue(output, value);
            } else return error.RuntimeError;
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
    const PackFormat = struct {
        source: []const u8,
        index: usize = 0,
        little_endian: bool = @import("builtin").cpu.arch.endian() == .little,
        max_alignment: usize = 1,

        fn next(format: *PackFormat) Error!?PackSpec {
            while (format.index < format.source.len) {
                const option = format.source[format.index];
                format.index += 1;
                switch (option) {
                    ' ', '\t', '\n', '\r', '\x0b', '\x0c' => continue,
                    '<' => {
                        format.little_endian = true;
                        continue;
                    },
                    '>' => {
                        format.little_endian = false;
                        continue;
                    },
                    '=' => {
                        format.little_endian = @import("builtin").cpu.arch.endian() == .little;
                        continue;
                    },
                    '!' => {
                        const alignment = try format.optionalSize(1);
                        if (alignment == 0 or alignment > 16 or !std.math.isPowerOfTwo(alignment)) return error.RuntimeError;
                        format.max_alignment = alignment;
                        continue;
                    },
                    'x' => return .{ .kind = .padding, .size = 1, .alignment = 1 },
                    'X' => {
                        const aligned = (try format.next()) orelse return error.RuntimeError;
                        return .{ .kind = .align_only, .size = 0, .alignment = aligned.alignment };
                    },
                    'b' => return format.spec(.signed, 1),
                    'B' => return format.spec(.unsigned, 1),
                    'h' => return format.spec(.signed, @sizeOf(c_short)),
                    'H' => return format.spec(.unsigned, @sizeOf(c_short)),
                    'l' => return format.spec(.signed, @sizeOf(c_long)),
                    'L' => return format.spec(.unsigned, @sizeOf(c_long)),
                    'j' => return format.spec(.signed, @sizeOf(i64)),
                    'J' => return format.spec(.unsigned, @sizeOf(u64)),
                    'T' => return format.spec(.unsigned, @sizeOf(usize)),
                    'i' => return format.spec(.signed, try format.optionalSize(@sizeOf(c_int))),
                    'I' => return format.spec(.unsigned, try format.optionalSize(@sizeOf(c_int))),
                    'f' => return format.spec(.float32, @sizeOf(f32)),
                    'd', 'n' => return format.spec(.float64, @sizeOf(f64)),
                    'c' => return .{ .kind = .fixed_string, .size = try format.requiredSize(), .alignment = 1 },
                    'z' => return .{ .kind = .zero_string, .size = 0, .alignment = 1 },
                    's' => {
                        const prefix = try format.optionalSize(@sizeOf(usize));
                        if (prefix == 0 or prefix > 16) return error.RuntimeError;
                        return .{ .kind = .sized_string, .size = 0, .alignment = @min(prefix, format.max_alignment), .prefix_size = prefix };
                    },
                    else => return error.RuntimeError,
                }
            }
            return null;
        }

        fn spec(format: *PackFormat, kind: PackKind, size: usize) Error!?PackSpec {
            if (size == 0 or size > 16) return error.RuntimeError;
            return .{ .kind = kind, .size = size, .alignment = @min(size, format.max_alignment) };
        }

        fn optionalSize(format: *PackFormat, default: usize) Error!usize {
            if (format.index >= format.source.len or !std.ascii.isDigit(format.source[format.index])) return default;
            return format.parseSize();
        }

        fn requiredSize(format: *PackFormat) Error!usize {
            if (format.index >= format.source.len or !std.ascii.isDigit(format.source[format.index])) return error.RuntimeError;
            return format.parseSize();
        }

        fn parseSize(format: *PackFormat) Error!usize {
            var size: usize = 0;
            while (format.index < format.source.len and std.ascii.isDigit(format.source[format.index])) : (format.index += 1) {
                size = std.math.mul(usize, size, 10) catch return error.RuntimeError;
                size = std.math.add(usize, size, format.source[format.index] - '0') catch return error.RuntimeError;
                if (size > 16 * 1024 * 1024) return error.RuntimeError;
            }
            if (size == 0) return error.RuntimeError;
            return size;
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

    fn readPackedInteger(bytes: []const u8, position: usize, size: usize, little_endian: bool) u128 {
        var result: u128 = 0;
        for (0..size) |i| {
            const source = if (little_endian) i else size - i - 1;
            result |= @as(u128, bytes[position + source]) << @as(u7, @intCast(i * 8));
        }
        return result;
    }

    fn stringPack(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0 or args[0] != .string) return error.RuntimeError;
        var format: PackFormat = .{ .source = args[0].string.slice() };
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        var argument_index: usize = 1;
        while (try format.next()) |spec| {
            const padding = packPadding(output.items.len, spec.alignment);
            try output.appendNTimes(vm.allocator, 0, padding);
            switch (spec.kind) {
                .padding => try output.appendNTimes(vm.allocator, 0, spec.size),
                .align_only => {},
                .signed, .unsigned => {
                    if (argument_index >= args.len) return error.RuntimeError;
                    const integer = try intArgument(args[argument_index]);
                    argument_index += 1;
                    if (spec.kind == .signed) {
                        const signed: i128 = integer;
                        if (spec.size < 16) {
                            const bits: u7 = @intCast(spec.size * 8);
                            const minimum = -(@as(i128, 1) << (bits - 1));
                            const maximum = (@as(i128, 1) << (bits - 1)) - 1;
                            if (signed < minimum or signed > maximum) return error.RuntimeError;
                        }
                        try vm.appendPackedInteger(&output, @bitCast(signed), spec.size, format.little_endian);
                    } else {
                        const unsigned: u64 = @bitCast(integer);
                        if (spec.size < 8 and unsigned >= (@as(u64, 1) << @as(u6, @intCast(spec.size * 8)))) return error.RuntimeError;
                        try vm.appendPackedInteger(&output, unsigned, spec.size, format.little_endian);
                    }
                },
                .float32 => {
                    if (argument_index >= args.len or args[argument_index] != .number) return error.RuntimeError;
                    argument_index += 1;
                    const bits: u32 = @bitCast(@as(f32, @floatCast(args[argument_index - 1].number.toFloat())));
                    try vm.appendPackedInteger(&output, bits, spec.size, format.little_endian);
                },
                .float64 => {
                    if (argument_index >= args.len or args[argument_index] != .number) return error.RuntimeError;
                    argument_index += 1;
                    const bits: u64 = @bitCast(args[argument_index - 1].number.toFloat());
                    try vm.appendPackedInteger(&output, bits, spec.size, format.little_endian);
                },
                .fixed_string => {
                    if (argument_index >= args.len or args[argument_index] != .string) return error.RuntimeError;
                    const bytes = args[argument_index].string.slice();
                    argument_index += 1;
                    if (bytes.len > spec.size) return error.RuntimeError;
                    output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                    try output.appendNTimes(vm.allocator, 0, spec.size - bytes.len);
                },
                .zero_string => {
                    if (argument_index >= args.len or args[argument_index] != .string) return error.RuntimeError;
                    const bytes = args[argument_index].string.slice();
                    argument_index += 1;
                    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.RuntimeError;
                    output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                    output.append(vm.allocator, 0) catch return error.OutOfMemory;
                },
                .sized_string => {
                    if (argument_index >= args.len or args[argument_index] != .string) return error.RuntimeError;
                    const bytes = args[argument_index].string.slice();
                    argument_index += 1;
                    const length: u128 = bytes.len;
                    if (spec.prefix_size < 16 and length >= (@as(u128, 1) << @as(u7, @intCast(spec.prefix_size * 8)))) return error.RuntimeError;
                    try vm.appendPackedInteger(&output, length, spec.prefix_size, format.little_endian);
                    output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                },
            }
        }
        const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn stringPackSize(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .string) return error.RuntimeError;
        var format: PackFormat = .{ .source = args[0].string.slice() };
        var size: usize = 0;
        while (try format.next()) |spec| {
            if (spec.kind == .zero_string or spec.kind == .sized_string) return error.RuntimeError;
            size = std.math.add(usize, size, packPadding(size, spec.alignment)) catch return error.RuntimeError;
            size = std.math.add(usize, size, spec.size) catch return error.RuntimeError;
        }
        return vm.singleNumber(Number.Number.fromInt(std.math.cast(i64, size) orelse return error.RuntimeError));
    }

    fn stringUnpack(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .string or args[1] != .string) return error.RuntimeError;
        const format_text = args[0].string.slice();
        const bytes = args[1].string.slice();
        const raw_position = if (args.len == 3) try intArgument(args[2]) else 1;
        const position: usize = if (raw_position > 0)
            std.math.cast(usize, raw_position - 1) orelse return error.RuntimeError
        else if (raw_position < 0)
            std.math.cast(usize, @as(i128, @intCast(bytes.len)) + raw_position) orelse return error.RuntimeError
        else
            return error.RuntimeError;
        if (position > bytes.len) return error.RuntimeError;
        var cursor = position;
        var format: PackFormat = .{ .source = format_text };
        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(vm.allocator);
        while (try format.next()) |spec| {
            cursor = std.math.add(usize, cursor, packPadding(cursor, spec.alignment)) catch return error.RuntimeError;
            if (spec.kind == .padding) {
                cursor = std.math.add(usize, cursor, spec.size) catch return error.RuntimeError;
                if (cursor > bytes.len) return error.RuntimeError;
                continue;
            }
            if (spec.kind == .align_only) continue;
            switch (spec.kind) {
                .signed, .unsigned => {
                    if (spec.size > bytes.len -| cursor) return error.RuntimeError;
                    const bits = readPackedInteger(bytes, cursor, spec.size, format.little_endian);
                    cursor += spec.size;
                    if (spec.kind == .signed) {
                        var signed_bits = bits;
                        const sign_shift: u7 = @intCast(spec.size * 8 - 1);
                        if ((bits & (@as(u128, 1) << sign_shift)) != 0 and spec.size < 16) signed_bits |= @as(u128, std.math.maxInt(u128)) << @as(u7, @intCast(spec.size * 8));
                        const signed: i128 = @bitCast(signed_bits);
                        if (signed < std.math.minInt(i64) or signed > std.math.maxInt(i64)) return error.RuntimeError;
                        try values.append(vm.allocator, .{ .number = Number.Number.fromInt(@intCast(signed)) });
                    } else {
                        if (bits > std.math.maxInt(i64)) return error.RuntimeError;
                        try values.append(vm.allocator, .{ .number = Number.Number.fromInt(@intCast(bits)) });
                    }
                },
                .float32 => {
                    if (spec.size > bytes.len -| cursor) return error.RuntimeError;
                    const bits: u32 = @truncate(readPackedInteger(bytes, cursor, spec.size, format.little_endian));
                    cursor += spec.size;
                    try values.append(vm.allocator, .{ .number = Number.Number.fromFloat(@as(f64, @floatCast(@as(f32, @bitCast(bits))))) });
                },
                .float64 => {
                    if (spec.size > bytes.len -| cursor) return error.RuntimeError;
                    const bits: u64 = @truncate(readPackedInteger(bytes, cursor, spec.size, format.little_endian));
                    cursor += spec.size;
                    try values.append(vm.allocator, .{ .number = Number.Number.fromFloat(@bitCast(bits)) });
                },
                .fixed_string => {
                    if (spec.size > bytes.len -| cursor) return error.RuntimeError;
                    const string = vm.interner.intern(bytes[cursor .. cursor + spec.size]) catch return error.OutOfMemory;
                    try values.append(vm.allocator, .{ .string = string });
                    cursor += spec.size;
                },
                .zero_string => {
                    const end = std.mem.indexOfScalarPos(u8, bytes, cursor, 0) orelse return error.RuntimeError;
                    const string = vm.interner.intern(bytes[cursor..end]) catch return error.OutOfMemory;
                    try values.append(vm.allocator, .{ .string = string });
                    cursor = end + 1;
                },
                .sized_string => {
                    if (spec.prefix_size > bytes.len -| cursor) return error.RuntimeError;
                    const length = readPackedInteger(bytes, cursor, spec.prefix_size, format.little_endian);
                    cursor += spec.prefix_size;
                    if (length > bytes.len -| cursor) return error.RuntimeError;
                    const len: usize = @intCast(length);
                    const string = vm.interner.intern(bytes[cursor .. cursor + len]) catch return error.OutOfMemory;
                    try values.append(vm.allocator, .{ .string = string });
                    cursor += len;
                },
                .padding => unreachable,
                .align_only => unreachable,
            }
        }
        try values.append(vm.allocator, .{ .number = Number.Number.fromInt(std.math.cast(i64, cursor + 1) orelse return error.RuntimeError) });
        return vm.allocator.dupe(Value, values.items) catch return error.OutOfMemory;
    }

    fn stringFormat(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0 or args[0] != .string) return error.RuntimeError;
        const format = args[0].string.slice();
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        var next_arg: usize = 1;
        var i: usize = 0;
        while (i < format.len) {
            if (format[i] != '%') {
                output.append(vm.allocator, format[i]) catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            const conversion_start = i;
            i += 1;
            if (i < format.len and format[i] == '%') {
                output.append(vm.allocator, '%') catch return error.OutOfMemory;
                i += 1;
                continue;
            }
            var flags: [8]u8 = undefined;
            var flag_count: usize = 0;
            var left = false;
            while (i < format.len) : (i += 1) switch (format[i]) {
                '-', '+', ' ', '0', '#' => {
                    // The reference stops at six flags, the width of its flag set.
                    if (flag_count == 6) return vm.raise("invalid format (repeated flags)", .{});
                    if (format[i] == '-') left = true;
                    flags[flag_count] = format[i];
                    flag_count += 1;
                },
                else => break,
            };
            var width: usize = 0;
            const width_start = i;
            while (i < format.len and std.ascii.isDigit(format[i])) : (i += 1) {}
            if (i - width_start > 2) return vm.raise("invalid format (width or precision too long)", .{});
            if (i > width_start) width = std.fmt.parseInt(usize, format[width_start..i], 10) catch return error.RuntimeError;
            var precision: ?usize = null;
            if (i < format.len and format[i] == '.') {
                i += 1;
                const precision_start = i;
                while (i < format.len and std.ascii.isDigit(format[i])) : (i += 1) {}
                if (i - precision_start > 2) return vm.raise("invalid format (width or precision too long)", .{});
                precision = if (i == precision_start) 0 else std.fmt.parseInt(usize, format[precision_start..i], 10) catch return error.RuntimeError;
            }
            const conversion = format[conversion_start..@min(i + 1, format.len)];
            if (i >= format.len) return vm.raise("invalid conversion '{s}' to 'format'", .{conversion});
            const specifier = format[i];
            i += 1;
            // `checkformat` in lstrlib.c: each conversion accepts a fixed flag
            // set, and only some take a precision.
            const allowed_flags: []const u8 = switch (specifier) {
                'd', 'i' => "-+0 ",
                'u' => "-0",
                'o', 'x', 'X' => "-#0",
                'c', 'p', 's' => "-",
                'a', 'A', 'f', 'F', 'e', 'E', 'g', 'G' => "-+#0 ",
                'q' => "",
                else => return vm.raise("invalid conversion '{s}' to 'format'", .{conversion}),
            };
            if (specifier == 'q') {
                if (conversion.len != 2) return vm.raise("specifier '%q' cannot have modifiers", .{});
            } else {
                for (flags[0..flag_count]) |flag| {
                    if (std.mem.indexOfScalar(u8, allowed_flags, flag) == null)
                        return vm.raise("invalid conversion specification: '{s}'", .{conversion});
                }
                if (precision != null and (specifier == 'c' or specifier == 'p'))
                    return vm.raise("invalid conversion specification: '{s}'", .{conversion});
            }
            if (next_arg >= args.len) return vm.raise("bad argument #{d} to 'format' (no value)", .{next_arg + 1});
            const value = args[next_arg];
            next_arg += 1;
            switch (specifier) {
                's' => {
                    // `%s` accepts anything `tostring` can render, as
                    // `luaL_tolstring` does for the reference.
                    var owned: ?[]Value = null;
                    defer if (owned) |results| vm.allocator.free(results);
                    const bytes = if (value == .string) value.string.slice() else blk: {
                        const results = try vm.baseToString(&.{value});
                        owned = results;
                        break :blk results[0].string.slice();
                    };
                    if (conversion.len > 2 and std.mem.indexOfScalar(u8, bytes, 0) != null)
                        return vm.raise("bad argument #{d} to 'format' (string contains zeros)", .{next_arg - 1});
                    const count = @min(bytes.len, precision orelse bytes.len);
                    try vm.appendFormatField(&output, bytes[0..count], width, left, ' ');
                },
                'q' => switch (value) {
                    .string => |string| try vm.appendQuoted(&output, string.slice()),
                    .number => |number| try vm.appendQuotedNumber(&output, number),
                    .nil => output.appendSlice(vm.allocator, "nil") catch return error.OutOfMemory,
                    .boolean => |boolean| output.appendSlice(vm.allocator, if (boolean) "true" else "false") catch return error.OutOfMemory,
                    else => return vm.raise("bad argument #{d} to 'format' (value has no literal form)", .{next_arg - 1}),
                },
                'c',
                'p',
                'd',
                'i',
                'u',
                'o',
                'x',
                'X',
                'f',
                'F',
                'e',
                'E',
                'g',
                'G',
                'a',
                'A',
                => try vm.appendNumericFormat(&output, value, flags[0..flag_count], width, precision, specifier),
                else => return vm.raise("invalid conversion '{s}' to 'format'", .{conversion}),
            }
        }
        const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
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
        if (number.toIntExact()) |integer| {
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

    /// Numeric conversions hand the parsed flags, width and precision to the
    /// C library; integers go through `long long` and floats stay `double`,
    /// mirroring `addlenmod` and `LUAI_UACNUMBER` in lstrlib.c. `%c` truncates
    /// to `int` (which C then narrows to a byte) and `%p` prints a collector
    /// address, with `(null)` for values `lua_topointer` refuses, as Lua does.
    fn appendNumericFormat(vm: *VM, output: *std.ArrayList(u8), value: Value, flags: []const u8, width: usize, precision: ?usize, specifier: u8) Error!void {
        if (specifier == 'p') {
            const pointer: ?*const anyopaque = switch (value) {
                .string => |string| @ptrCast(string),
                .table => |table| @ptrCast(table),
                .function => |function| @ptrCast(function),
                .thread => |thread| @ptrCast(thread),
                .native_function => |native| @ptrFromInt(@intFromEnum(native) + 1),
                else => null,
            };
            if (pointer == null) {
                try vm.appendFormatField(output, "(null)", width, std.mem.indexOfScalar(u8, flags, '-') != null, ' ');
                return;
            }
        }
        const is_integer = specifier == 'd' or specifier == 'i' or specifier == 'u' or specifier == 'o' or specifier == 'x' or specifier == 'X';
        var format_buffer: [64]u8 = undefined;
        var length: usize = 0;
        format_buffer[length] = '%';
        length += 1;
        @memcpy(format_buffer[length..][0..flags.len], flags);
        length += flags.len;
        if (width != 0) {
            const printed = std.fmt.bufPrint(format_buffer[length..], "{d}", .{width}) catch return error.RuntimeError;
            length += printed.len;
        }
        if (precision) |digits| {
            const printed = std.fmt.bufPrint(format_buffer[length..], ".{d}", .{digits}) catch return error.RuntimeError;
            length += printed.len;
        }
        if (is_integer) {
            format_buffer[length] = 'l';
            format_buffer[length + 1] = 'l';
            length += 2;
        }
        format_buffer[length] = specifier;
        length += 1;
        format_buffer[length] = 0;

        const capacity = 512 + width + (precision orelse 0);
        const buffer = vm.allocator.alloc(u8, capacity) catch return error.OutOfMemory;
        defer vm.allocator.free(buffer);
        const needed: c_int = if (is_integer) blk: {
            const integer = try intArgument(value);
            if (specifier == 'd' or specifier == 'i')
                break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&format_buffer), @as(c_longlong, integer));
            break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&format_buffer), @as(c_ulonglong, @bitCast(integer)));
        } else if (specifier == 'c') blk: {
            const integer = try intArgument(value);
            break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&format_buffer), @as(c_int, @truncate(integer)));
        } else if (specifier == 'p') blk: {
            const pointer: ?*const anyopaque = switch (value) {
                .string => |string| @ptrCast(string),
                .table => |table| @ptrCast(table),
                .function => |function| @ptrCast(function),
                .thread => |thread| @ptrCast(thread),
                .native_function => |native| @ptrFromInt(@intFromEnum(native) + 1),
                else => null,
            };
            break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&format_buffer), pointer.?);
        } else blk: {
            if (value != .number) return error.RuntimeError;
            break :blk snprintf(buffer.ptr, buffer.len, @ptrCast(&format_buffer), value.number.toFloat());
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

    fn singleNumber(vm: *VM, number: Number.Number) Error![]Value {
        return vm.allocator.dupe(Value, &.{.{ .number = number }}) catch return error.OutOfMemory;
    }

    fn utf8Char(vm: *VM, args: []const Value) Error![]Value {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(vm.allocator);
        for (args) |argument| {
            const integer = try intArgument(argument);
            const encoded = Utf8.encode(@as(u64, @bitCast(integer))) orelse return error.RuntimeError;
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

    fn utf8Source(args: []const Value, minimum: usize) Error![]const u8 {
        if (args.len < minimum or args[0] != .string) return error.RuntimeError;
        return args[0].string.slice();
    }

    fn utf8Len(vm: *VM, args: []const Value) Error![]Value {
        const source = try utf8Source(args, 1);
        const length = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const initial = if (args.len >= 2) try intArgument(args[1]) else 1;
        const final = if (args.len >= 3) try intArgument(args[2]) else -1;
        const start = utf8RelativePosition(initial, length);
        const end = utf8RelativePosition(final, length);
        if (start < 1 or start - 1 > length or end > length) return error.RuntimeError;
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
        const source = try utf8Source(args, 1);
        const length = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const initial = if (args.len >= 2) try intArgument(args[1]) else 1;
        const start = utf8RelativePosition(initial, length);
        const final = if (args.len >= 3) utf8RelativePosition(try intArgument(args[2]), length) else start;
        if (start < 1 or final > length) return error.RuntimeError;
        if (start > final) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const lax = args.len >= 4 and args[3].truthy();
        var values: std.ArrayList(Value) = .empty;
        errdefer values.deinit(vm.allocator);
        var position: usize = @intCast(start - 1);
        const end: usize = @intCast(final);
        while (position < end) {
            const decoded = Utf8.decode(source, position, lax) orelse return error.RuntimeError;
            values.append(vm.allocator, .{ .number = Number.Number.fromInt(decoded.codepoint) }) catch return error.OutOfMemory;
            position = decoded.next;
        }
        return values.toOwnedSlice(vm.allocator) catch return error.OutOfMemory;
    }

    fn utf8Offset(vm: *VM, args: []const Value) Error![]Value {
        const source = try utf8Source(args, 2);
        const n = try intArgument(args[1]);
        const length = std.math.cast(i64, source.len) orelse return error.RuntimeError;
        const default_position = if (n >= 0) @as(i64, 1) else length + 1;
        const one_based = utf8RelativePosition(if (args.len >= 3) try intArgument(args[2]) else default_position, length);
        if (one_based < 1 or one_based - 1 > length) return error.RuntimeError;
        var position: usize = @intCast(one_based - 1);
        var remaining = n;
        if (remaining == 0) {
            while (position > 0 and position < source.len and Utf8.isContinuation(source[position])) position -= 1;
        } else {
            if (position < source.len and Utf8.isContinuation(source[position])) return error.RuntimeError;
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

    fn utf8Codes(vm: *VM, args: []const Value) Error![]Value {
        const source = try utf8Source(args, 1);
        if (source.len > 0 and Utf8.isContinuation(source[0])) return error.RuntimeError;
        const state = try vm.newTable();
        state.set(.{ .string = vm.interner.intern("source") catch return error.OutOfMemory }, args[0]) catch return error.OutOfMemory;
        state.set(.{ .string = vm.interner.intern("lax") catch return error.OutOfMemory }, .{ .boolean = args.len >= 2 and args[1].truthy() }) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{ .{ .native_function = .utf8_codes_iterator }, .{ .table = state }, .{ .number = Number.Number.fromInt(0) } }) catch return error.OutOfMemory;
    }

    fn utf8CodesIterator(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .table) return error.RuntimeError;
        const source = args[0].table.get(.{ .string = vm.interner.intern("source") catch return error.OutOfMemory });
        if (source != .string) return error.RuntimeError;
        const control = try intArgument(args[1]);
        if (control < 0) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const bytes = source.string.slice();
        var position: usize = @intCast(control);
        while (position < bytes.len and Utf8.isContinuation(bytes[position])) position += 1;
        if (position >= bytes.len) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const lax_value = args[0].table.get(.{ .string = vm.interner.intern("lax") catch return error.OutOfMemory });
        const decoded = Utf8.decode(bytes, position, lax_value.truthy()) orelse return error.RuntimeError;
        if (decoded.next < bytes.len and Utf8.isContinuation(bytes[decoded.next])) return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{
            .{ .number = Number.Number.fromInt(std.math.cast(i64, position + 1) orelse return error.RuntimeError) },
            .{ .number = Number.Number.fromInt(decoded.codepoint) },
        }) catch return error.OutOfMemory;
    }

    fn mathAbs(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .number) return error.RuntimeError;
        const n = args[0].number;
        return singleNumber(vm, switch (n) {
            .int => |i| .{ .int = if (i < 0) 0 -% i else i },
            .float => |f| .{ .float = @abs(f) },
        });
    }

    fn mathRound(vm: *VM, args: []const Value, floor: bool) Error![]Value {
        if (args.len < 1 or args[0] != .number) return error.RuntimeError;
        const n = args[0].number;
        if (n == .int) return singleNumber(vm, n);
        const f = if (floor) @floor(n.float) else @ceil(n.float);
        if (Number.Number.fromFloat(f).toIntExact()) |integer| return singleNumber(vm, .{ .int = integer });
        return singleNumber(vm, .{ .float = f });
    }

    fn mathSqrt(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .number) return error.RuntimeError;
        return singleNumber(vm, .{ .float = @sqrt(args[0].number.toFloat()) });
    }

    fn mathFmod(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .number or args[1] != .number) return error.RuntimeError;
        if (args[0].number == .int and args[1].number == .int) {
            const divisor = args[1].number.int;
            if (divisor == 0) return vm.raisePlain("bad argument #2 to 'fmod' (zero)", .{});
            if (divisor == -1) return singleNumber(vm, .{ .int = 0 });
            return singleNumber(vm, .{ .int = @rem(args[0].number.int, divisor) });
        }
        return singleNumber(vm, .{ .float = @rem(args[0].number.toFloat(), args[1].number.toFloat()) });
    }

    fn mathMinMax(vm: *VM, args: []const Value, maximum: bool) Error![]Value {
        if (args.len == 0 or args[0] != .number) return error.RuntimeError;
        var best = args[0].number;
        for (args[1..]) |arg| {
            if (arg != .number) return error.RuntimeError;
            const less = Number.less(arg.number, best);
            const greater = Number.less(best, arg.number);
            if ((maximum and greater) or (!maximum and less)) best = arg.number;
        }
        return singleNumber(vm, best);
    }

    fn mathToInteger(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] == .nil) return vm.raisePlain("bad argument #1 to 'tointeger' (value expected)", .{});
        const number = arithmeticNumber(args[0]) orelse return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const integer = number.toIntExact() orelse return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        return singleNumber(vm, .{ .int = integer });
    }

    fn mathType(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1) return error.RuntimeError;
        const type_name = args[0].mathType() orelse return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const string = vm.interner.intern(type_name) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    const MathUnary = enum { sin, cos, tan, asin, acos, exp, deg, rad };

    fn mathUnary(vm: *VM, args: []const Value, op: MathUnary) Error![]Value {
        if (args.len < 1 or args[0] != .number) return error.RuntimeError;
        const x = args[0].number.toFloat();
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
        if (args.len < 1 or args[0] != .number or (args.len >= 2 and args[1] != .number)) return error.RuntimeError;
        const y = args[0].number.toFloat();
        const result = if (args.len == 2) std.math.atan2(y, args[1].number.toFloat()) else std.math.atan(y);
        return singleNumber(vm, .{ .float = result });
    }

    fn mathLog(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .number or (args.len >= 2 and args[1] != .number)) return error.RuntimeError;
        const x = args[0].number.toFloat();
        const result = if (args.len == 2) @log(x) / @log(args[1].number.toFloat()) else @log(x);
        return singleNumber(vm, .{ .float = result });
    }

    fn mathModf(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .number) return error.RuntimeError;
        const n = args[0].number;
        const values = vm.allocator.alloc(Value, 2) catch return error.OutOfMemory;
        switch (n) {
            .int => |integer| {
                values[0] = .{ .number = .{ .int = integer } };
                values[1] = .{ .number = .{ .float = 0 } };
            },
            .float => |float| {
                const integral = @trunc(float);
                values[0] = if (integral >= -9223372036854775808.0 and integral < 9223372036854775808.0)
                    .{ .number = .{ .int = @intFromFloat(integral) } }
                else
                    .{ .number = .{ .float = integral } };
                values[1] = .{ .number = .{ .float = if (float == integral) 0 else float - integral } };
            },
        }
        return values;
    }

    fn mathUlt(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2) return error.RuntimeError;
        const a = try intArgument(args[0]);
        const b = try intArgument(args[1]);
        const result: Value = .{ .boolean = @as(u64, @bitCast(a)) < @as(u64, @bitCast(b)) };
        return vm.allocator.dupe(Value, &.{result}) catch return error.OutOfMemory;
    }

    fn nextRandom(vm: *VM) u64 {
        return nextRandomState(&vm.rng_state);
    }

    fn mathRandom(vm: *VM, args: []const Value) Error![]Value {
        if (args.len > 2) return error.RuntimeError;
        try vm.tick();
        const sample = vm.nextRandom();
        if (args.len == 0) {
            const fraction = @as(f64, @floatFromInt(sample >> 11)) / 9007199254740992.0;
            return vm.singleNumber(.{ .float = fraction });
        }
        const low: i64 = if (args.len == 1) 1 else try intArgument(args[0]);
        const high: i64 = try intArgument(args[args.len - 1]);
        if (args.len == 1 and high == 0) return vm.singleNumber(.{ .int = @bitCast(sample) });
        if (low > high) return error.RuntimeError;
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
        const first = if (args.len == 0) @as(i64, 0x6c75616c697465) else try intArgument(args[0]);
        const second = if (args.len == 2) try intArgument(args[1]) else if (args.len == 0) @as(i64, 0x72616e646f6d) else 0;
        vm.rng_state = seedRandomState(@bitCast(first), @bitCast(second));
        return vm.allocator.dupe(Value, &.{ .{ .number = Number.Number.fromInt(first) }, .{ .number = Number.Number.fromInt(second) } }) catch return error.OutOfMemory;
    }

    fn dateField(vm: *VM, table: *Table, name: []const u8, default: ?i64) Error!i64 {
        const key = Value{ .string = vm.interner.intern(name) catch return error.OutOfMemory };
        const value = table.get(key);
        if (value == .nil) return default orelse error.RuntimeError;
        return intArgument(value);
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
            if (index >= format.len) return error.RuntimeError;
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
                else => return error.RuntimeError,
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

    fn osTime(vm: *VM, args: []const Value) Error![]Value {
        const io = vm.io orelse return error.RuntimeError;
        if (args.len == 0 or (args.len == 1 and args[0] == .nil)) return vm.singleNumber(.{ .int = std.Io.Clock.real.now(io).toSeconds() });
        if (args.len < 1 or args[0] != .table) return error.RuntimeError;
        const fields = args[0].table;
        const year = try vm.dateField(fields, "year", null);
        const month = try vm.dateField(fields, "month", null);
        const day = try vm.dateField(fields, "day", null);
        const hour = try vm.dateField(fields, "hour", 12);
        const minute = try vm.dateField(fields, "min", 0);
        const second = try vm.dateField(fields, "sec", 0);
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

    fn osDiffTime(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .number or args[1] != .number) return error.RuntimeError;
        const difference = args[0].number.toFloat() - args[1].number.toFloat();
        return vm.singleNumber(.{ .float = difference });
    }

    fn osGetEnv(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .string) return error.RuntimeError;
        const value = if (vm.environ_map) |environment| environment.get(args[0].string.slice()) else null;
        if (value) |bytes| {
            const string = vm.interner.intern(bytes) catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
        }
        return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
    }

    fn osDate(vm: *VM, args: []const Value) Error![]Value {
        if ((args.len >= 1 and args[0] != .string and args[0] != .nil) or (args.len >= 2 and args[1] != .number and args[1] != .nil)) return error.RuntimeError;
        const io = vm.io orelse return error.RuntimeError;
        const raw_format = if (args.len == 0 or args[0] == .nil) "%c" else args[0].string.slice();
        const utc = raw_format.len != 0 and raw_format[0] == '!';
        const format = if (utc) raw_format[1..] else raw_format;
        // This runtime currently uses UTC for both paths; `!` is accepted so
        // portable UTC date formatting works consistently on every host.
        const timestamp = if (args.len == 2 and args[1] != .nil)
            @as(i128, try intArgument(args[1]))
        else
            @as(i128, std.Io.Clock.real.now(io).toSeconds());
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
            .{ "DirNotEmpty", 39 },
        };
        inline for (mappings) |mapping| if (std.mem.eql(u8, error_name, mapping[0])) return mapping[1];
        return 1;
    }

    fn osFileFailure(vm: *VM, err: anyerror) Error![]Value {
        const error_name = @errorName(err);
        const message = vm.interner.intern(error_name) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{ .nil, .{ .string = message }, .{ .number = Number.Number.fromInt(osErrorCode(error_name)) } }) catch return error.OutOfMemory;
    }

    fn osRemove(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1 or args[0] != .string) return error.RuntimeError;
        const io = vm.io orelse return error.RuntimeError;
        const directory = std.Io.Dir.cwd();
        directory.deleteFile(io, args[0].string.slice()) catch |err| {
            if (err == error.IsDir) {
                directory.deleteDir(io, args[0].string.slice()) catch |dir_err| return vm.osFileFailure(dir_err);
                return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
            }
            return vm.osFileFailure(err);
        };
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
    }

    fn osRename(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .string or args[1] != .string) return error.RuntimeError;
        const io = vm.io orelse return error.RuntimeError;
        const directory = std.Io.Dir.cwd();
        directory.rename(args[0].string.slice(), directory, args[1].string.slice(), io) catch |err| return vm.osFileFailure(err);
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
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
        if (args.len == 0 or args[0] != .string or (args.len >= 2 and args[1] != .string)) return error.RuntimeError;
        const io = vm.io orelse return error.RuntimeError;
        const path = args[0].string.slice();
        const mode = if (args.len == 2) args[1].string.slice() else "r";
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
        if (!readable and !writable) return error.RuntimeError;
        const file = if (read_mode or read_update_mode)
            std.Io.Dir.cwd().openFile(io, path, .{ .mode = if (readable and writable) .read_write else .read_only }) catch |err| return vm.osFileFailure(err)
        else
            std.Io.Dir.cwd().createFile(io, path, .{ .read = readable, .truncate = write_mode or write_update_mode }) catch |err| return vm.osFileFailure(err);
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
                const stat = file.stat(io) catch |err| return vm.osFileFailure(err);
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

    fn ioWrite(vm: *VM, args: []const Value) Error![]Value {
        const table = vm.default_output orelse try vm.standardFile(false);
        const values = vm.allocator.alloc(Value, args.len + 1) catch return error.OutOfMemory;
        defer vm.allocator.free(values);
        values[0] = .{ .table = table };
        @memcpy(values[1..], args);
        return vm.fileWrite(values);
    }

    fn ioFlush(vm: *VM, args: []const Value) Error![]Value {
        _ = args;
        const table = vm.default_output orelse try vm.standardFile(false);
        return vm.fileFlush(&.{.{ .table = table }});
    }

    fn ioType(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1) return error.RuntimeError;
        if (args[0] != .table) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        for (vm.owned_files.items) |handle| if (handle.table == args[0].table) {
            const name = vm.interner.intern(if (handle.closed) "closed file" else "file") catch return error.OutOfMemory;
            return vm.allocator.dupe(Value, &.{.{ .string = name }}) catch return error.OutOfMemory;
        };
        return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
    }

    fn ioClose(vm: *VM, args: []const Value) Error![]Value {
        const file: Value = if (args.len == 1) args[0] else .{ .table = vm.default_output orelse try vm.standardFile(false) };
        return vm.fileClose(&.{file});
    }

    fn ioLines(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) {
            const table = vm.default_input orelse try vm.standardFile(true);
            return vm.fileLines(&.{.{ .table = table }});
        }
        if (args[0] != .string) return error.RuntimeError;
        const opened = try vm.ioOpen(&.{ args[0], .{ .string = vm.interner.intern("r") catch return error.OutOfMemory } });
        defer vm.allocator.free(opened);
        if (opened.len == 0 or opened[0] != .table) return error.RuntimeError;
        const file_args = vm.allocator.alloc(Value, args.len) catch return error.OutOfMemory;
        defer vm.allocator.free(file_args);
        file_args[0] = opened[0];
        @memcpy(file_args[1..], args[1..]);
        return vm.fileLines(file_args);
    }

    fn fileLines(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const handle = try vm.fileHandle(args[0]);
        if (handle.closed or !handle.readable) return error.RuntimeError;
        if (handle.owns_file) handle.auto_close = true;
        if (handle.line_formats) |old_formats| vm.allocator.free(old_formats);
        handle.line_formats = null;
        if (args.len > 1) {
            for (args[1..]) |format| if (format != .nil and format != .string and format != .number) return error.RuntimeError;
            handle.line_formats = vm.allocator.dupe(Value, args[1..]) catch return error.OutOfMemory;
        }
        return vm.allocator.dupe(Value, &.{ .{ .native_function = .file_lines_iterator }, args[0], .nil }) catch return error.OutOfMemory;
    }

    fn fileLinesIterator(vm: *VM, args: []const Value) Error![]Value {
        if (args.len != 2) return error.RuntimeError;
        const handle = try vm.fileHandle(args[0]);
        const formats = handle.line_formats orelse return vm.fileRead(&.{args[0]});
        const read_args = vm.allocator.alloc(Value, formats.len + 1) catch return error.OutOfMemory;
        defer vm.allocator.free(read_args);
        read_args[0] = args[0];
        @memcpy(read_args[1..], formats);
        return vm.fileRead(read_args);
    }

    fn standardFile(vm: *VM, input: bool) Error!*Table {
        const current = if (input) vm.default_input else vm.default_output;
        if (current) |table| return table;
        const io = vm.io orelse return error.RuntimeError;
        const table = try vm.newTable();
        table.metatable = vm.file_metatable;
        const handle = vm.allocator.create(FileHandle) catch return error.OutOfMemory;
        errdefer vm.allocator.destroy(handle);
        handle.* = .{
            .allocator = vm.allocator,
            .io = io,
            .file = if (input) std.Io.File.stdin() else std.Io.File.stdout(),
            .table = table,
            .readable = input,
            .writable = !input,
            .owns_file = false,
        };
        if (input) {
            handle.reader = handle.file.readerStreaming(io, &handle.reader_buffer);
        } else {
            handle.writer_interface = vm.writer orelse return error.RuntimeError;
        }
        vm.owned_files.append(vm.allocator, handle) catch return error.OutOfMemory;
        if (input) vm.default_input = table else vm.default_output = table;
        return table;
    }

    fn ioInput(vm: *VM, args: []const Value) Error![]Value {
        var table: *Table = undefined;
        if (args.len == 0) {
            table = try vm.standardFile(true);
        } else if (args[0] == .string) {
            const mode = Value{ .string = vm.interner.intern("r") catch return error.OutOfMemory };
            const opened = try vm.ioOpen(&.{ args[0], mode });
            defer vm.allocator.free(opened);
            if (opened.len == 0 or opened[0] != .table) return error.RuntimeError;
            table = opened[0].table;
        } else if (args[0] == .table) {
            const handle = vm.fileHandle(args[0]) catch return error.RuntimeError;
            if (handle.closed or !handle.readable) return error.RuntimeError;
            table = args[0].table;
        } else return error.RuntimeError;
        vm.default_input = table;
        return vm.allocator.dupe(Value, &.{.{ .table = table }}) catch return error.OutOfMemory;
    }

    fn ioOutput(vm: *VM, args: []const Value) Error![]Value {
        var table: *Table = undefined;
        if (args.len == 0) {
            table = try vm.standardFile(false);
        } else if (args[0] == .string) {
            const mode = Value{ .string = vm.interner.intern("w") catch return error.OutOfMemory };
            const opened = try vm.ioOpen(&.{ args[0], mode });
            defer vm.allocator.free(opened);
            if (opened.len == 0 or opened[0] != .table) return error.RuntimeError;
            table = opened[0].table;
        } else if (args[0] == .table) {
            const handle = vm.fileHandle(args[0]) catch return error.RuntimeError;
            if (handle.closed or !handle.writable) return error.RuntimeError;
            table = args[0].table;
        } else return error.RuntimeError;
        vm.default_output = table;
        return vm.allocator.dupe(Value, &.{.{ .table = table }}) catch return error.OutOfMemory;
    }

    fn ioRead(vm: *VM, args: []const Value) Error![]Value {
        const table = vm.default_input orelse try vm.standardFile(true);
        const file_args = vm.allocator.alloc(Value, args.len + 1) catch return error.OutOfMemory;
        defer vm.allocator.free(file_args);
        file_args[0] = .{ .table = table };
        @memcpy(file_args[1..], args);
        return vm.fileRead(file_args);
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

    fn fileClose(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const handle = try vm.fileHandle(args[0]);
        if (handle.closed) return error.RuntimeError;
        closeFileHandle(handle);
        return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
    }

    fn fileSeek(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const handle = try vm.fileHandle(args[0]);
        if (handle.closed or (!handle.readable and !handle.writable)) return error.RuntimeError;
        const whence = if (args.len >= 2) switch (args[1]) {
            .string => |string| string.slice(),
            else => return error.RuntimeError,
        } else "cur";
        const offset: i64 = if (args.len == 3) try intArgument(args[2]) else 0;
        const base: i128 = if (std.mem.eql(u8, whence, "set")) 0 else if (std.mem.eql(u8, whence, "cur"))
            if (handle.readable) handle.reader.?.logicalPos() else handle.writer.?.logicalPos()
        else if (std.mem.eql(u8, whence, "end")) (handle.file.stat(handle.io) catch return error.RuntimeError).size else return error.RuntimeError;
        const target_i128 = base + offset;
        if (target_i128 < 0 or target_i128 > std.math.maxInt(u64)) return error.RuntimeError;
        const target: u64 = @intCast(target_i128);
        if (handle.writer) |*writer| writer.seekTo(target) catch return error.RuntimeError;
        if (handle.reader) |*reader| reader.seekTo(target) catch return error.RuntimeError;
        return vm.singleNumber(.{ .int = @intCast(target) });
    }

    fn fileFlush(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1) return error.RuntimeError;
        const handle = try vm.fileHandle(args[0]);
        if (handle.closed or !handle.writable) return error.RuntimeError;
        if (handle.writer_interface) |writer| {
            writer.flush() catch return error.RuntimeError;
        } else handle.writer.?.interface.flush() catch return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{args[0]}) catch return error.OutOfMemory;
    }

    fn fileWrite(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2) return error.RuntimeError;
        const handle = try vm.fileHandle(args[0]);
        if (handle.closed or !handle.writable) return error.RuntimeError;
        const writer = handle.writer_interface orelse &handle.writer.?.interface;
        for (args[1..]) |value| {
            const bytes = switch (value) {
                .string => |string| string.slice(),
                .number => |number| vm.numberBytes(number),
                else => return error.RuntimeError,
            };
            writer.writeAll(bytes) catch return error.RuntimeError;
        }
        return vm.allocator.dupe(Value, &.{args[0]}) catch return error.OutOfMemory;
    }

    fn fileRead(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        if (args.len > 2) {
            var results: std.ArrayList(Value) = .empty;
            errdefer results.deinit(vm.allocator);
            for (args[1..]) |format| {
                const values = try vm.fileRead(&.{ args[0], format });
                defer vm.allocator.free(values);
                if (values.len == 0) return error.RuntimeError;
                results.append(vm.allocator, values[0]) catch return error.OutOfMemory;
                if (values[0] == .nil) break;
            }
            return results.toOwnedSlice(vm.allocator) catch return error.OutOfMemory;
        }
        const handle = try vm.fileHandle(args[0]);
        if (handle.closed or !handle.readable) return error.RuntimeError;
        const format = if (args.len == 1 or args[1] == .nil) "*l" else switch (args[1]) {
            .string => |string| string.slice(),
            .number => |number| vm.numberBytes(number),
            else => return error.RuntimeError,
        };
        var bytes: []u8 = undefined;
        var owned = false;
        if (std.mem.eql(u8, format, "*l") or std.mem.eql(u8, format, "*L")) {
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
                    if (format[1] == 'L') line.append(vm.allocator, '\n') catch return error.OutOfMemory;
                    break;
                }
                line.append(vm.allocator, byte[0]) catch return error.OutOfMemory;
            }
            if (!ended and line.items.len == 0) {
                if (handle.auto_close) closeFileHandle(handle);
                return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
            }
            bytes = vm.allocator.dupe(u8, line.items) catch return error.OutOfMemory;
            owned = true;
        } else if (std.mem.eql(u8, format, "*n")) {
            const reader = &handle.reader.?.interface;
            while (true) {
                const next = reader.peek(1) catch |err| switch (err) {
                    error.EndOfStream => {
                        if (handle.auto_close) closeFileHandle(handle);
                        return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
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
                return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
            };
            return vm.allocator.dupe(Value, &.{.{ .number = number }}) catch return error.OutOfMemory;
        } else if (std.mem.eql(u8, format, "*a")) {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(vm.allocator);
            const reader = &handle.reader.?.interface;
            while (true) {
                var chunk_buffer: [1024]u8 = undefined;
                const chunk_len = reader.readSliceShort(&chunk_buffer) catch return error.RuntimeError;
                if (chunk_len == 0) break;
                const chunk = chunk_buffer[0..chunk_len];
                output.appendSlice(vm.allocator, chunk) catch return error.OutOfMemory;
            }
            if (handle.auto_close) closeFileHandle(handle);
            bytes = vm.allocator.dupe(u8, output.items) catch return error.OutOfMemory;
            owned = true;
        } else {
            const count = std.fmt.parseInt(usize, format, 10) catch return error.RuntimeError;
            const reader = &handle.reader.?.interface;
            const buffer = vm.allocator.alloc(u8, count) catch return error.OutOfMemory;
            const actual = reader.readSliceShort(buffer) catch {
                vm.allocator.free(buffer);
                return error.RuntimeError;
            };
            if (actual == 0) {
                vm.allocator.free(buffer);
                if (handle.auto_close) closeFileHandle(handle);
                return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
            }
            bytes = buffer[0..actual];
            owned = true;
        }
        defer if (owned) vm.allocator.free(bytes);
        const string = vm.interner.intern(bytes) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn tableInsert(vm: *VM, args: []const Value) Error![]Value {
        if (args.len != 2 and args.len != 3) return error.RuntimeError;
        const table = switch (args[0]) {
            .table => |table| table,
            else => return error.RuntimeError,
        };
        const length: i64 = table.len();
        const position = if (args.len == 2) length + 1 else try intArgument(args[1]);
        if (position < 1 or position > length + 1) return error.RuntimeError;
        const value = args[if (args.len == 2) 1 else 2];
        var index = length + 1;
        while (index > position) : (index -= 1) {
            table.set(intKey(index), table.get(intKey(index - 1))) catch return error.OutOfMemory;
        }
        table.set(intKey(position), value) catch return error.OutOfMemory;
        return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
    }

    fn tableRemove(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const table = switch (args[0]) {
            .table => |table| table,
            else => return error.RuntimeError,
        };
        const length: i64 = table.len();
        const position = if (args.len == 1) length else try intArgument(args[1]);
        if (position < 1 or position > length) return vm.allocator.dupe(Value, &.{.nil}) catch return error.OutOfMemory;
        const removed = table.get(intKey(position));
        var index = position;
        while (index < length) : (index += 1) {
            table.set(intKey(index), table.get(intKey(index + 1))) catch return error.OutOfMemory;
        }
        table.set(intKey(length), .nil) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{removed}) catch return error.OutOfMemory;
    }

    fn tableConcat(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const table = switch (args[0]) {
            .table => |table| table,
            else => return error.RuntimeError,
        };
        const separator = if (args.len > 1) switch (args[1]) {
            .string => |string| string.slice(),
            else => return error.RuntimeError,
        } else "";
        const first = if (args.len > 2) try intArgument(args[2]) else @as(i64, 1);
        const last = if (args.len > 3) try intArgument(args[3]) else @as(i64, table.len());
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(vm.allocator);
        if (first <= last) {
            var index = first;
            while (true) : (index += 1) {
                try vm.tick();
                if (index != first) output.appendSlice(vm.allocator, separator) catch return error.OutOfMemory;
                const value = table.get(intKey(index));
                const bytes = switch (value) {
                    .string => |string| string.slice(),
                    .number => |number| Number.toBytes(number, &vm.number_buffer) catch return error.RuntimeError,
                    else => return error.RuntimeError,
                };
                output.appendSlice(vm.allocator, bytes) catch return error.OutOfMemory;
                if (index == last) break;
                if (index == std.math.maxInt(i64)) return error.RuntimeError;
            }
        }
        const string = vm.interner.intern(output.items) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{.{ .string = string }}) catch return error.OutOfMemory;
    }

    fn tableUnpack(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const table = switch (args[0]) {
            .table => |table| table,
            else => return error.RuntimeError,
        };
        const first = if (args.len > 1) try intArgument(args[1]) else @as(i64, 1);
        const last = if (args.len > 2) try intArgument(args[2]) else @as(i64, table.len());
        if (first > last) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
        const distance = std.math.sub(i64, last, first) catch return error.RuntimeError;
        const count = std.math.add(i64, distance, 1) catch return error.RuntimeError;
        const size = std.math.cast(usize, count) orelse return error.RuntimeError;
        if (size > vm.steps_left) return error.StepLimit;
        const values = vm.allocator.alloc(Value, size) catch return error.OutOfMemory;
        for (values, 0..) |*value, offset| {
            value.* = table.get(intKey(first + @as(i64, @intCast(offset))));
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
        if (args.len < 4 or args[0] != .table) return error.RuntimeError;
        const source = args[0].table;
        const first = try intArgument(args[1]);
        const last = try intArgument(args[2]);
        const target_first = try intArgument(args[3]);
        const destination = if (args.len == 5) switch (args[4]) {
            .table => |table| table,
            else => return error.RuntimeError,
        } else source;
        if (last < first) return vm.allocator.dupe(Value, &.{.{ .table = destination }}) catch return error.OutOfMemory;
        const count = std.math.cast(usize, @as(i128, last) - @as(i128, first) + 1) orelse return error.RuntimeError;
        const backwards = source == destination and target_first > first and target_first <= last;
        var offset: usize = 0;
        while (offset < count) : (offset += 1) {
            try vm.tick();
            const current_offset = if (backwards) count - offset - 1 else offset;
            const source_index = std.math.cast(i64, @as(i128, first) + @as(i128, current_offset)) orelse return error.RuntimeError;
            const destination_index = std.math.cast(i64, @as(i128, target_first) + @as(i128, current_offset)) orelse return error.RuntimeError;
            destination.set(intKey(destination_index), source.get(intKey(source_index))) catch return error.OutOfMemory;
        }
        return vm.allocator.dupe(Value, &.{.{ .table = destination }}) catch return error.OutOfMemory;
    }

    fn tableSort(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const table = switch (args[0]) {
            .table => |table| table,
            else => return error.RuntimeError,
        };
        const comparator: ?Value = if (args.len == 2 and args[1] != .nil) args[1] else null;
        if (comparator) |function| if (function != .function and function != .native_function) return error.RuntimeError;
        const length: usize = table.len();
        const values = vm.allocator.alloc(Value, length) catch return error.OutOfMemory;
        defer vm.allocator.free(values);
        for (values, 0..) |*value, i| value.* = table.getInt(@intCast(i + 1));
        for (1..values.len) |i| {
            const value = values[i];
            var insertion = i;
            while (insertion > 0 and try vm.tableSortLess(comparator, value, values[insertion - 1])) : (insertion -= 1) {
                values[insertion] = values[insertion - 1];
            }
            values[insertion] = value;
        }
        for (values, 0..) |value, i| table.set(intKey(@intCast(i + 1)), value) catch return error.OutOfMemory;
        return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
    }

    fn tableSortLess(vm: *VM, comparator: ?Value, left: Value, right: Value) Error!bool {
        if (comparator) |function| {
            const result = try vm.invokeCallableValues(function, &.{ left, right });
            defer vm.allocator.free(result);
            return result.len != 0 and result[0].truthy();
        }
        return switch (left) {
            .number => |a| switch (right) {
                .number => |b| Number.less(a, b),
                else => error.RuntimeError,
            },
            .string => |a| switch (right) {
                .string => |b| std.mem.lessThan(u8, a.slice(), b.slice()),
                else => error.RuntimeError,
            },
            else => error.RuntimeError,
        };
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
        const old_locals = vm.locals;
        const old_function_index = vm.function_index;
        const old_returned = vm.returned;
        const old_goto_name = vm.goto_name;
        const old_upvalues = vm.upvalues;
        const old_varargs = vm.varargs;
        const old_environment = vm.active_environment;
        const old_semantics = vm.semantics;
        const saved_results = vm.results;
        const locals_root_start = vm.suspended_locals.items.len;
        const varargs_root_start = vm.suspended_varargs.items.len;
        const results_root_start = vm.suspended_results.items.len;
        const functions_root_start = vm.active_functions.items.len;
        errdefer {
            vm.suspended_locals.shrinkRetainingCapacity(locals_root_start);
            vm.suspended_varargs.shrinkRetainingCapacity(varargs_root_start);
            vm.suspended_results.shrinkRetainingCapacity(results_root_start);
            vm.active_functions.shrinkRetainingCapacity(functions_root_start);
        }
        vm.suspended_locals.append(vm.allocator, old_locals) catch return error.OutOfMemory;
        vm.suspended_varargs.append(vm.allocator, old_varargs) catch return error.OutOfMemory;
        vm.suspended_results.append(vm.allocator, saved_results.items) catch return error.OutOfMemory;
        vm.active_functions.append(vm.allocator, function) catch return error.OutOfMemory;
        vm.error_frames.append(vm.allocator, .{ .program = function.semantics, .call_offset = vm.error_offset }) catch return error.OutOfMemory;
        defer _ = vm.error_frames.pop();
        const called_semantics = function.semantics;
        const frame_size = called_semantics.functions[function.function_index].frame_size;
        const new_locals = try vm.allocFrame(frame_size);
        const parameter_count = called_semantics.functions[function.function_index].parameters.len;
        vm.semantics = called_semantics;
        vm.results = .empty;
        vm.returned = false;
        vm.goto_name = null;
        vm.function_index = function.function_index;
        vm.locals = new_locals;
        vm.upvalues = function.captures;
        vm.active_environment = function.environment;
        vm.varargs = if (vm.semantics.functions[function.function_index].is_vararg and argument_values.len > parameter_count) argument_values[parameter_count..] else &.{};
        defer {
            vm.results.deinit(vm.allocator);
            vm.results = saved_results;
            vm.locals = old_locals;
            vm.function_index = old_function_index;
            vm.returned = old_returned;
            vm.goto_name = old_goto_name;
            vm.upvalues = old_upvalues;
            vm.varargs = old_varargs;
            vm.active_environment = old_environment;
            vm.semantics = old_semantics;
            vm.suspended_locals.shrinkRetainingCapacity(locals_root_start);
            vm.suspended_varargs.shrinkRetainingCapacity(varargs_root_start);
            vm.suspended_results.shrinkRetainingCapacity(results_root_start);
            vm.active_functions.shrinkRetainingCapacity(functions_root_start);
        }
        for (0..parameter_count) |i| {
            vm.locals[i].value = if (i < argument_values.len) argument_values[i] else .nil;
        }
        vm.gc_deferral_depth += 1;
        defer vm.gc_deferral_depth -= 1;
        try vm.execBlock(&function.body.block);
        return vm.allocator.dupe(Value, vm.results.items) catch return error.OutOfMemory;
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

    fn basePrint(vm: *VM, args: []const Value) Error![]Value {
        const writer = vm.writer orelse return error.RuntimeError;
        for (args, 0..) |value, i| {
            if (i != 0) writer.writeByte('\t') catch return error.RuntimeError;
            try vm.writeValue(writer, value);
        }
        writer.writeByte('\n') catch return error.RuntimeError;
        return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
    }

    fn baseWarn(vm: *VM, args: []const Value) Error![]Value {
        if (args.len != 0 and args.len == 1) {
            const message = switch (args[0]) {
                .string => |string| string.slice(),
                .number => vm.numberBytes(args[0].number),
                else => return error.RuntimeError,
            };
            if (message.len > 0 and message[0] == '@') {
                if (std.mem.eql(u8, message, "@on")) vm.warn_state = .ready else if (std.mem.eql(u8, message, "@off")) vm.warn_state = .off;
                return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
            }
        }
        if (args.len == 0 or vm.warn_state == .off) return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
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

    fn baseCollectGarbage(vm: *VM, args: []const Value) Error![]Value {
        const option = if (args.len == 0) "collect" else switch (args[0]) {
            .string => |string| string.slice(),
            else => return error.RuntimeError,
        };
        if (!std.mem.eql(u8, option, "step") and args.len > 1) return error.RuntimeError;
        if (std.mem.eql(u8, option, "collect")) {
            vm.gc_pending = true;
            return vm.allocator.alloc(Value, 0) catch return error.OutOfMemory;
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
            if (args.len == 2 and try intArgument(args[1]) < 0) return error.RuntimeError;
            vm.gc_pending = true;
            return vm.allocator.dupe(Value, &.{.{ .boolean = true }}) catch return error.OutOfMemory;
        }
        return error.RuntimeError;
    }

    fn collectAtSafePoint(vm: *VM) Error!void {
        // An interpreted call can be nested inside expression evaluation, where
        // callers still hold values only in Zig locals. Defer sweeping until the
        // outermost script statement has finished evaluating those temporaries.
        if (!vm.gc_pending or vm.gc_deferral_depth != 0) return;
        var roots: std.ArrayList(Value) = .empty;
        defer roots.deinit(vm.allocator);
        try roots.append(vm.allocator, .{ .table = vm.globals });
        try roots.append(vm.allocator, vm.global_environment.value);
        try roots.append(vm.allocator, vm.active_environment.value);
        if (vm.string_metatable) |metatable| try roots.append(vm.allocator, .{ .table = metatable });
        if (vm.default_input) |table| try roots.append(vm.allocator, .{ .table = table });
        if (vm.default_output) |table| try roots.append(vm.allocator, .{ .table = table });
        for (vm.locals) |cell| try roots.append(vm.allocator, cell.value);
        for (vm.suspended_locals.items) |frame| for (frame) |cell| try roots.append(vm.allocator, cell.value);
        for (vm.upvalues) |cell| try roots.append(vm.allocator, cell.value);
        for (vm.varargs) |value| try roots.append(vm.allocator, value);
        for (vm.suspended_varargs.items) |values| for (values) |value| try roots.append(vm.allocator, value);
        for (vm.results.items) |value| try roots.append(vm.allocator, value);
        for (vm.suspended_results.items) |values| for (values) |value| try roots.append(vm.allocator, value);
        for (vm.close_values.items) |value| try roots.append(vm.allocator, value);
        if (vm.thrown_error) |value| try roots.append(vm.allocator, value);
        for (vm.active_functions.items) |function| try roots.append(vm.allocator, .{ .function = function });
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
        if (args.len < 1) return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{.{ .string = vm.interner.intern(args[0].typeName()) catch return error.OutOfMemory }}) catch return error.OutOfMemory;
    }

    fn baseLoad(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0 or args[0] != .string) return error.RuntimeError;
        if (args.len > 2 and args[2] != .nil and args[2] != .string) return vm.loadFailure("bad argument #3 to 'load' (string expected)");
        if (args.len > 2 and args[2] == .string) {
            const mode = args[2].string.slice();
            if (mode.len == 0 or (std.mem.indexOfScalar(u8, mode, 'b') == null and std.mem.indexOfScalar(u8, mode, 't') == null)) return vm.loadFailure("invalid mode");
            for (mode) |byte| if (byte != 'b' and byte != 't') return vm.loadFailure("invalid mode");
            if (std.mem.indexOfScalar(u8, mode, 'b') != null and std.mem.indexOfScalar(u8, mode, 't') == null) {
                return vm.loadFailure("attempt to load a binary chunk (mode is 't')");
            }
        }

        const chunk_name = if (args.len > 1 and args[1] == .string) args[1].string.slice() else "=(load)";
        const source = args[0].string.slice();
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
                arena_ptr.deinit();
                vm.allocator.destroy(arena_ptr);
                arena_transferred = true;
                return vm.loadFailureIn(chunk_name);
            },
        };
        const semantics = arena.create(Semantic.Program) catch return error.OutOfMemory;
        semantics.* = Semantic.analyze(arena, &diagnostics, &chunk) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReportFailed => {
                arena_ptr.deinit();
                vm.allocator.destroy(arena_ptr);
                arena_transferred = true;
                return vm.loadFailureIn(chunk_name);
            },
        };
        semantics.source = owned_source;
        semantics.chunk_name = arena.dupe(u8, chunk_name) catch return error.OutOfMemory;
        if (diagnostics.errors.items.len != 0) {
            arena_ptr.deinit();
            vm.allocator.destroy(arena_ptr);
            arena_transferred = true;
            return vm.loadFailureIn(chunk_name);
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
        vm.owned_functions.append(vm.allocator, function) catch {
            vm.tracker.free(function);
            return error.OutOfMemory;
        };
        return vm.allocator.dupe(Value, &.{.{ .function = function }}) catch return error.OutOfMemory;
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
            const message = std.fmt.allocPrint(vm.allocator, "cannot open {s}: {t}", .{ filename, err }) catch return error.OutOfMemory;
            defer vm.allocator.free(message);
            return vm.loadFailure(message);
        } else blk: {
            var buffer: [4096]u8 = undefined;
            var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
            break :blk reader.interface.allocRemaining(vm.allocator, .unlimited) catch return vm.loadFailure("cannot read stdin");
        };
        defer vm.allocator.free(source);
        const name = vm.interner.intern(path orelse "=stdin") catch return error.OutOfMemory;
        const mode: Value = if (args.len > 1) args[1] else .nil;
        const environment: Value = if (args.len > 2) args[2] else .nil;
        return vm.baseLoad(&.{ .{ .string = vm.interner.intern(source) catch return error.OutOfMemory }, .{ .string = name }, mode, environment });
    }

    fn baseDoFile(vm: *VM, args: []const Value) Error![]Value {
        const loaded = try vm.baseLoadFile(args);
        defer vm.allocator.free(loaded);
        if (loaded.len == 0 or loaded[0] == .nil) {
            vm.thrown_error = if (loaded.len > 1) loaded[1] else .{ .string = vm.interner.intern("cannot load file") catch return error.OutOfMemory };
            return error.RuntimeError;
        }
        return vm.invokeCallableValues(loaded[0], &.{});
    }

    fn baseToString(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1) return error.RuntimeError;
        const value = args[0];
        if (value == .string) return vm.allocator.dupe(Value, &.{value}) catch return error.OutOfMemory;
        if (value == .table) {
            const method = try vm.metamethod(value.table, "__tostring");
            if (method != .nil) {
                const returned = try vm.invokeCallableValues(method, &.{value});
                defer vm.allocator.free(returned);
                if (returned.len == 0 or returned[0] != .string) return error.RuntimeError;
                return vm.allocator.dupe(Value, &.{returned[0]}) catch return error.OutOfMemory;
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
        _ = vm;
        return switch (value) {
            .nil => "nil",
            .boolean => |boolean| if (boolean) "true" else "false",
            .number => |number| Number.toBytes(number, buffer) catch return error.RuntimeError,
            .string => |string| string.slice(),
            .table => |table| std.fmt.bufPrint(buffer, "table: 0x{x}", .{@intFromPtr(table)}) catch return error.RuntimeError,
            .function => |function| std.fmt.bufPrint(buffer, "function: 0x{x}", .{@intFromPtr(function)}) catch return error.RuntimeError,
            // a native function has no pointer of its own, so its ordinal
            // stands in for the C function address `%p` would print
            .native_function => |native| std.fmt.bufPrint(buffer, "function: 0x{d}", .{@intFromEnum(native) + 1}) catch return error.RuntimeError,
            .thread => |thread| std.fmt.bufPrint(buffer, "thread: 0x{x}", .{@intFromPtr(thread)}) catch return error.RuntimeError,
        };
    }

    fn baseToNumber(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        const result: Value = if (args.len == 1 and args[0] == .number) args[0] else if (args[0] == .string) blk: {
            const bytes = std.mem.trim(u8, args[0].string.slice(), " \t\r\n\x0b\x0c");
            if (args.len == 1) break :blk if (Number.parse(bytes)) |number| .{ .number = number } else .nil;
            const base = try intArgument(args[1]);
            if (base < 2 or base > 36) return error.RuntimeError;
            const integer = std.fmt.parseInt(i64, bytes, @intCast(base)) catch break :blk .nil;
            break :blk .{ .number = Number.Number.fromInt(integer) };
        } else .nil;
        return vm.allocator.dupe(Value, &.{result}) catch return error.OutOfMemory;
    }

    fn baseAssert(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0 or !args[0].truthy()) {
            vm.thrown_error = if (args.len > 1) args[1] else .{ .string = vm.interner.intern("assertion failed!") catch return error.OutOfMemory };
            return error.RuntimeError;
        }
        return vm.allocator.dupe(Value, args) catch return error.OutOfMemory;
    }

    /// Raises a runtime error the way `luaG_runerror` does: the message gains
    /// the current `chunk:line: ` prefix and becomes the value `pcall` hands
    /// back. `raisePlain` is for the API-style errors (`bad argument #1 ...`)
    /// that the reference reports without a position.
    fn raise(vm: *VM, comptime fmt: []const u8, args: anytype) Error {
        var detail_buffer: [256]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buffer, fmt, args) catch fmt;
        var position_buffer: [192]u8 = undefined;
        const raised_by_native = vm.error_frames.items.len != 0 and vm.error_frames.items[vm.error_frames.items.len - 1].program == null;
        const position = if (raised_by_native)
            vm.nativeRaisePosition(&position_buffer) catch null
        else
            vm.currentLuaPosition(&position_buffer) catch null;
        const message = if (position) |p|
            std.fmt.allocPrint(vm.allocator, "{s}{s}", .{ p, detail }) catch return error.OutOfMemory
        else
            vm.allocator.dupe(u8, detail) catch return error.OutOfMemory;
        defer vm.allocator.free(message);
        vm.thrown_error = .{ .string = vm.interner.intern(message) catch return error.OutOfMemory };
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
        vm.thrown_error = .{ .string = vm.interner.intern(detail) catch return error.OutOfMemory };
        return error.RuntimeError;
    }

    fn baseError(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) {
            vm.thrown_error = .nil;
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
        vm.thrown_error = message;
        return error.RuntimeError;
    }

    /// `chunk:line: ` for the function `level` frames up, or null where the
    /// reference would push the empty string. Levels count Lua functions only;
    /// a native caller has no position to give.
    fn errorPosition(vm: *VM, level: i64, buffer: *[192]u8) Error!?[]const u8 {
        if (level < 1) return null;
        const depth = std.math.cast(usize, level) orelse return null;
        const count = vm.error_frames.items.len;
        if (count == 0 or depth >= count) return null;
        // level counts activations above the one raising the error, and the
        // activation above frame `index` is what holds its call site
        const index = count - 1 - depth;
        const frame = vm.error_frames.items[index];
        const program = frame.program orelse return null;
        const offset = vm.error_frames.items[index + 1].call_offset;
        if (offset == null or program.source.len == 0) return null;
        const line = lineAt(program.source, offset.?);
        var name_buffer: [64]u8 = undefined;
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
        const frames = vm.error_frames.items;
        if (frames.len < 2) return null;
        const program = frames[frames.len - 2].program orelse return null;
        const offset = frames[frames.len - 1].call_offset orelse return null;
        if (program.source.len == 0) return null;
        const line = lineAt(program.source, offset);
        var name_buffer: [64]u8 = undefined;
        const name = shortSource(&name_buffer, program.chunk_name);
        return std.fmt.bufPrint(buffer, "{s}:{d}: ", .{ name, line }) catch return error.RuntimeError;
    }

    fn currentLuaPosition(vm: *VM, buffer: *[192]u8) Error!?[]const u8 {
        var index: usize = vm.error_frames.items.len;
        while (index > 0) {
            index -= 1;
            const program = vm.error_frames.items[index].program orelse continue;
            if (vm.error_offset == null or program.source.len == 0) return null;
            const line = lineAt(program.source, vm.error_offset.?);
            var name_buffer: [64]u8 = undefined;
            const name = shortSource(&name_buffer, program.chunk_name);
            return std.fmt.bufPrint(buffer, "{s}:{d}: ", .{ name, line }) catch return error.RuntimeError;
        }
        return null;
    }

    fn baseSelect(vm: *VM, args: []const Value) Error![]Value {
        if (args.len == 0) return error.RuntimeError;
        if (args[0] == .string and std.mem.eql(u8, args[0].string.slice(), "#")) {
            return vm.allocator.dupe(Value, &.{.{ .number = Number.Number.fromInt(std.math.cast(i64, args.len - 1) orelse return error.RuntimeError) }}) catch return error.OutOfMemory;
        }
        const selector = try intArgument(args[0]);
        const start: usize = if (selector > 0)
            @min(std.math.cast(usize, selector) orelse return error.RuntimeError, args.len)
        else if (selector < 0) blk: {
            if (selector == std.math.minInt(i64)) return error.RuntimeError;
            const offset = std.math.cast(usize, -selector) orelse return error.RuntimeError;
            if (offset > args.len - 1) return error.RuntimeError;
            break :blk args.len - offset;
        } else return error.RuntimeError;
        return vm.allocator.dupe(Value, args[start..]) catch return error.OutOfMemory;
    }

    fn baseRawequal(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2) return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{.{ .boolean = args[0].equal(args[1]) }}) catch return error.OutOfMemory;
    }

    fn baseRawGet(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .table) return error.RuntimeError;
        return vm.allocator.dupe(Value, &.{args[0].table.get(args[1])}) catch return error.OutOfMemory;
    }

    fn baseRawSet(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 3 or args[0] != .table) return error.RuntimeError;
        args[0].table.set(args[1], args[2]) catch return error.OutOfMemory;
        return vm.allocator.dupe(Value, &.{args[0]}) catch return error.OutOfMemory;
    }

    fn baseRawLen(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1) return error.RuntimeError;
        const length: i64 = switch (args[0]) {
            .string => |string| std.math.cast(i64, string.slice().len) orelse return error.RuntimeError,
            .table => |table| table.len(),
            else => return error.RuntimeError,
        };
        return vm.allocator.dupe(Value, &.{.{ .number = Number.Number.fromInt(length) }}) catch return error.OutOfMemory;
    }

    fn baseSetMetatable(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 2 or args[0] != .table) return error.RuntimeError;
        const table = args[0].table;
        if (table.metatable) |metatable| if (metatable.get(.{ .string = vm.interner.intern("__metatable") catch return error.OutOfMemory }) != .nil)
            return vm.raisePlain("cannot change a protected metatable", .{});
        table.metatable = if (args[1] == .table) args[1].table else null;
        return vm.allocator.dupe(Value, &.{args[0]}) catch return error.OutOfMemory;
    }

    fn baseGetMetatable(vm: *VM, args: []const Value) Error![]Value {
        if (args.len < 1) return error.RuntimeError;
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
        try vm.putNative(library, "exit", .os_exit);
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
        metatable.set(.{ .string = vm.interner.intern("__index") catch return error.OutOfMemory }, .{ .table = methods }) catch return error.OutOfMemory;
        try vm.putNative(metatable, "__close", .file_close);
        try vm.putNative(metatable, "__gc", .file_close);
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

    fn getTableIndex(vm: *VM, receiver: Value, key: Value) Error!Value {
        return vm.getTableIndexDepth(receiver, key, 0);
    }

    fn getTableIndexDepth(vm: *VM, receiver: Value, key: Value, depth: usize) Error!Value {
        if (depth >= 200) return error.RuntimeError;
        if (receiver == .table) {
            const value = receiver.table.get(key);
            if (value != .nil) return value;
        }
        const index = try vm.valueMetamethod(receiver, "__index");
        if (index == .nil) return if (receiver == .table) .nil else error.RuntimeError;
        return switch (index) {
            .function, .native_function => blk: {
                const values = try vm.invokeCallableValues(index, &.{ receiver, key });
                defer vm.allocator.free(values);
                break :blk if (values.len == 0) .nil else values[0];
            },
            else => vm.getTableIndexDepth(index, key, depth + 1),
        };
    }

    fn setTableIndex(vm: *VM, receiver: Value, key: Value, value: Value) Error!void {
        return vm.setTableIndexDepth(receiver, key, value, 0);
    }

    fn setTableIndexDepth(vm: *VM, receiver: Value, key: Value, value: Value, depth: usize) Error!void {
        if (depth >= 200) return error.RuntimeError;
        if (receiver == .table) {
            if (receiver.table.get(key) != .nil) {
                receiver.table.set(key, value) catch return error.OutOfMemory;
                return;
            }
        }
        const newindex = try vm.valueMetamethod(receiver, "__newindex");
        if (newindex == .nil) {
            if (receiver != .table) return error.RuntimeError;
            receiver.table.set(key, value) catch return error.OutOfMemory;
        } else {
            switch (newindex) {
                .function, .native_function => {
                    const values = try vm.invokeCallableValues(newindex, &.{ receiver, key, value });
                    vm.allocator.free(values);
                },
                else => try vm.setTableIndexDepth(newindex, key, value, depth + 1),
            }
        }
    }

    fn evalTableConstructor(vm: *VM, constructor: *const Ast.TableConstructor) Error!Value {
        const table = try vm.newTable();
        var list_values: std.ArrayList(Value) = .empty;
        defer list_values.deinit(vm.allocator);
        var next: i64 = 1;
        for (constructor.fields, 0..) |field, field_index| switch (field) {
            .expression => |item| {
                const is_last = field_index + 1 == constructor.fields.len;
                if (is_last) switch (item.expression) {
                    .vararg => {
                        for (vm.varargs) |value| {
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
            .indexed => |item| table.set(try vm.eval(item.key), try vm.eval(item.value)) catch return error.OutOfMemory,
        };
        for (list_values.items) |value| {
            table.set(.{ .number = .{ .int = next } }, value) catch return error.OutOfMemory;
            next += 1;
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

    fn numberValue(vm: *VM, expr: Ast.Expression) Error!Number.Number {
        return switch (try vm.eval(expr)) {
            .number => |number| number,
            .string => |string| Number.parse(string.slice()) orelse return error.RuntimeError,
            else => error.RuntimeError,
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
            .string => |node| return std.fmt.bufPrint(buffer, " (constant '{s}')", .{node.value}) catch "",
            .variable => |variable| switch (variable.*) {
                .name => |name| {
                    const kind: []const u8 = switch (vm.semantics.resolutions.get(name.span.start) orelse .global) {
                        .local => "local",
                        .upvalue => "upvalue",
                        .global => "global",
                    };
                    return std.fmt.bufPrint(buffer, " ({s} '{s}')", .{ kind, name.name }) catch "";
                },
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
        if (left != .table or right != .table) return false;
        const left_method = try vm.metamethod(left.table, "__eq");
        const right_method = try vm.metamethod(right.table, "__eq");
        if (left_method == .nil or !left_method.equal(right_method)) return false;
        const results = try vm.invokeCallableValues(left_method, &.{ left, right });
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
        return if (negate_result) .{ .boolean = !result.truthy() } else result;
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
    try testing.expect(values[12] == .boolean and !values[12].boolean);
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
    var parser = Parser.fromSource("math.randomseed(123, 456); local a = math.random(); local x = math.random(10); local y = math.random(-5, 5); math.randomseed(123, 456); local b = math.random(); local seed1, seed2 = math.randomseed(); local full = math.random(0); local wide = math.random(-9223372036854775808, 9223372036854775807); return a == b, x >= 1 and x <= 10, y >= -5 and y <= 5, a >= 0 and a < 1, seed1 == 0x6c75616c697465, seed2 == 0x72616e646f6d, math.type(full) == 'integer', math.type(wide) == 'integer'", &arena, &reporter);
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
        \\assert(io.type(f) == "closed file")
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
