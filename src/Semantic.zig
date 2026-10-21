const std = @import("std");

const Token = @import("Token.zig");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");
const Parser = @import("Parser.zig");

const Statement = @import("Semantic/Statement.zig");
const Expression = @import("Semantic/Expression.zig");

pub const Semantic = @This();

// Semantic analysis only ever fails on allocation. Every check reports and
// carries on, since an out of scope name says nothing about the rest of the
// chunk, and a caller wants every error in a file rather than the first
pub const Error = error{
    OutOfMemory,
    ReportFailed,
};

// Lua's own caps, from lparser.c and lfunc.h. These are Lua's constants rather
// than counts, so they stay narrow: a chunk that goes past one is refused, and the
// slots and frame sizes below keep counting well past it.
pub const max_locals: u16 = 200;
pub const max_upvalues: u16 = 255;

// What a chunk resolves to: the scopes it opens, the locals and upvalues in
// them, and where every name it wrote went. Names borrow from the source and
// everything else is arena allocated, so both have to outlive this.
pub const Program = struct {
    // the chunk is functions[0]
    functions: []const Function,
    // the outermost scope, which is the chunk itself
    body: *BlockScope,
    // where each name resolved to, keyed by the offset the name starts at. Every
    // name in a chunk has a span of its own, so the offset says which one
    resolutions: Resolutions,
    // The lexical `_ENV` binding used when each free name is read or written.
    environment_resolutions: Resolutions,
    // one per function body in the chunk, keyed the same way
    definitions: std.AutoHashMapUnmanaged(u32, Definition) = .empty,
    // The text the spans point into and the name the chunk was loaded under,
    // filled in by whoever compiled it. The parser walks the source but does
    // not keep it, and the runtime needs both to say where an error() call is.
    source: []const u8 = &.{},
    chunk_name: []const u8 = &.{},

    pub const Resolutions = std.AutoHashMapUnmanaged(u32, Resolution);

    // the slot a name resolved to, when it is a local of the function it was
    // written in
    pub fn localSlot(program: *const Program, name: Ast.Identifier) ?u32 {
        return switch (program.resolutions.get(name.span.start) orelse return null) {
            .local => |slot| slot,
            .upvalue, .global => null,
        };
    }
};

// where a name that is read or written turns out to live
pub const Resolution = union(enum) {
    // a slot in the frame of the function it was written in
    local: u32,
    // a slot in the closure that function makes, filled from a frame or an
    // upvalue of the function around it
    upvalue: u32,
    // nothing to resolve to, which is a global read or write
    global,
};

// the frame a nested function needs, given to the runtime when it is created
pub const Definition = struct {
    // the index of the function this body makes
    function: u32,
    span: Token.Span,
};

// One function, the chunk included. Parameters are locals of slots 0 to
// `parameters.len - 1`; every local past them was declared in the body.
pub const Function = struct {
    // the function this one is written inside, absent for the chunk
    parent: ?u32,
    parameters: []const Parameter,
    is_vararg: bool,
    // in the order they were first captured, which is the order the closure
    // built from this function has to fill its upvalues in
    upvalues: []const Upvalue,
    body: *BlockScope,
    // how many slots the frame needs live at once
    frame_size: u32,
    // which slots are read by a nested function. Those are the ones the
    // runtime gives a fresh cell on every (re)declaration, which is what makes
    // each turn of a loop capture its own variables.
    captured_slots: []const bool,
};

pub const Parameter = struct {
    name: []const u8,
    span: Token.Span,
};

// where a nested function reads a name from in the function around it
pub const Upvalue = union(enum) {
    // a slot in the parent's frame
    parent_local: u32,
    // an upvalue of the parent, one hop further out
    parent_upvalue: u32,
};

// A block. Blocks nest, and a name is visible from where it is written until the
// innermost block that declared it closes.
pub const BlockScope = struct {
    parent: ?*BlockScope,
    // which function this block is written in
    function: u32,
    // how many locals of that function were in scope where this block opened.
    // Its own locals begin here, and closing the block hands them back.
    n_actvar: u32,
    // whether a `break` written in here would have a loop to leave
    is_loop: bool,

    // what the block declared, and the labels written in it. Both are filled in
    // as it closes, from the function's live locals and its own label list.
    locals: []const Local = &.{},
    labels: []const Label = &.{},

    // the blocks opened inside this one, in source order, which preserves the
    // function's lexical structure for runtime and diagnostics
    children: []const *BlockScope = &.{},

    child_items: std.ArrayList(*BlockScope) = .empty,
    label_items: std.ArrayList(Label) = .empty,
};

