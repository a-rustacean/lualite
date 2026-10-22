const std = @import("std");

const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const Ast = @import("Ast.zig");
const Diagnostic = @import("Diagnostic.zig");

const Block = @import("Parser/Block.zig");
const Expression = @import("Parser/Expression.zig");
const Statement = @import("Parser/Statement.zig");

pub const Parser = @This();

// ParserFailed is the recoverable one, its diagnostic is already in the
// reporter and the block loop synchronizes and carries on
pub const Error = error{
    OutOfMemory,
    ReportFailed,
    ParserFailed,
};

// Blocks, table constructors and parenthesized expressions all recurse, so a
// source like `((((((...` would run the stack out. Lua caps this at 200.
const max_depth: u32 = 200;

// pushBlock runs once per construct, enter once per recursion point, and
// `if function() ... then` needs two pushes for one enter, so this covers the
// worst case plus the one the innermost construct pushes
const max_open_blocks: u32 = 2 * max_depth + 1;

lexer: Lexer,
// by pointer, since an ArenaAllocator allocates its state lazily and a copy by
// value would leave the other copy's deinit with nothing to free
arena: *std.heap.ArenaAllocator,
reporter: *Diagnostic.Reporter,
depth: u32 = 0,
// the blocks open right now, outermost first. Sized for max_open_blocks since
// pushes are not matched to enter calls one for one
open_blocks: [max_open_blocks]OpenBlock = undefined,
open_len: u16 = 0,
// where a token the lexer rejected stood, set by skipInvalid and taken by the
// next expression parse: the reference stops at the lexer's complaint, so the
// slot the rejected token was read for is filled without a second complaint
// about it being empty. Consuming a token drops the mark, so a statement
// dispatched over junk does not leave it behind for a later expression.
lexer_gap: ?Token.Span = null,

// a block that has been opened and not yet closed
pub const OpenBlock = struct {
    // if, while, for, do, repeat or function
    keyword: Token.Kind,
    // where that keyword is, so a missing `end` can point back at it
    span: Token.Span,
    // set when the keyword alone cannot name the block, as it cannot for
    // `local function`, where the whole phrase opens it
    phrase: ?[]const u8 = null,
};

// takes ownership of arena, deinit frees it along with every node the parse
// allocated
pub fn fromSource(
    source: []const u8,
    arena: *std.heap.ArenaAllocator,
    reporter: *Diagnostic.Reporter,
) Parser {
    return .{
        .lexer = .{ .source = source, .current_char_idx = 0 },
        .arena = arena,
        .reporter = reporter,
    };
}

// frees the arena and every node in it, including the Ast from parseChunk
pub fn deinit(parser: *Parser) void {
    parser.arena.deinit();
}

pub fn allocator(parser: *Parser) std.mem.Allocator {
    return parser.arena.allocator();
}

pub fn parseChunk(parser: *Parser) Error!Ast.Chunk {
    const start: u32 = @intCast(parser.lexer.current_char_idx);

    // the chunk is the one block with no terminator, only end of file closes it
    const block = try Block.parseBlock(parser, &.{});

    return .{
        // the chunk covers the whole source, the block inside it stops at the
        // last token it parsed
        .span = .{ .start = start, .end = @intCast(parser.lexer.source.len) },
        .block = block,
    };
}

// the next token, left in place for next to consume
//
// a token the lexer rejects is stepped over and the peek retried, since
// peekToken never moves the cursor and would otherwise rescan it forever
pub fn peek(parser: *Parser) Error!Token {
    while (true) {
        const mark = parser.reporter.errors.items.len;

        const token = parser.lexer.peekToken(parser.reporter) catch |err| switch (err) {
            error.ReportFailed => return error.ReportFailed,
            error.LexerFailed => {
                parser.skipInvalid(mark);
                continue;
            },
        };

        return token;
    }
}

