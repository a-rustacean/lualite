const std = @import("std");

const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");

const Semantic = @import("../Semantic.zig");

const Error = Semantic.Error;

// `is_last` says whether this statement is the last one in its block, which is
// what a label needs to know: Lua treats a label at the end of a block as though
// the locals the block declared had already gone out of scope.
pub fn walk(semantic: *Semantic, statement: Ast.Statement, is_last: bool) Error!void {
    switch (statement) {
        .empty => {},

        .assignment => |node| try assignment(semantic, node),
        .function_call => |node| try Semantic.walkExpression(semantic, .{ .function_call = node }),

        .label => |node| try Semantic.declareLabel(semantic, node.name, is_last),
        .@"break" => |node| try Semantic.declareBreak(semantic, node),
        .goto => |node| try Semantic.declareGoto(semantic, node),

        .do => |node| try scoped(semantic, &node.block, &ends, false),
        .@"while" => |node| try whileStatement(semantic, node),
        .repeat => |node| try repeatStatement(semantic, node),
        .@"if" => |node| try ifStatement(semantic, node),

        .numeric_for => |node| try numericFor(semantic, node),
        .generic_for => |node| try genericFor(semantic, node),

        .function_definition => |node| try functionDefinition(semantic, node),
        .local_function_definition => |node| try localFunctionDefinition(semantic, node),
        .local_declaration => |node| try localDeclaration(semantic, node),
    }
}

// Walks a block in a scope of its own, which every construct with a `do` and an
// `end` around it needs. `terminators` are the tokens that close it, which is what
// says whether a label at the end of it is the last statement in it.
fn scoped(
    semantic: *Semantic,
    block: *const Ast.Block,
    terminators: []const Token.Kind,
    is_loop: bool,
) Error!void {
    try Semantic.walkOpenBlock(semantic, is_loop);
    defer Semantic.walkCloseBlock(semantic) catch {};

    try Semantic.walkBlock(semantic, block, terminators);
}

// the blocks every construct but `repeat` opens
const ends = [_]Token.Kind{.end};
// `repeat` is the one closed by `until`, which puts its condition inside the block
const untils = [_]Token.Kind{.until};
// an `if` clause stops for `else` and `elseif` as well, or recovery would not know
// where the clause it is in ends
const then_ends = [_]Token.Kind{ .end, .@"else", .elseif };
// the last clause of an `if` runs to the `end` itself
const clause_ends = [_]Token.Kind{ .@"else", .elseif, .end };

fn assignment(semantic: *Semantic, node: *const Ast.AssignmentStatement) Error!void {
    for (node.expressions) |expression| {
        try Semantic.walkExpression(semantic, expression);
    }

    // the targets are read as well as written, since a field or an index reads
    // the object it reaches through
    for (node.variables) |variable| {
        switch (variable) {
            .name => |name| try Semantic.resolveAssign(semantic, name),
            .index => |index| {
                try Semantic.walkExpression(semantic, index.object);
                try Semantic.walkExpression(semantic, index.index);
            },
            .field => |field| try Semantic.walkExpression(semantic, field.object),
        }
    }
}

fn whileStatement(semantic: *Semantic, node: *const Ast.WhileStatement) Error!void {
    // the condition is outside the loop, so it sees nothing the body declares
    try Semantic.walkExpression(semantic, node.condition);
    try scoped(semantic, &node.block, &ends, true);
}

fn repeatStatement(semantic: *Semantic, node: *const Ast.RepeatStatement) Error!void {
    try Semantic.walkOpenBlock(semantic, true);
    defer Semantic.walkCloseBlock(semantic) catch {};

    try Semantic.walkBlock(semantic, &node.block, &untils);

    // the condition is inside the loop, which is what lets it see the locals the
    // body declared. That is why a `repeat` block has to still be open here.
    try Semantic.walkExpression(semantic, node.condition);
}

fn ifStatement(semantic: *Semantic, node: *const Ast.IfStatement) Error!void {
    try Semantic.walkExpression(semantic, node.condition);
    try scoped(semantic, &node.block, &then_ends, false);

    // each `elseif` and `else` gets a scope of its own, so a local declared in
    // one clause is not in scope in the next
    for (node.elseif_clauses) |clause| {
        try Semantic.walkExpression(semantic, clause.condition);
        try scoped(semantic, &clause.block, &clause_ends, false);
    }

    if (node.else_clause) |else_clause| {
        try scoped(semantic, &else_clause.block, &ends, false);
    }
}

fn numericFor(semantic: *Semantic, node: *const Ast.ForStatement) Error!void {
    // the three bounds are outside the loop and see nothing it declares
    try Semantic.walkExpression(semantic, node.initial);
    try Semantic.walkExpression(semantic, node.limit);
    if (node.step) |step| try Semantic.walkExpression(semantic, step);

    try Semantic.walkOpenBlock(semantic, true);
    defer Semantic.walkCloseBlock(semantic) catch {};

    // the control variable is a local of the loop, shadowing anything of the
    // same name around it
    const slot = try Semantic.declare(semantic, node.name, null);
    try Semantic.record(semantic, node.name, .{ .local = slot });

    try Semantic.walkBlock(semantic, &node.block, &ends);
}

fn genericFor(semantic: *Semantic, node: *const Ast.ForInStatement) Error!void {
    // the expressions are outside the loop. Lua leaves the first value it gets
    // to the loop, and that is decided when the iterator is called, not here.
    for (node.expressions) |expression| {
        try Semantic.walkExpression(semantic, expression);
    }

    try Semantic.walkOpenBlock(semantic, true);
    defer Semantic.walkCloseBlock(semantic) catch {};

    // every name of the list is a local of the loop, in source order
    for (node.names) |name| {
        const slot = try Semantic.declare(semantic, name, null);
        try Semantic.record(semantic, name, .{ .local = slot });
    }

    try Semantic.walkBlock(semantic, &node.block, &ends);
}

// `function Name body`, where the name may be a dotted path and a method
fn functionDefinition(semantic: *Semantic, node: *const Ast.FunctionDefinition) Error!void {
    const name = node.name;

    // `function f` assigns to f, while `function a.b` and `function a:b` read a
    // first and only write the last name of the path
    if (name.fields.len == 0 and name.method == null) {
        try Semantic.resolveAssign(semantic, name.first);
    } else {
        try Semantic.read(semantic, name.first);
    }

    try Semantic.walkBody(semantic, &node.body);
}

// `local function Name body`, which binds the name before the body so that the
// function can call itself
fn localFunctionDefinition(semantic: *Semantic, node: *const Ast.LocalFunctionDefinition) Error!void {
    const slot = try Semantic.declare(semantic, node.name, null);
    try Semantic.record(semantic, node.name, .{ .local = slot });

    try Semantic.walkBody(semantic, &node.body);
}

fn localDeclaration(semantic: *Semantic, node: *const Ast.LocalDeclaration) Error!void {
    try Semantic.checkCloses(semantic, node);

    // The values are read before the names are bound, which is what makes
    // `local x = x` read a name from around the declaration rather than the
    // local it is introducing.
    for (node.expressions) |expression| {
        try Semantic.walkExpression(semantic, expression);
    }

    for (node.names) |local| {
        const slot = try Semantic.declare(semantic, local.name, local.attribute);
        try Semantic.record(semantic, local.name, .{ .local = slot });
    }
}