pub const Local = struct {
    name: []const u8,
    span: Token.Span,
    // the slot this local occupies. Blocks close by handing their slots back, so
    // a name is a slot together with the block that holds it, never a slot alone
    slot: u32,
    // `<const>`, which nothing may be assigned to
    is_const: bool,
    // a nested function reads this local, so its slot may not be reused while a
    // closure can still see it. The runtime retains its cell while closures hold
    // references to it.
    is_captured: bool,
};

pub const Label = struct {
    name: []const u8,
    span: Token.Span,
    // how many locals were in scope where the label sits, which is what a goto
    // written against it is measured by
    n_actvar: u32,
    // the token after the closing `::`, which is where the reference's checks
    // on a label stop, so a refusal about it names that line
    after_span: Token.Span,
};

// a `goto` that no label has claimed yet. Gotos may name a label written later in
// the same block, so one is held until a label of that name turns up or until its
// block closes and it is carried out to the block around it.
const Goto = struct {
    name: []const u8,
    span: Token.Span,
    // how many locals were in scope where the goto was written
    n_actvar: u32,
    // the block the goto belongs to. Moving it outward as blocks close is what
    // stops a goto reaching a label in a block it is not written in.
    scope: *BlockScope,
    // set once a label has claimed it, so a claimed goto is neither carried
    // outward nor reported as having no label
    resolved: bool = false,
};

// the state of one function while the walk is inside it
const FuncState = struct {
    arena: std.mem.Allocator,
    index: u32,
    parent: ?*FuncState,
    // the root scope of this function, the one whose parent is null
    root: *BlockScope,
    is_vararg: bool,

    // every local of this function in scope right now, indexed by slot. A scope
    // closes by truncating this back to its own count, which is what frees a
    // slot for whatever is declared next in an outer block.
    active: std.ArrayList(Local) = .empty,
    // the most slots live at once, which is what the frame has to be
    max_actvar: u32 = 0,

    upvalues: std.ArrayList(Upvalue) = .empty,
    // slots of this function that some nested function captured, for the
    // frame-sized flag array handed to the runtime
    captured: std.ArrayList(u32) = .empty,
    // every goto written so far that no label has claimed
    pending: std.ArrayList(*Goto) = .empty,

    // filled in as the walk enters and leaves
    parameters: std.ArrayList(Parameter) = .empty,
    // the chunk takes `...` and has no parameter list
    body_span: Token.Span,
};

arena: std.mem.Allocator,
reporter: *Diagnostic.Reporter,
functions: std.ArrayList(Function) = .empty,
resolutions: std.AutoHashMapUnmanaged(u32, Resolution) = .empty,
environment_resolutions: std.AutoHashMapUnmanaged(u32, Resolution) = .empty,
definitions: std.AutoHashMapUnmanaged(u32, Definition) = .empty,
// the scope being walked, and the function it is in. Both are set by
// enterFunction and restored by leaveFunction, and are only ever read while a
// walk is inside a function, which the statement and expression walks are
scope: *BlockScope,
function: *FuncState,

pub fn analyze(
    arena: std.mem.Allocator,
    reporter: *Diagnostic.Reporter,
    chunk: *const Ast.Chunk,
) Error!Program {
    var semantic: Semantic = .{
        .arena = arena,
        .reporter = reporter,
        .scope = undefined,
        .function = undefined,
    };

    // the chunk is a function that takes `...` and returns no name, and there is
    // no function around it for the walk to go back to
    try semantic.enterFunction(null, true, &.{}, chunk.span);
    try semantic.blockBody(&chunk.block);
    try semantic.closeBlock();
    try semantic.leaveFunction(null, null);

    // read before the list is handed over, which empties it
    const body = semantic.functions.items[0].body;

    return .{
        .functions = try semantic.functions.toOwnedSlice(arena),
        .body = body,
        .resolutions = semantic.resolutions,
        .environment_resolutions = semantic.environment_resolutions,
        .definitions = semantic.definitions,
    };
}