pub fn next(parser: *Parser) Error!Token {
    const token = try parser.peek();
    // an eof token spans nothing, so this leaves the cursor put and every
    // later call yields eof again
    parser.lexer.current_char_idx = token.span.end;
    // a token consumed means the parse has moved past whatever was skipped
    // to reach it, so the gap it was reached through is spent
    parser.lexer_gap = null;
    return token;
}

pub fn check(parser: *Parser, kind: Token.Kind) Error!bool {
    return (try parser.peek()).kind == kind;
}

pub fn eat(parser: *Parser, kind: Token.Kind) Error!bool {
    if (!try parser.check(kind)) return false;
    _ = try parser.next();
    return true;
}

// a kind that closes a block also pops it, but only on success. The construct
// that pushed the block owns unwinding it, through the errdefer at the pushBlock
// site.
pub fn expect(parser: *Parser, kind: Token.Kind) Error!Token {
    const token = try parser.peek();
    if (token.kind != kind) {
        // report before the caller unwinds, while the open block is still known
        return parser.fail(.expected_token, token, .{ .token = kind });
    }

    _ = try parser.next();
    if (closesBlock(kind)) parser.popBlock();

    return token;
}

// the two tokens that close a block rather than being part of one
fn closesBlock(kind: Token.Kind) bool {
    return kind == .end or kind == .until;
}

pub fn expectIdent(parser: *Parser) Error!Ast.Identifier {
    const token = try parser.peek();
    if (token.kind != .ident) return parser.fail(.expected_token, token, .{ .token = .ident });
    return parser.ident(try parser.next());
}

// true at end of file or at one of the tokens that closes the block being
// parsed, which is left for the caller to consume
pub fn atBlockEnd(parser: *Parser, terminators: []const Token.Kind) Error!bool {
    const kind = (try parser.peek()).kind;
    if (kind == .eof) return true;

    for (terminators) |terminator| {
        if (kind == terminator) return true;
    }

    return false;
}

// records a diagnostic without stopping the parse, the caller decides whether
// to bail or recover
pub fn report(parser: *Parser, diagnostic: Diagnostic.Error) Error!void {
    parser.reporter.report(diagnostic) catch return error.ReportFailed;
}

// reports about the token the parser stopped on and gives up on the statement,
// the block loop catches ParserFailed and synchronizes. wanted is null where
// nothing at all could have gone there.
pub fn fail(
    parser: *Parser,
    kind: Diagnostic.Error.Kind,
    at: Token,
    wanted: ?Diagnostic.Error.Expected,
) Error {
    return parser.failFull(kind, at.span, wanted, at.kind);
}

fn failFull(
    parser: *Parser,
    kind: Diagnostic.Error.Kind,
    span: Token.Span,
    wanted: ?Diagnostic.Error.Expected,
    found: ?Token.Kind,
) Error {
    const opened = parser.openedFor(wanted);

    parser.report(.{
        .kind = kind,
        .span = span,
        .expected = wanted,
        .found = found,
        .opened_at = if (opened) |open| open.span else null,
        .opened_name = if (opened) |open| open.name else "",
    }) catch return error.ReportFailed;

    return error.ParserFailed;
}

// every pointer payload in Ast comes from here, so no node is freed on its own
pub fn box(parser: *Parser, comptime T: type, value: T) Error!*T {
    const ptr = parser.arena.allocator().create(T) catch return error.OutOfMemory;
    ptr.* = value;
    return ptr;
}

pub fn ident(parser: *const Parser, token: Token) Ast.Identifier {
    return .{
        .span = token.span,
        .name = parser.lexer.source[token.span.start..token.span.end],
    };
}

pub fn slice(parser: *const Parser, span: Token.Span) []const u8 {
    return parser.lexer.source[span.start..span.end];
}

