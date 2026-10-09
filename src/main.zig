const std = @import("std");
const fehler = @import("fehler");
const lualite = @import("lualite");

const Lexer = lualite.Lexer;
const Token = lualite.Token;
const Diagnostic = lualite.Diagnostic;

// how each token kind reads in a message, built at comptime so the phrases are
// static strings. A keyword is its own name. A punctuator is spelled as written,
// since the lexer's names are about the left and right of a pair. The kinds with
// no source text of their own are described rather than quoted.
const token_words = blk: {
    @setEvalBranchQuota(100_000);
    const Words = struct { expected: []const u8, found: []const u8 };

    var words: [std.meta.fields(Token.Kind).len]Words = undefined;

    for (std.meta.fields(Token.Kind), 0..) |field, i| {
        const kind = @field(Token.Kind, field.name);

        words[i] = switch (kind) {
            .eof => .{
                .expected = "expected a token",
                .found = "found the end of the input here",
            },
            .ident => .{
                .expected = "expected a name",
                .found = "found a name here",
            },
            .decimal, .float => .{
                .expected = "expected a numeral",
                .found = "found a numeral here",
            },
            .str, .long_str => .{
                .expected = "expected a string",
                .found = "found a string here",
            },

            // keywords, which are their own names
            .@"and",
            .@"break",
            .do,
            .@"else",
            .elseif,
            .end,
            .false,
            .@"for",
            .function,
            .goto,
            .@"if",
            .in,
            .local,
            .nil,
            .not,
            .@"or",
            .repeat,
            .@"return",
            .then,
            .true,
            .until,
            .@"while",
            => |keyword| .{
                .expected = std.fmt.comptimePrint("expected `{s}`", .{@tagName(keyword)}),
                .found = std.fmt.comptimePrint("found `{s}` here", .{@tagName(keyword)}),
            },

            // punctuators, which are not
            else => |punctuation| .{
                .expected = std.fmt.comptimePrint("expected `{s}`", .{punctuation_text(punctuation)}),
                .found = std.fmt.comptimePrint("found `{s}` here", .{punctuation_text(punctuation)}),
            },
        };
    }

    break :blk words;
};

fn token_words_of(kind: Token.Kind) @TypeOf(token_words[0]) {
    return token_words[@intFromEnum(kind)];
}

// the source text of a punctuator
fn punctuation_text(kind: Token.Kind) []const u8 {
    return switch (kind) {
        .plus => "+",
        .minus => "-",
        .star => "*",
        .slash => "/",
        .slash2 => "//",
        .percent => "%",
        .caret => "^",
        .amp => "&",
        .tilde => "~",
        .tilde_eq => "~=",
        .pipe => "|",
        .shift_left => "<<",
        .shift_right => ">>",
        .eq => "=",
        .eq2 => "==",
        .lte => "<=",
        .gte => ">=",
        .hash => "#",
        .dot => ".",
        .dot2 => "..",
        .dot3 => "...",
        .langle => "<",
        .lbrack => "[",
        .lcurly => "{",
        .lparen => "(",
        .rangle => ">",
        .rbrack => "]",
        .rcurly => "}",
        .rparen => ")",
        .colon => ":",
        .colon2 => "::",
        .semicolon => ";",
        .comma => ",",
        .eof, .ident, .decimal, .float, .str, .long_str => unreachable,
        else => @tagName(kind),
    };
}

// what the parser wanted. A token is named as itself, the rest are the classes
// of thing that span several tokens.
fn expectedMessage(expected: Diagnostic.Error.Expected) []const u8 {
    return switch (expected) {
        .token => |kind| token_words_of(kind).expected,
        .expression => "expected an expression",
        .statement => "expected a statement",
        .arguments => "expected an argument list: `( ... )`, `{ ... }` or a string",
    };
}

fn foundMessage(found: Token.Kind) []const u8 {
    return token_words_of(found).found;
}