fn enterFunction(
    semantic: *Semantic,
    parent: ?*FuncState,
    is_vararg: bool,
    parameters: []const Ast.Parameter,
    body_span: Token.Span,
) Error!void {
    const root = try semantic.arena.create(BlockScope);
    root.* = .{
        .parent = null,
        .function = @intCast(semantic.functions.items.len),
        .n_actvar = 0,
        .is_loop = false,
    };

    const state = try semantic.arena.create(FuncState);
    state.* = .{
        .arena = semantic.arena,
        .index = root.function,
        .parent = parent,
        .root = root,
        .is_vararg = is_vararg,
        .max_actvar = 0,
        .body_span = body_span,
    };

    // written now and filled in when the walk leaves, since a function's
    // upvalues are not all known until it has been walked whole
    try semantic.functions.append(semantic.arena, .{
        .parent = if (parent) |outer| outer.index else null,
        .parameters = &.{},
        .is_vararg = is_vararg,
        .upvalues = &.{},
        .body = root,
        .frame_size = 0,
        .captured_slots = &.{},
    });

    semantic.function = state;
    semantic.scope = root;

    // parameters are the first locals of the function, in the slots 0 to
    // `parameters.len - 1`, and they are in scope in the body
    for (parameters) |parameter| {
        const slot = try semantic.declare(parameter.name, null);
        try semantic.record(parameter.name, .{ .local = slot });
        try state.parameters.append(semantic.arena, .{
            .name = parameter.name.name,
            .span = parameter.name.span,
        });
    }
}

fn leaveFunction(semantic: *Semantic, outer: ?*FuncState, outer_scope: ?*BlockScope) Error!void {
    const state = semantic.function;

    // `functions` is filled in at the index a function was given, which is its
    // own depth in the source, so the result is ordered by position however
    // deeply the walk nests
    const captured_slots = try semantic.arena.alloc(bool, state.max_actvar);
    @memset(captured_slots, false);
    for (state.captured.items) |slot| {
        if (slot < captured_slots.len) captured_slots[slot] = true;
    }
    semantic.functions.items[state.index] = .{
        .parent = if (outer) |parent| parent.index else null,
        .parameters = try state.parameters.toOwnedSlice(semantic.arena),
        .is_vararg = state.is_vararg,
        .upvalues = try state.upvalues.toOwnedSlice(semantic.arena),
        .body = state.root,
        .frame_size = state.max_actvar,
        .captured_slots = captured_slots,
    };

    // the chunk has nothing around it to go back to, which is where the walk
    // ends rather than where it would read an uninitialized field
    if (outer) |parent| {
        semantic.function = parent;
        semantic.scope = outer_scope.?;
    }
}

fn openBlock(semantic: *Semantic, is_loop: bool) Error!void {
    const scope = try semantic.arena.create(BlockScope);
    scope.* = .{
        .parent = semantic.scope,
        .function = semantic.function.index,
        .n_actvar = @intCast(semantic.function.active.items.len),
        .is_loop = is_loop,
    };

    try semantic.scope.child_items.append(semantic.arena, scope);
    semantic.scope = scope;
}

// Closes a scope: what it declared and the labels in it are final, its locals
// stop being in scope and their slots go back for the block around it. A
// function root has no block around it, which is where its gotos run out of
// labels.
fn closeBlock(semantic: *Semantic) Error!void {
    const scope = semantic.scope;
    const state = semantic.function;

    scope.locals = try semantic.arena.dupe(Local, state.active.items[scope.n_actvar..]);
    scope.labels = try scope.label_items.toOwnedSlice(semantic.arena);
    scope.children = try scope.child_items.toOwnedSlice(semantic.arena);
    state.active.shrinkRetainingCapacity(scope.n_actvar);

    // A goto written in this block may name a label one block further out.
    // Carrying it there is what makes `do goto out end` legal while a goto can
    // never reach a label written inside a block it is not in.
    var i: usize = 0;
    while (i < state.pending.items.len) : (i += 1) {
        const goto = state.pending.items[i];
        if (goto.scope != scope or goto.resolved) continue;

        const outer = scope.parent orelse {
            try semantic.report(.{
                .kind = .undefined_label,
                // `undefgoto` runs when the function closes, so the position
                // is the end of the body and only the `at line` inside the
                // message is the goto's own
                .span = .{ .start = semantic.function.body_span.end, .end = semantic.function.body_span.end },
                .name = goto.name,
                .name_span = goto.span,
            });
            continue;
        };

        goto.scope = outer;
    }

    if (scope.parent) |outer| semantic.scope = outer;
}

