const std = @import("std");

const Token = @import("../Token.zig");
const Ast = @import("../Ast.zig");

const Semantic = @import("../Semantic.zig");

const Error = Semantic.Error;

// The walk only has to visit the names an expression writes and say whether
// `...` has anywhere to come from. Everything else in a node is evaluated by
// the AST runtime, and there is nothing else for this resolver to check.
pub fn walk(semantic: *Semantic, expression: Ast.Expression) Error!void {
    switch (expression) {
        // no names to look up
        .nil, .boolean, .number, .string => {},

        .vararg => |node| try Semantic.declareVararg(semantic, node),

        .variable => |node| try variable(semantic, node.*),

        .unary => |node| try walk(semantic, node.expression),
        .binary => |node| {
            try walk(semantic, node.left);
            try walk(semantic, node.right);
        },

        .function => |node| try Semantic.walkBody(semantic, &node.body),

        .table => |node| try table(semantic, node),
        .parenthesized => |node| try walk(semantic, node.expression),

        .function_call => |node| try call(semantic, node),
    }
}

// A name is looked up, unless it is being assigned to, in which case a `<const>`
// local is refused. A field or an index reads the object it hangs off, and the
// name of a field is part of the object rather than a name of its own, so `a.b`
// reads `a` and `a[x]` reads both.
fn variable(semantic: *Semantic, node: Ast.Variable) Error!void {
    switch (node) {
        .name => |name| try Semantic.read(semantic, name),
        .index => |index| {
            try walk(semantic, index.object);
            try walk(semantic, index.index);
        },
        .field => |field| try walk(semantic, field.object),
    }
}

// `object:name(...)` passes the object as the first argument, so its name is read
// once, to find the method, and the object itself is not an expression of its own
// here
fn call(semantic: *Semantic, node: *const Ast.FunctionCall) Error!void {
    try walk(semantic, node.expression);

    switch (node.arguments) {
        .parenthesized => |arguments| {
            for (arguments.expressions) |expression| try walk(semantic, expression);
        },
        .table => |constructor| try table(semantic, &constructor),
        .string => {},
    }
}

fn table(semantic: *Semantic, node: *const Ast.TableConstructor) Error!void {
    for (node.fields) |field| {
        switch (field) {
            .indexed => |indexed| {
                try walk(semantic, indexed.key);
                try walk(semantic, indexed.value);
            },
            .named => |named| try walk(semantic, named.value),
            .expression => |list| try walk(semantic, list.expression),
        }
    }
}