// steps past the input the lexer just rejected. mark is where the reporter
// stood before that attempt, so the widest of the diagnostics since is how far
// to jump. Always moves at least one byte, the rejected token may have reported
// a span as long as itself. The span jumped over is left behind as the parser's
// lexer gap, so the expression that asked for the token is filled rather than
// reported empty as well.
fn skipInvalid(parser: *Parser, mark: usize) void {
    var next_idx = parser.lexer.current_char_idx + 1;

    for (parser.reporter.errors.items[mark..]) |e| {
        if (e.span.end > next_idx) next_idx = e.span.end;
    }

    const landed = @min(next_idx, parser.lexer.source.len);
    parser.lexer_gap = .{ .start = @intCast(parser.lexer.current_char_idx), .end = @intCast(landed) };
    parser.lexer.current_char_idx = landed;
}

pub fn enter(parser: *Parser) Error!void {
    // checked before the increment, since the caller only defers its leave once
    // this has returned. Counting first would leak a level per refusal and put
    // every statement after it one step nearer the limit than it really is.
    if (parser.depth >= max_depth) return parser.fail(.nesting_too_deep, try parser.peek(), null);

    parser.depth += 1;
}

pub fn leave(parser: *Parser) void {
    parser.depth -= 1;
}

// records an open block so the closer it waits for can name it. Only the
// innermost one is ever named.
pub fn pushBlock(parser: *Parser, keyword: Token.Kind, span: Token.Span) void {
    return parser.pushBlockPhrase(keyword, span, null);
}

pub fn pushBlockPhrase(parser: *Parser, keyword: Token.Kind, span: Token.Span, phrase: ?[]const u8) void {
    // max_open_blocks covers every block the deepest nesting enter allows, so
    // this is always a free slot. Writing past the array would take the fields
    // after it with it, and the bound is an argument rather than something the
    // code can check its way to.
    std.debug.assert(parser.open_len < parser.open_blocks.len);

    parser.open_blocks[parser.open_len] = .{ .keyword = keyword, .span = span, .phrase = phrase };
    parser.open_len += 1;
}

// the innermost open block, the one a missing closer belongs to
pub fn openBlock(parser: *const Parser) ?OpenBlock {
    if (parser.open_len == 0) return null;
    return parser.open_blocks[parser.open_len - 1];
}

// a block that a diagnostic about a missing closer can point at
const Opened = struct { span: Token.Span, name: []const u8 };

pub fn popBlock(parser: *Parser) void {
    if (parser.open_len != 0) parser.open_len -= 1;
}

// taken before a pushBlock that an errdefer has to take back. The guard cannot
// simply decrement: the closer a block waits for pops it on the way out, so by
// the time the errdefer runs the block may already be closed and a second pop
// would take an enclosing one with it.
pub fn blockMark(parser: *const Parser) u16 {
    return parser.open_len;
}

// closes the block pushed after mark, and nothing else
pub fn unwindBlocks(parser: *Parser, mark: u16) void {
    parser.open_len = mark;
}

// the open block a diagnostic about a missing closer belongs to
fn openedFor(parser: *const Parser, wanted: ?Diagnostic.Error.Expected) ?Opened {
    const token = switch (wanted orelse return null) {
        .token => |kind| kind,
        else => return null,
    };

    if (!closesBlock(token)) return null;

    const open = parser.openBlock() orelse return null;
    return .{ .span = open.span, .name = open.phrase orelse @tagName(open.keyword) };
}

// the parse is split across the files in this directory and every entry point
// there takes the parser first, so the ones more than one file needs are
// forwarded here to read as methods

pub fn parseExpression(parser: *Parser) Error!Ast.Expression {
    return Expression.parseExpression(parser);
}

pub fn parseExpressionList(parser: *Parser) Error![]Ast.Expression {
    return Expression.parseExpressionList(parser);
}

pub fn parseSuffixed(parser: *Parser) Error!Ast.Expression {
    return Expression.parseSuffixed(parser);
}