// The body of a function or of the chunk, neither of which is closed by `until`.
pub fn blockBody(semantic: *Semantic, block: *const Ast.Block) Error!void {
    try semantic.blockBodyUntil(block, &.{});
}

// Whether the block is followed by its `until` condition, which only a `repeat`
// is. A label at the end of such a block is followed by that condition rather than
// by the end of the block, so it is not the last statement in it.
fn untilFollows(terminators: []const Token.Kind) bool {
    for (terminators) |kind| {
        if (kind == .until) return true;
    }
    return false;
}

// `terminators` is the same set the parser stopped the block on, which is what
// says whether a label here is the last statement in the block.
pub fn blockBodyUntil(
    semantic: *Semantic,
    block: *const Ast.Block,
    terminators: []const Token.Kind,
) Error!void {
    const is_last_block = !untilFollows(terminators);

    for (block.statements, 0..) |statement, i| {
        // Lua skips a label's trailing `;` and `::other::` when deciding this,
        // since neither is a statement that can go anywhere
        const is_last = is_last_block and
            (i + 1 == block.statements.len or onlyNoOpsAfter(block.statements[i + 1 ..]));

        try Statement.walk(semantic, statement, is_last);
    }

    if (block.ret_statement) |ret| {
        for (ret.expressions) |expression| {
            try Expression.walk(semantic, expression);
        }
    }
}

// whether everything from here on is an empty statement or a label, which is what
// a label at the end of a block is followed by
fn onlyNoOpsAfter(statements: []const Ast.Statement) bool {
    for (statements) |statement| {
        switch (statement) {
            .empty, .label => {},
            else => return false,
        }
    }
    return true;
}

// Binds a name in the scope being walked. Locals are addressed by slot, and the
// slot a name takes is the count of the locals already in scope, so closing a
// block hands its slots back to the next declaration.
pub fn declare(
    semantic: *Semantic,
    name: Ast.Identifier,
    attribute: ?Ast.Attribute,
) Error!u32 {
    if (attribute) |value| {
        const text = value.name.name;
        if (!std.mem.eql(u8, text, "const") and !std.mem.eql(u8, text, "close")) {
            try semantic.report(.{
                .kind = .unknown_attribute,
                .span = value.name.span,
                .name = text,
                .name_span = value.name.span,
            });
            // the name is still declared, so the rest of the chunk reads a scope
            // rather than tripping over a name that appears out of nowhere
        }
    }

    const state = semantic.function;
    // u32 rather than u16, since the count keeps going past `max_locals` rather
    // than stopping there. A chunk with 65536 locals in one function is refused
    // like any other, and refusing it must not overflow on the way.
    const slot: u32 = @intCast(state.active.items.len);

    // reported and then declared anyway, for the same reason
    if (slot >= max_locals) {
        try semantic.report(.{
            .kind = .too_many_locals,
            .span = name.span,
            .name = name.name,
            .name_span = name.span,
            // the `in main function` or `in function at line N` the reference
            // ends the message with, the body span standing for the line
            .opened_at = if (state.parent == null) null else state.body_span,
            .opened_name = if (state.parent == null) "main function" else "function",
        });
    }

    try state.active.append(semantic.arena, .{
        .name = name.name,
        .span = name.span,
        .slot = slot,
        .is_const = if (attribute) |value| std.mem.eql(u8, value.name.name, "const") else false,
        .is_captured = false,
    });
    state.max_actvar = @max(state.max_actvar, slot + 1);

    return slot;
}

