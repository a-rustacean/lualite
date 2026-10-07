const std = @import("std");
const fehler = @import("fehler");
const lualite = @import("lualite");

const Lexer = lualite.Lexer;
const Token = lualite.Token;

fn kindMessage(kind: lualite.Diagnostic.Error.Kind) []const u8 {
    return switch (kind) {
        .unexpected_eof => "unexpected end of file",
        .unexpected_newline => "unexpected newline",
        .invalid_char => "invalid character",
        .malformed_number => "malformed number",
    };
}

fn kindHelp(kind: lualite.Diagnostic.Error.Kind) []const u8 {
    return switch (kind) {
        .unexpected_eof => "the input ended before the token was complete",
        .unexpected_newline => "strings cannot contain raw newlines; use '\\n' or a long string",
        .invalid_char => "this byte cannot start any Lua token",
        .malformed_number => "check the numeral against Lua's number grammar",
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

    const sample =
        \\local x = "unterminated
        \\local y = 3a
        \\local z = 0x
        \\local w = $5
    ;
    const source: []const u8 = sample;
    const filename: []const u8 = "<input>";

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