pub fn parseSuffixedAfter(parser: *Parser, first: Token) Error!Ast.Expression {
    return Expression.parseSuffixedAfter(parser, first);
}

pub fn toVariable(parser: *Parser, expr: Ast.Expression) Error!Ast.Variable {
    return Expression.toVariable(parser, expr);
}

// Build a string of `n` copies of `s` at comptime, since the tests that probe the
// nesting limit need a few hundred repeats and Zig 0.17 no longer ships a
// repeat helper in `std.mem`. Comptime is the right home for it: the count is
// always known ahead, and the result is a static slice the test can build
// larger literals from.
fn repeat(comptime s: []const u8, comptime n: usize) [s.len * n]u8 {
    comptime var out: [s.len * n]u8 = undefined;
    @setEvalBranchQuota(100_000);
    comptime var i: usize = 0;
    inline while (i < n) : (i += 1) @memcpy(out[i * s.len ..][0..s.len], s);
    return out;
}

// a parser with an arena and a reporter of its own, for the tests in this
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

    pub fn parse(t: *@This(), source: []const u8) Error!Ast.Chunk {
        var parser = fromSource(source, &t.arena, &t.reporter);
        return parser.parseChunk();
    }

    // hangs the expression off a return so it gets a statement around it
    pub fn parseExpression(t: *@This(), source: []const u8) anyerror!Ast.Expression {
        const wrapped = try std.mem.concat(t.arena.allocator(), u8, &.{ "return ", source });
        var parser = fromSource(wrapped, &t.arena, &t.reporter);
        const chunk = try parser.parseChunk();
        const ret = chunk.block.ret_statement orelse return error.NoReturnStatement;
        if (ret.expressions.len == 0) return error.NoExpression;
        return ret.expressions[0];
    }

    pub fn parseStatement(t: *@This(), source: []const u8) anyerror!Ast.Statement {
        var parser = fromSource(source, &t.arena, &t.reporter);
        const statement = (try Statement.parseStatement(&parser)) orelse return error.NotAStatement;
        return statement;
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
        try std.testing.expectEqualStrings(@tagName(expected), @tagName(found[index].kind));
    }

    // what the parser wanted at index
    pub fn expectExpected(t: *@This(), index: usize, expected: Diagnostic.Error.Expected) !void {
        const all = t.reporter.errors.items;
        try std.testing.expect(index < all.len);

        const recorded = all[index].expected orelse return error.NoExpectationRecorded;

        try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(recorded));

        switch (recorded) {
            .token => |kind| switch (expected) {
                .token => |wanted| try std.testing.expectEqual(wanted, kind),
                else => return error.WrongExpectationKind,
            },
            else => {},
        }
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

    // the token the parser found at index instead
    pub fn expectFound(t: *@This(), index: usize, expected: Token.Kind) !void {
        const all = t.reporter.errors.items;
        try std.testing.expect(index < all.len);
        try std.testing.expectEqual(expected, all[index].found.?);
    }
};
test "peek leaves the token and next consumes it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var reporter: Diagnostic.Reporter = .{ .gpa = std.testing.allocator };
    defer reporter.deinit();

    var parser = fromSource("local x = 1", &arena, &reporter);

    const first = try parser.peek();
    try std.testing.expectEqual(Token.Kind.local, first.kind);
    try std.testing.expectEqual(@as(usize, 0), parser.lexer.current_char_idx);

    const again = try parser.peek();
    try std.testing.expectEqual(first.span.start, again.span.start);

    const consumed = try parser.next();
    try std.testing.expectEqual(@as(usize, 5), parser.lexer.current_char_idx);
    try std.testing.expectEqual(@as(u32, 0), consumed.span.start);
}