// A name read where it was not introduced, so it has to be looked up: a local of
// this function, a local of one of the functions around it, or nothing, which is
// a global.
pub fn read(semantic: *Semantic, name: Ast.Identifier) Error!void {
    _ = try semantic.resolve(name);
}

// A name read or written where it was not introduced.
pub fn resolve(semantic: *Semantic, name: Ast.Identifier) Error!Resolution {
    const state = semantic.function;

    // Live locals are a stack, and a later declaration of a name shadows an
    // earlier one, so the last match is the one a reader means.
    var i = state.active.items.len;
    while (i > 0) {
        i -= 1;
        if (!std.mem.eql(u8, state.active.items[i].name, name.name)) continue;

        try semantic.record(name, .{ .local = state.active.items[i].slot });
        return .{ .local = state.active.items[i].slot };
    }

    // Not local here, so it may belong to a function around this one. The
    // outermost function holding the name is the frame the closure reads it out
    // of, and every function in between has to hand it on.
    var owner = state.parent;
    while (owner) |outer| {
        const slot = findLocal(outer, name.name) orelse {
            owner = outer.parent;
            continue;
        };

        const index = try semantic.capture(state, outer, slot, name);
        try semantic.record(name, .{ .upvalue = index });
        return .{ .upvalue = index };
    }

    // `_ENV` is the current environment cell even when the source has no
    // explicit local with that name. Other free names are fields in that cell.
    if (std.mem.eql(u8, name.name, "_ENV")) {
        try semantic.record(name, .global);
        return .global;
    }

    const environment = try semantic.resolveEnvironment(name);
    try semantic.environment_resolutions.put(semantic.arena, name.span.start, environment);
    try semantic.record(name, .global);
    return .global;
}

// Resolve the `_ENV` cell for a free name and capture it through intermediate
// functions just like any other upvalue.
fn resolveEnvironment(semantic: *Semantic, name: Ast.Identifier) Error!Resolution {
    const state = semantic.function;
    if (findLocal(state, "_ENV")) |slot| return .{ .local = slot };

    var owner = state.parent;
    while (owner) |outer| {
        const slot = findLocal(outer, "_ENV") orelse {
            owner = outer.parent;
            continue;
        };
        const index = try semantic.capture(state, outer, slot, name);
        return .{ .upvalue = index };
    }
    return .global;
}

// The same, for a name that is being assigned rather than read. A `<const>` local
// can be introduced here but never assigned to.
pub fn resolveAssign(semantic: *Semantic, name: Ast.Identifier) Error!void {
    const resolution = try semantic.resolve(name);

    const slot = switch (resolution) {
        .local => |value| value,
        .upvalue, .global => return,
    };

    if (!semantic.function.active.items[slot].is_const) return;

    try semantic.report(.{
        .kind = .assign_to_const,
        .span = name.span,
        .name = name.name,
        .name_span = name.span,
    });
}

// Captures a local of outer as an upvalue of function, and of every function
// between the two, since each has to read it from the one outside it.
fn capture(
    semantic: *Semantic,
    function: *FuncState,
    outer: *FuncState,
    slot: u32,
    name: Ast.Identifier,
) Error!u32 {
    // A closure keeps the local alive, so its slot may not be handed to anything
    // else while the closure may still be running.
    outer.active.items[slot].is_captured = true;
    try outer.captured.append(outer.arena, slot);

    // Where the value comes from. The function that owns the local holds it in a
    // frame slot, so its closure reads that slot; anything further in reads it out
    // of the closure the one outside it made.
    const from: Upvalue = if (function.parent == outer)
        .{ .parent_local = slot }
    else
        .{ .parent_upvalue = try semantic.capture(function.parent.?, outer, slot, name) };

    // the same name read twice is one upvalue, which is also what makes the two
    // closures of a counter share a cell rather than get one each
    for (function.upvalues.items, 0..) |upvalue, i| {
        switch (upvalue) {
            .parent_local => |value| {
                if (from == .parent_local and from.parent_local == value) return @intCast(i);
            },
            .parent_upvalue => |value| {
                if (from == .parent_upvalue and from.parent_upvalue == value) return @intCast(i);
            },
        }
    }

    if (function.upvalues.items.len >= max_upvalues) {
        try semantic.report(.{
            .kind = .too_many_upvalues,
            .span = name.span,
            .name = name.name,
            .name_span = name.span,
            // the same `in main function` or `in function at line N` clause
            .opened_at = if (function.parent == null) null else function.body_span,
            .opened_name = if (function.parent == null) "main function" else "function",
        });
        // reported and captured anyway, so the rest of the chunk reads a scope
        return 0;
    }

    try function.upvalues.append(function.arena, from);
    return @intCast(function.upvalues.items.len - 1);
}