fn kindMessage(kind: lualite.Diagnostic.Error.Kind) []const u8 {
    return switch (kind) {
        .unexpected_eof => "unexpected end of file",
        .unexpected_newline => "unexpected newline",
        .invalid_char => "invalid character",
        .malformed_number => "malformed number",
        // the expectation carries the message instead, and there is always one
        .expected_token => unreachable,
        .unexpected_token => "unexpected symbol",
        .invalid_assignment_target => "cannot assign to this",
        .statement_after_return => "statement after `return`",
        .nesting_too_deep => "too much nesting",
    };
}

fn kindHelp(kind: lualite.Diagnostic.Error.Kind) []const u8 {
    return switch (kind) {
        .unexpected_eof => "the input ended before the token was complete",
        .unexpected_newline => "strings cannot contain raw newlines; use '\\n' or a long string",
        .invalid_char => "this byte cannot start any Lua token",
        .malformed_number => "check the numeral against Lua's number grammar",
        .unexpected_token => "nothing in Lua can go where this token is",
        .invalid_assignment_target => "a name, a field or an index can be assigned to, nothing else",
        .statement_after_return => "`return` has to be the last statement of its block",
        .nesting_too_deep => "this nests deeper than the parser follows; it is most likely unbalanced",
        .expected_token => unreachable,
    };
}

fn lineCol(source: []const u8, offset: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;
    for (source[0..@min(offset, source.len)]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

// fehler columns are inclusive and fehler treats a span crossing newlines by
// underlining each line to its end, so clamp multi-line spans to the end of
// the first line.
fn sourceRange(
    filename: []const u8,
    source: []const u8,
    span: Token.Span,
) fehler.SourceRange {
    const start = lineCol(source, span.start);
    const end_off = if (span.end > span.start) span.end - 1 else span.start;
    var end = lineCol(source, end_off);

    if (end.line > start.line) {
        var i: usize = span.start;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        end = lineCol(source, if (i > span.start) i - 1 else span.start);
    }

    return fehler.SourceRange.span(filename, start.line, start.col, end.line, end.col);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const file_arg = if (argv.len > 1) argv[1] else null;

    const sample =
        \\local greet = function(name)
        \\  return "hi " .. name
        \\end
        \\local x = 3a
        \\greet("world")
        \\local y = = 1
        \\print(greet)
    ;

    var source: []const u8 = sample;
    var filename: []const u8 = "<input>";
    if (file_arg) |path| {
        source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1 << 20));
        filename = path;
    }

    var reporter: fehler.ErrorReporter = fehler.ErrorReporter.init(allocator);
    defer reporter.deinit();
    try reporter.addSource(filename, source);

    var diag_reporter: lualite.Diagnostic.Reporter = .{ .gpa = allocator };
    defer diag_reporter.errors.deinit(allocator);

    var lexer = Lexer{ .source = source, .current_char_idx = 0 };

    while (true) {
        const start_errs = diag_reporter.errors.items.len;
        const token = lexer.nextToken(&diag_reporter) catch |err| {
            if (err == error.LexerFailed) {
                // pick up everything reported since the last good token and
                // skip past the offending span to collect more diagnostics
                var next_idx = lexer.current_char_idx + 1;
                for (diag_reporter.errors.items[start_errs..]) |e| {
                    reportOne(&reporter, filename, source, e);
                    if (e.span.end > next_idx) next_idx = e.span.end;
                }
                lexer.current_char_idx = next_idx;
                continue;
            }
            return err;
        };

        if (token.kind == .eof) break;
    }

}

fn reportOne(
    reporter: *fehler.ErrorReporter,
    filename: []const u8,
    source: []const u8,
    e: lualite.Diagnostic.Error,
) void {
    reporter.report(
        fehler.Diagnostic.init(.err, kindMessage(e.kind))
            .withRange(sourceRange(filename, source, e.span))
            .withHelp(kindHelp(e.kind)),
    );
}