test "next past the last token keeps yielding eof" {
    var t = Test.init();
    defer t.deinit();

    var parser = fromSource("x", &t.arena, &t.reporter);

    _ = try parser.next();
    const first_eof = try parser.next();
    const second_eof = try parser.next();

    try std.testing.expectEqual(Token.Kind.eof, first_eof.kind);
    try std.testing.expectEqual(Token.Kind.eof, second_eof.kind);
    try std.testing.expectEqual(first_eof.span.start, second_eof.span.start);
}

test "check, eat and expect" {
    var t = Test.init();
    defer t.deinit();

    var parser = fromSource("x, 2", &t.arena, &t.reporter);

    try std.testing.expect(try parser.check(.ident));
    try std.testing.expect(!try parser.check(.comma));
    try std.testing.expect(try parser.eat(.ident));
    try std.testing.expect(!try parser.eat(.ident));
    try std.testing.expectEqual(@as(usize, 1), parser.lexer.current_char_idx);

    const comma = try parser.expect(.comma);
    try std.testing.expectEqual(@as(u32, 1), comma.span.start);
}

test "expect reports the token it wanted" {
    var t = Test.init();
    defer t.deinit();

    var parser = fromSource("local 1", &t.arena, &t.reporter);

    _ = try parser.expect(.local);
    try std.testing.expectError(error.ParserFailed, parser.expect(.ident));

    try std.testing.expectEqual(@as(usize, 1), t.errors().len);
    const found = t.errors()[0];
    try std.testing.expectEqual(Diagnostic.Error.Kind.expected_token, found.kind);
    try std.testing.expectEqual(Token.Kind.ident, found.expected.?.token);
    try std.testing.expectEqual(@as(u32, 6), found.span.start);
    try std.testing.expectEqual(@as(u32, 7), found.span.end);
}

test "atBlockEnd stops on eof and on the terminators" {
    var t = Test.init();
    defer t.deinit();

    var parser = fromSource("end x", &t.arena, &t.reporter);

    try std.testing.expect(try parser.atBlockEnd(&.{ .end, .until }));
    try std.testing.expect(!try parser.atBlockEnd(&.{.until}));

    _ = try parser.next();
    try std.testing.expect(!try parser.atBlockEnd(&.{ .end, .until }));
    _ = try parser.next();
    try std.testing.expect(try parser.atBlockEnd(&.{}));
}

test "a token the lexer rejects is stepped over" {
    var t = Test.init();
    defer t.deinit();

    // the lexer reports the malformed numeral and gives up, so the parse has to
    // carry on at the `;` behind it
    const chunk = try t.parse("local x = 3a; local y = 2");

    try std.testing.expectEqual(@as(usize, 1), t.errors().len);
    try std.testing.expectEqual(Diagnostic.Error.Kind.malformed_number, t.errors()[0].kind);
    try std.testing.expectEqual(@as(usize, 3), chunk.block.statements.len);
}

test "a run of bytes the lexer rejects still terminates" {
    var t = Test.init();
    defer t.deinit();

    // peek retries after stepping over what the lexer rejected, so a source made
    // entirely of junk has to run out rather than spin on the first byte
    const chunk = try t.parse("$%$%$%$%$");

    var rejected: usize = 0;
    for (t.errors()) |found| {
        if (found.kind == .invalid_char) rejected += 1;
    }

    try std.testing.expectEqual(@as(usize, 5), rejected);
    try std.testing.expectEqual(@as(usize, 0), chunk.block.statements.len);
}

test "nesting past the depth limit is refused, and the rest of the file is not" {
    var t = Test.init();
    defer t.deinit();

    const parens = &@as([300]u8, @splat('(')) ++ "x" ++ &@as([300]u8, @splat(')'));
    const tail_at = parens.len + 1;

    // the tail is the point: recovery unwinds the levels the refusal gave up,
    // so the same parser has to accept what comes after
    const chunk = try t.parse(parens ++ " print(1)");

    // recovery gets past it, so this is the first of several
    try t.expectKind(0, .nesting_too_deep);

    // the call parses as itself rather than being refused. A limit that stayed
    // set, or that counted the levels it gave up, would report it too and say
    // nothing useful about it
    try std.testing.expectEqual(@as(usize, 1), chunk.block.statements.len);
    try std.testing.expectEqual(
        std.meta.Tag(Ast.Statement).function_call,
        std.meta.activeTag(chunk.block.statements[0]),
    );

    // and none of the leftovers reach into it
    for (t.errors()) |found| {
        try std.testing.expect(found.span.start < tail_at);
    }
}