fn findLocal(state: *FuncState, name: []const u8) ?u32 {
    var i = state.active.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, state.active.items[i].name, name)) return state.active.items[i].slot;
    }
    return null;
}

pub fn record(semantic: *Semantic, name: Ast.Identifier, resolution: Resolution) Error!void {
    try semantic.resolutions.put(semantic.arena, name.span.start, resolution);
}

// A label is visible in the whole block it is written in and in every block
// inside that, so a duplicate is one already declared anywhere up the chain.
// `is_last` says the label is the last thing in its block. Lua treats that as
// though the locals the block declared had already gone out of scope, since
// nothing can jump to a label past the end of a block. `after` is the token
// after the closing `::`, which is where the reference's checks stop.
pub fn declareLabel(semantic: *Semantic, name: Ast.Identifier, is_last: bool, after: Token.Span) Error!void {
    var scope: ?*BlockScope = semantic.scope;
    while (scope) |block| {
        const label = findLabel(block.label_items.items, name.name) orelse {
            scope = block.parent;
            continue;
        };

        try semantic.report(.{
            .kind = .duplicate_label,
            // `checkrepeated` runs once the whole label has been read, so the
            // position it reports from is the token behind it
            .span = after,
            .name = name.name,
            .name_span = name.span,
            // where the one already there is written, which is the more useful
            // half of the pair
            .opened_at = label.span,
            .opened_name = label.name,
        });
        return;
    }

    // measured against the block rather than the point the label is written at,
    // for the reason the parameter says
    const n_actvar: u32 = if (is_last)
        semantic.scope.n_actvar
    else
        @intCast(semantic.function.active.items.len);

    try semantic.scope.label_items.append(semantic.arena, .{
        .name = name.name,
        .span = name.span,
        .n_actvar = n_actvar,
        .after_span = after,
    });

    try semantic.claimGotos(name.name, n_actvar, after);
}

fn findLabel(labels: []const Label, name: []const u8) ?Label {
    var i = labels.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, labels[i].name, name)) return labels[i];
    }
    return null;
}

// A label claims every goto of its name waiting in the block the label is written
// in, or in one nested inside that.
//
// A goto in a block further out is left waiting. It cannot reach this label, but it
// may still be carried out to a block that holds a label of that name, which is
// what makes `do goto out end ::out::` legal while `do ::out:: end goto out` is
// not. Two labels of one name, an inner and an outer, are not a duplicate, and the
// goto is claimed by whichever comes first in the enclosing chain.
fn claimGotos(semantic: *Semantic, name: []const u8, n_actvar: u32, after: Token.Span) Error!void {
    const state = semantic.function;
    var claimed: usize = 0;

    for (state.pending.items) |goto| {
        if (goto.resolved) continue;
        if (!std.mem.eql(u8, goto.name, name)) continue;
        if (!within(goto.scope, semantic.scope)) continue;

        goto.resolved = true;
        claimed += 1;

        // A goto with fewer locals in scope than the label has would bring the
        // difference into scope, which is the one jump Lua will not make.
        if (goto.n_actvar < n_actvar) try semantic.reportScopeJump(goto, after);
    }

    if (claimed == 0) return;

    // a claimed goto leaves the waiting list, so a long run of them is not walked
    // again by every label after it
    var kept: std.ArrayList(*Goto) = .empty;
    for (state.pending.items) |goto| {
        if (!goto.resolved) try kept.append(semantic.arena, goto);
    }

    state.pending = kept;
}