test "nested calls are held to the depth limit too" {
    var t = Test.init();
    defer t.deinit();

    // a call never enters a block, so this only gets caught if the argument list
    // counts towards the nesting as well
    const calls_buf = repeat("f(", 300);
    const calls = calls_buf[0..];
    const close_buf = repeat(")", 300);
    _ = t.parse("return " ++ calls ++ "x" ++ close_buf[0..]) catch {};

    try t.expectKind(0, .nesting_too_deep);
}

test "a chain of prefix operators is held to the depth limit too" {
    var t = Test.init();
    defer t.deinit();

    // likewise for a unary operand, which is a whole expression and not a simple
    // one
    const not_buf = repeat("not ", 300);
    _ = t.parse("return " ++ not_buf[0..] ++ "x") catch {};

    try t.expectKind(0, .nesting_too_deep);
}

test "nesting just under the depth limit still parses" {
    var t = Test.init();
    defer t.deinit();

    // a return keeps the parentheses on the expression side of the parse
    const depth: usize = 100;

    // all three of the ways a parse can recurse are open at this depth
    const open_buf = repeat("(", depth);
    const close_buf = repeat(")", depth);
    const not_buf = repeat("not ", depth);
    const call_buf = repeat("(x)", depth);
    _ = try t.parse("return " ++ (open_buf[0..] ++ "x" ++ close_buf[0..]));
    _ = try t.parse("return " ++ not_buf[0..] ++ "x");
    _ = try t.parse("return f" ++ call_buf[0..]);
    try t.expectClean();
}

test "nested blocks are held to the depth limit too" {
    var t = Test.init();
    defer t.deinit();

    // a function in the condition of an if opens a block of its own, so this pushes
    // twice per level of depth. The open blocks need a wider budget than the
    // depth, or the stack of them runs out while the parse is still inside its
    // limit.
    const depth: usize = 90;

    const open_buf = repeat("if function() ", depth);
    const close_buf = repeat(" end then end", depth);
    _ = try t.parse(open_buf[0..] ++ "x()" ++ close_buf[0..]);
    try t.expectClean();
}

test "nesting blocks past the depth limit is refused" {
    var t = Test.init();
    defer t.deinit();

    // well past what the open blocks are sized for, to show the nesting is caught
    // by the limit and not by running the stack of blocks out
    const depth: usize = 250;

    // the whole token run has to repeat, not a run of spaces, or the parse never
    // opens the blocks the limit is meant to refuse
    const open_buf = repeat("if function() ", depth);
    const close_buf = repeat(" end then end", depth);
    _ = t.parse(open_buf[0..] ++ "x" ++ close_buf[0..]) catch {};

    try t.expectKind(0, .nesting_too_deep);
}

test "a local declaration spans the whole statement" {
    var t = Test.init();
    defer t.deinit();

    // as every other statement does, from the `local` to whatever was assigned
    // rather than stopping at the name list
    const chunk = try t.parse("  local a, b = f(), 2  local c  ");
    try t.expectClean();

    const first = chunk.block.statements[0].local_declaration;
    try std.testing.expectEqual(@as(u32, 2), first.span.start);
    try std.testing.expectEqual(@as(u32, 21), first.span.end);

    // with nothing assigned, the last name is where it ends
    const second = chunk.block.statements[1].local_declaration;
    try std.testing.expectEqual(@as(u32, 23), second.span.start);
    try std.testing.expectEqual(@as(u32, 30), second.span.end);
}