// names the local the jump would bring into scope, which is the first one the
// label has and the goto does not. `after` is the token behind the label that
// claimed the goto, which is where `jumpscopeerror` reports from
fn reportScopeJump(semantic: *Semantic, goto: *const Goto, after: Token.Span) Error!void {
    const local = semantic.function.active.items[goto.n_actvar];

    try semantic.report(.{
        .kind = .goto_into_local_scope,
        .span = after,
        .name = goto.name,
        .name_span = goto.span,
        .opened_at = local.span,
        .opened_name = local.name,
    });
}

// whether scope sits inside ancestor or is it, within one function
fn within(scope: *const BlockScope, ancestor: *const BlockScope) bool {
    var current: ?*const BlockScope = scope;
    while (current) |block| {
        if (block == ancestor) return true;
        current = block.parent;
    }
    return false;
}

pub fn declareGoto(semantic: *Semantic, node: *const Ast.GotoStatement) Error!void {
    const goto = try semantic.arena.create(Goto);
    goto.* = .{
        .name = node.name.name,
        .span = node.name.span,
        .n_actvar = @intCast(semantic.function.active.items.len),
        .scope = semantic.scope,
    };

    // A label written above this one has already been seen, so the goto matches it
    // now rather than waiting for a label that is not coming. A label further down
    // is the other way round, and claims this goto when it is declared.
    const label = visibleLabel(semantic, goto.name) orelse {
        try semantic.function.pending.append(semantic.arena, goto);
        return;
    };

    goto.resolved = true;
    if (goto.n_actvar < label.n_actvar) try semantic.reportScopeJump(goto, label.after_span);
}

// the nearest label of that name in scope here, which is a label in this block or
// in one of the blocks around it
fn visibleLabel(semantic: *Semantic, name: []const u8) ?Label {
    var scope: ?*BlockScope = semantic.scope;
    while (scope) |block| {
        if (findLabel(block.label_items.items, name)) |label| return label;
        scope = block.parent;
    }
    return null;
}

// A `break` is a jump to the end of the innermost loop around it, so it needs one.
// A function body is a scope of its own, so a break in one cannot reach a loop in
// the function around it.
pub fn declareBreak(semantic: *Semantic, node: *const Ast.BreakStatement) Error!void {
    var scope: ?*const BlockScope = semantic.scope;
    while (scope) |block| {
        if (block.is_loop) return;
        if (block.parent == null) break;
        scope = block.parent;
    }

    try semantic.report(.{
        .kind = .break_outside_loop,
        // a `break` is a goto to a label only a loop makes, so — like an
        // undefined one — the position is the end of the function and the
        // `at line` inside the message is the `break`'s own
        .span = .{ .start = semantic.function.body_span.end, .end = semantic.function.body_span.end },
        .name_span = node.break_span,
        .found = .@"break",
    });
}

// `...` is only written in a function whose parameter list has it, and the chunk
// counts as one that does
pub fn declareVararg(semantic: *Semantic, node: *const Ast.VarargExpression) Error!void {
    if (semantic.function.is_vararg) return;

    try semantic.report(.{
        .kind = .vararg_outside_function,
        .span = node.dots_span,
        .found = .dot3,
    });
}

// Only one variable of a list can be to-be-closed, since closing them is what
// keeps the others alive
pub fn checkCloses(semantic: *Semantic, declaration: *const Ast.LocalDeclaration) Error!void {
    var first: ?Ast.LocalName = null;

    for (declaration.names) |local| {
        const attribute = local.attribute orelse continue;
        if (!std.mem.eql(u8, attribute.name.name, "close")) continue;

        if (first) |seen| {
            try semantic.report(.{
                .kind = .multiple_close_variables,
                .span = local.name.span,
                .name = local.name.name,
                .name_span = local.name.span,
                .opened_at = seen.name.span,
                .opened_name = seen.name.name,
            });
            return;
        }

        first = local;
    }
}

pub fn report(semantic: *Semantic, diagnostic: Diagnostic.Error) Error!void {
    semantic.reporter.report(diagnostic) catch return error.ReportFailed;
}

// the walk is split across the files in this directory and every entry point
// there takes the pass first, so the ones more than one file needs are forwarded
// here to read as methods

// The statements of a block, with the tokens the parser would have stopped it on.
// Only the statement walk knows those, since only it knows what closed the block.
pub fn walkBlock(
    semantic: *Semantic,
    block: *const Ast.Block,
    terminators: []const Token.Kind,
) Error!void {
    try semantic.blockBodyUntil(block, terminators);
}