test "Token.at is a span of no width" {
    const span = Token.at(7);

    try std.testing.expectEqual(@as(u32, 7), span.start);
    try std.testing.expectEqual(@as(u32, 7), span.end);

    // merging a span of no width is the same span
    try std.testing.expectEqual(span, Token.merge(span, span));
}

test "a whole module parses without a diagnostic" {
    var t = Test.init();
    defer t.deinit();

    const source =
        \\local Account = {}
        \\
        \\Account.__index = Account
        \\
        \\function Account.new(owner, balance)
        \\  local closed <close> = nil
        \\  return setmetatable({ owner = owner, balance = balance or 0 }, Account)
        \\end
        \\
        \\function Account:deposit(amount)
        \\  assert(type(amount) == "number", "amount must be a number")
        \\  self.balance = self.balance + amount
        \\  return self
        \\end
        \\
        \\local rates = { usd = 1, ["gbp"] = 0.8; eur = 0.9 }
        \\
        \\local function total(account, ...)
        \\  local sum = account.balance
        \\  for _, amount in ipairs({ ... }) do
        \\    sum = sum + amount * (rates.gbp or 1)
        \\  end
        \\  repeat
        \\    sum = sum // 1
        \\  until sum == sum
        \\  return sum
        \\end
        \\
        \\for name, rate in pairs(rates) do
        \\  if rate < 1 then
        \\    io.write(name, " is below par\\n")
        \\  elseif rate > 1 then
        \\    io.write(name, " is above par\\n")
        \\  else
        \\    io.write(name, " is at par\\n")
        \\  end
        \\end
        \\
        \\do
        \\  local account = Account.new("ada")
        \\  account:deposit(100):deposit(50)
        \\  print(total(account, 1, 2, 3), #"abc", -2^2, 2^-3, not nil == true)
        \\end
        \\
        \\::top::
        \\for i = 10, 1, -1 do
        \\  if i % 2 == 0 then goto top end
        \\end
        \\
        \\return Account, total
    ;

    const chunk = try t.parse(source);
    try t.expectClean();

    // the module's own return is the chunk's, and the statements behind it are
    // all still there
    try std.testing.expectEqual(@as(usize, 10), chunk.block.statements.len);
    try std.testing.expectEqual(@as(usize, 2), chunk.block.ret_statement.?.expressions.len);
    try std.testing.expectEqualStrings("Account", chunk.block.ret_statement.?.expressions[0].variable.name.name);
    try std.testing.expectEqual(
        std.meta.Tag(Ast.Statement).numeric_for,
        std.meta.activeTag(chunk.block.statements[chunk.block.statements.len - 1]),
    );

    try std.testing.expectEqual(@as(u32, 0), chunk.span.start);
    try std.testing.expectEqual(@as(u32, source.len), chunk.span.end);
}

test {
    // the tests live beside the code they cover, so they are named here for the
    // module root to pick up
    _ = @import("Parser/Block.zig");
    _ = @import("Parser/Expression.zig");
    _ = @import("Parser/Function.zig");
    _ = @import("Parser/Statement.zig");
    _ = @import("Parser/Table.zig");
}

test "a diagnostic names what was wanted and what was found" {
    var t = Test.init();
    defer t.deinit();

    _ = t.parse("local x = end") catch {};

    // a class of thing rather than a token, the parser wanted an expression and
    // stopped on a keyword
    try t.expectKind(0, .expected_token);
    try t.expectExpected(0, .expression);
    try t.expectFound(0, .end);
}

test "a diagnostic names the block a missing closer belongs to" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local function outer()\n  while x do\n    print(1)\n");

    // the innermost block is named first, then the one around it, which is the
    // order they would have to be closed in
    try t.expectExpected(0, .{ .token = .end });
    try std.testing.expectEqual(@as(u32, 25), t.errors()[0].opened_at.?.start);

    try t.expectExpected(1, .{ .token = .end });
    // the `local` of `local function outer()`, since that is what opens it
    try std.testing.expectEqual(@as(u32, 0), t.errors()[1].opened_at.?.start);
}

test "a closer that is matched does not leave its block open" {
    var t = Test.init();
    defer t.deinit();

    // balanced, so the later missing closer is the chunk's own and has no block
    // to name
    _ = try t.parse("do end");

    var parser = fromSource("do end do", &t.arena, &t.reporter);
    _ = try parser.parseChunk();

    try t.expectExpected(0, .{ .token = .end });
    // the `do` that is still open, not the one that closed
    try std.testing.expectEqual(@as(u32, 7), t.errors()[0].opened_at.?.start);
}

test "a failed token that is not a closer leaves its block open" {
    var t = Test.init();
    defer t.deinit();

    // the `}` is wanted inside the open `if`, and missing it does not close the
    // `if`, so the `if` is still the open block afterwards
    _ = try t.parse("if x then local t = {1 2}\n");

    // the table constructor is given up on, and the missing `end` is reported
    // against the `if` still waiting for it rather than going unnamed
    try t.expectExpected(0, .{ .token = .rcurly });
    try std.testing.expect(t.errors()[0].opened_at == null);

    try t.expectExpected(1, .{ .token = .end });
    try std.testing.expectEqual(@as(u32, 0), t.errors()[1].opened_at.?.start);
    try std.testing.expectEqualStrings("if", t.errors()[1].opened_name);
}

test "a closed function body does not take the block around it" {
    var t = Test.init();
    defer t.deinit();

    // the end here closes the if, not the do. A body that popped twice would have
    // answered for the do as well and left the real one unnamed
    _ = try t.parse("do if x then function f() end");

    try t.expectExpected(0, .{ .token = .end });
    try std.testing.expectEqualStrings("if", t.errors()[0].opened_name);
    try std.testing.expectEqualStrings("do", t.errors()[1].opened_name);
}

test "a closed function body does not drop an enclosing block early" {
    var t = Test.init();
    defer t.deinit();

    // both blocks close cleanly here, so the do has to still be on the stack for
    // the end that never comes
    _ = try t.parse("do\n  if x then\n    function f() end\n  end\n");

    try t.expectExpected(0, .{ .token = .end });
    try std.testing.expectEqual(@as(u32, 0), t.errors()[0].opened_at.?.start);
    try std.testing.expectEqualStrings("do", t.errors()[0].opened_name);
}

test "a missing repeat reports until, not end" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("repeat print(1)");

    try t.expectExpected(0, .{ .token = .until });
    try std.testing.expectEqual(@as(u32, 0), t.errors()[0].opened_at.?.start);
}

test "a lexer failure has no expectation to record" {
    var t = Test.init();
    defer t.deinit();

    _ = try t.parse("local x = $");

    try t.expectKind(0, .invalid_char);
    try std.testing.expect(t.errors()[0].expected == null);
    try std.testing.expect(t.errors()[0].found == null);
}

test "the name of an open block is recorded, not looked up later" {
    var t = Test.init();
    defer t.deinit();

    // the parser has closed both blocks by the time the diagnostic is read, so the
    // name has to be recorded already
    _ = try t.parse("local function outer()\n  if x then\n    print(1)\n");

    try std.testing.expectEqualStrings("if", t.errors()[0].opened_name);
    try std.testing.expectEqualStrings("local function", t.errors()[1].opened_name);
}

test "an expectation that is not a closer names no block" {
    var t = Test.init();
    defer t.deinit();

    // then is wanted inside an open if, but the missing token is not what closes
    // it, so there is nothing to point back at
    _ = try t.parse("do if x end");

    try t.expectExpected(0, .{ .token = .then });
    try std.testing.expect(t.errors()[0].opened_at == null);
}