pub fn walkOpenBlock(semantic: *Semantic, is_loop: bool) Error!void {
    try semantic.openBlock(is_loop);
}

pub fn walkExpression(semantic: *Semantic, expression: Ast.Expression) Error!void {
    try Expression.walk(semantic, expression);
}

pub fn walkCloseBlock(semantic: *Semantic) Error!void {
    try semantic.closeBlock();
}

// `function body`, shared by all three forms. `function Name` and
// `local function Name` bind their name in the scope around the body, which the
// statement walk does before calling this.
pub fn walkBody(semantic: *Semantic, body: *const Ast.FunctionBody) Error!void {
    const outer = semantic.function;
    const outer_scope = semantic.scope;

    try semantic.enterFunction(outer, body.vararg != null, body.parameters, body.span);
    try semantic.definitions.put(semantic.arena, body.span.start, .{
        .function = semantic.function.index,
        .span = body.span,
    });

    try semantic.blockBody(&body.block);
    try semantic.closeBlock();
    try semantic.leaveFunction(outer, outer_scope);
}

// A parser and an arena and a reporter of its own, for the tests in this
// directory to share. The arena is not the one inside the parser, since the
// nodes in a chunk point into it and it has to outlive the call that made them.
pub const Test = struct {
    arena: std.heap.ArenaAllocator,
    reporter: Diagnostic.Reporter,

    pub fn init() @This() {
        return .{
            .arena = .init(std.testing.allocator),
            .reporter = .{ .gpa = std.testing.allocator },
        };
    }

    pub fn deinit(t: *@This()) void {
        t.reporter.deinit();
        t.arena.deinit();
    }

    // parses and then analyzes, which is what a caller of the two together does.
    // The error set is the parser's as well as this one's, since a source the
    // parser cannot get through never reaches the walk.
    //
    // The parser is not deinited: it took the arena, and the chunk points into
    // it, so the test harness's own deinit frees the lot at the end.
    pub fn parse(t: *@This(), source: []const u8) (Error || Parser.Error)!Program {
        var parser = Parser.fromSource(source, &t.arena, &t.reporter);
        const chunk = try parser.parseChunk();
        return analyze(t.arena.allocator(), &t.reporter, &chunk);
    }

    pub fn errors(t: *@This()) []const Diagnostic.Error {
        return t.reporter.errors.items;
    }

    pub fn expectClean(t: *@This()) !void {
        const found = t.reporter.errors.items;
        if (found.len != 0) {
            std.debug.print("unexpected diagnostic: {t}\n", .{found[0].kind});
            return error.UnexpectedDiagnostic;
        }
    }

    // the kind of the diagnostic at index, which pins down both that the right
    // thing went wrong and how many things did
    pub fn expectKind(t: *@This(), index: usize, expected: Diagnostic.Error.Kind) !void {
        const found = t.reporter.errors.items;
        try std.testing.expect(index < found.len);
        try std.testing.expectEqual(@tagName(expected), @tagName(found[index].kind));
    }

    // the name the check at index is about
    pub fn expectName(t: *@This(), index: usize, expected: []const u8) !void {
        const found = t.reporter.errors.items;
        try std.testing.expect(index < found.len);
        try std.testing.expectEqualStrings(expected, found[index].name);
    }

    // how many diagnostics the source produced, for the checks that have to stop
    // at one and not pile up
    pub fn expectCount(t: *@This(), expected: usize) !void {
        const found = t.reporter.errors.items;
        if (found.len != expected) {
            std.debug.print("expected {d} diagnostic(s), found {d}", .{ expected, found.len });
            for (found) |e| std.debug.print("\n  {t}", .{e.kind});
            return error.WrongDiagnosticCount;
        }
    }
};

test {
    // the tests live beside the code they cover, so they are named here for the
    // module root to pick up
    _ = @import("Semantic/Statement.zig");
    _ = @import("Semantic/Expression.zig");
    _ = @import("Semantic/Scope.zig");
    _ = @import("Semantic/Goto.zig");
    _ = @import("Semantic/Check.zig");
}
