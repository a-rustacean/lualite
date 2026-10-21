const std = @import("std");
const fehler = @import("fehler");
const lualite = @import("lualite");

const Token = lualite.Token;
const Diagnostic = lualite.Diagnostic;

// how each token kind reads in a message, built at comptime so the phrases are
// static strings. A keyword is its own name. A punctuator is spelled as written,
// since the lexer's names are about the left and right of a pair. The kinds with
// no source text of their own are described rather than quoted.
const token_words = blk: {
    @setEvalBranchQuota(100_000);
    const Words = struct { expected: []const u8, found: []const u8 };

    const info = @typeInfo(Token.Kind).@"enum";
    var words: [info.fields.len]Words = undefined;

    for (info.fields, 0..) |field, i| {
        const name = field.name;
        const kind: Token.Kind = @enumFromInt(i);
        _ = name;

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
    return Token.punctuationText(kind);
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

fn kindMessage(e: Diagnostic.Error) []const u8 {
    return switch (e.kind) {
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

        // semantic analysis, where `name` names what the check is about
        .break_outside_loop => "`break` outside a loop",
        .undefined_label => "no visible label",
        .duplicate_label => "label already defined",
        .goto_into_local_scope => "jump into the scope of a local",
        .assign_to_const => "attempt to assign to const variable",
        .vararg_outside_function => "cannot use `...` outside a vararg function",
        .unknown_attribute => "unknown attribute",
        .multiple_close_variables => "multiple to-be-closed variables in local list",
        .too_many_locals => "too many local variables",
        .too_many_upvalues => "too many upvalues",

        // the escape is spelled into the message, since which escape it was is the
        // whole of what went wrong
        .invalid_escape_sequence => "invalid escape sequence",
        .decimal_escape_too_large => "decimal escape too large",
        .hex_digit_expected => "hexadecimal digit expected",
        .unicode_escape_too_large => "UTF-8 value too large",
        .malformed_unicode_escape => e.name,
    };
}

// What each semantic check says about the name it is about. These need the name
// spelled into them, which is what the kind alone cannot say.
fn kindNamePhrase(e: Diagnostic.Error) ?[]const u8 {
    return switch (e.kind) {
        .undefined_label => std.fmt.bufPrint(
            &name_buffer,
            "no visible label '{s}' for `goto`",
            .{e.name},
        ) catch "no visible label for `goto`",
        .duplicate_label => std.fmt.bufPrint(
            &name_buffer,
            "label '{s}' already defined",
            .{e.name},
        ) catch "label already defined",
        .goto_into_local_scope => std.fmt.bufPrint(
            &name_buffer,
            "`<goto {s}>` jumps into the scope of local '{s}'",
            .{ e.name, e.opened_name },
        ) catch "this jump enters the scope of a local",
        .assign_to_const => std.fmt.bufPrint(
            &name_buffer,
            "attempt to assign to const variable '{s}'",
            .{e.name},
        ) catch "cannot assign to a const local",
        .unknown_attribute => std.fmt.bufPrint(
            &name_buffer,
            "unknown attribute '{s}'",
            .{e.name},
        ) catch "unknown attribute",

        // what each escape asked for, which is the useful half of the message
        .invalid_escape_sequence => std.fmt.bufPrint(
            &name_buffer,
            "invalid escape sequence '{s}'",
            .{e.name},
        ) catch "invalid escape sequence",
        .decimal_escape_too_large => std.fmt.bufPrint(
            &name_buffer,
            "decimal escape too large: '{s}'",
            .{e.name},
        ) catch "decimal escape too large",
        .unicode_escape_too_large => std.fmt.bufPrint(
            &name_buffer,
            "UTF-8 value too large: '{s}'",
            .{e.name},
        ) catch "UTF-8 value too large",

        else => null,
    };
}

// written by kindNamePhrase and handed straight to report, which prints before
// returning. Nothing holds the slice past that call, which is what lets the
// buffer be shared rather than per-diagnostic.
var name_buffer: [128]u8 = undefined;

fn kindHelp(e: Diagnostic.Error) []const u8 {
    return switch (e.kind) {
        .unexpected_eof => "the input ended before the token was complete",
        .unexpected_newline => "strings cannot contain raw newlines; use '\\n' or a long string",
        .invalid_char => "this byte cannot start any Lua token",
        .malformed_number => "check the numeral against Lua's number grammar",
        .unexpected_token => "nothing in Lua can go where this token is",
        .invalid_assignment_target => "a name, a field or an index can be assigned to, nothing else",
        .statement_after_return => "`return` has to be the last statement of its block",
        .nesting_too_deep => "this nests deeper than the parser follows; it is most likely unbalanced",

        .break_outside_loop => "only a `while`, a `for` or a `repeat` has something for `break` to leave",
        .undefined_label => "a `goto` can only jump to a label in the same function",
        .duplicate_label => "rename one of them",
        .goto_into_local_scope => "a jump cannot bring a local into scope, since the frame it sits in is gone by then",
        .assign_to_const => "drop the `<const>`, or declare a new local to hold the value",
        .vararg_outside_function => "add `...` to the parameter list of the function",
        .unknown_attribute => "the only attributes are `<const>` and `<close>`",
        .multiple_close_variables => "closing the first would close the others too",
        .too_many_locals => "fold some of them into a table",
        .too_many_upvalues => "fold some of them into a table",

        // an escape's own message already says what it wants, so what is left to
        // say is what a correct one looks like
        .invalid_escape_sequence => escapeHelp("the escapes Lua knows are written in the manual"),
        .decimal_escape_too_large => escapeHelp("a `\\ddd` is one byte, so at most `\\255`"),
        .hex_digit_expected => escapeHelp("`\\x` takes exactly two digits, and `\\u{...}` at least one"),
        .unicode_escape_too_large => escapeHelp("the largest code point is `\\u{7FFFFFFF}`"),
        .malformed_unicode_escape => escapeHelp("a code point is written `\\u{XXXX}`, braces and all"),

        .expected_token => unreachable,
    };
}

// written by kindHelp and handed straight to report, which prints before
// returning, so nothing holds the slice past that call
var escape_buffer: [96]u8 = undefined;

fn escapeHelp(text: []const u8) []const u8 {
    return std.fmt.bufPrint(
        &escape_buffer,
        "the escapes are `a` `b` `f` `n` `r` `t` `v` `\\\\` the quote `\\z` `\\x` `\\ddd` and `\\u{{...}}`; {s}",
        .{text},
    ) catch "the escape is not one Lua knows";
}

// Where each line starts, so an offset can be turned into a line and a column
// without rescanning the file. One linear pass up front, since a file with many
// diagnostics in it asks the same question once per diagnostic, and rescanning
// each time made a chunk with thousands of errors take minutes.
const Lines = struct {
    // the offset each line begins at, so `starts[i]` is where line `i + 1` does
    starts: []const usize,

    fn init(allocator: std.mem.Allocator, source: []const u8) !Lines {
        var starts: std.ArrayList(usize) = .empty;
        errdefer starts.deinit(allocator);

        try starts.append(allocator, 0);
        for (source, 0..) |c, i| {
            if (c == '\n') try starts.append(allocator, i + 1);
        }

        return .{ .starts = try starts.toOwnedSlice(allocator) };
    }

    fn deinit(lines: Lines, allocator: std.mem.Allocator) void {
        allocator.free(lines.starts);
    }

    // the last line that begins at or before offset
    fn lineAt(lines: Lines, offset: usize) usize {
        var low: usize = 0;
        var high: usize = lines.starts.len;

        // the greatest start that is still <= offset
        while (low + 1 < high) {
            const mid = low + (high - low) / 2;
            if (lines.starts[mid] <= offset) low = mid else high = mid;
        }

        return low;
    }

    fn lineCol(lines: Lines, source: []const u8, offset: usize) struct { line: usize, col: usize } {
        const at = @min(offset, source.len);
        const line = lines.lineAt(at);
        return .{ .line = line + 1, .col = at - lines.starts[line] + 1 };
    }
};

// fehler columns are inclusive and a span crossing newlines is underlined to
// the end of each line, so clamp a multi-line span to the end of its first line
fn sourceRange(
    filename: []const u8,
    lines: Lines,
    source: []const u8,
    span: Token.Span,
) fehler.SourceRange {
    const start = lines.lineCol(source, span.start);
    const end_off = if (span.end > span.start) span.end - 1 else span.start;
    var end = lines.lineCol(source, end_off);

    if (end.line > start.line) {
        var i: usize = span.start;
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        end = lines.lineCol(source, if (i > span.start) i - 1 else span.start);
    }

    return fehler.SourceRange.span(filename, start.line, start.col, end.line, end.col);
}

pub fn main(init: std.process.Init) !void {
    var requested_exit_status: ?u8 = null;
    defer if (requested_exit_status) |status| std.process.exit(status);
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    const argv = try std.process.Args.toSlice(init.minimal.args, arena);
    const check_only = argv.len > 1 and std.mem.eql(u8, argv[1], "--check");
    const file_arg = if (check_only)
        (if (argv.len > 2) argv[2] else null)
    else if (argv.len > 1)
        argv[1]
    else
        null;

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
        // The arena, since the source outlives the parse and is never freed by
        // hand. No size limit: real Lua files run to megabytes, and a cap that
        // reports itself as a read failure reads as a bug rather than a policy.
        source = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .unlimited) catch |err| {
            // Anything that goes wrong reading the file is the reader's business,
            // not a trace through the parser's dependencies
            std.debug.print("lualite: cannot read {s}: {t}\n", .{ path, err });
            return;
        };
        filename = path;
    }

    const lines = try Lines.init(arena, source);

    var reporter: fehler.ErrorReporter = fehler.ErrorReporter.init(allocator);
    defer reporter.deinit();
    try reporter.addSource(filename, source);

    var diagnostics: Diagnostic.Reporter = .{ .gpa = allocator };
    defer diagnostics.errors.deinit(allocator);

    // the parse owns its nodes. The diagnostics live outside it so they can
    // outlive the parser and be rendered at the end.
    var parse_arena: std.heap.ArenaAllocator = .init(allocator);
    var parser = lualite.Parser.fromSource(source, &parse_arena, &diagnostics);
    defer parser.deinit();

    // the parser lexes as it goes, so a lexer error and a syntax error both land in
    // the same reporter in the order they were found
    const chunk = parser.parseChunk() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // whatever went wrong is already in the reporter
        error.ReportFailed, error.ParserFailed => {
            reportAll(&reporter, &diagnostics, lines, filename, source);
            return;
        },
    };

    // The syntax tree is recovered rather than abandoned, so semantic analysis
    // still runs on whatever came out. A name the walk cannot resolve is
    // reported and walked past, which is why a file with syntax errors picks up
    // checks for the parts that did parse.
    var semantics = lualite.Semantic.analyze(parse_arena.allocator(), &diagnostics, &chunk) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // whatever went wrong is already in the reporter
        error.ReportFailed => return,
    };
    // where `error` points when the chunk is running, the way luaL_loadfile
    // registers a file: the name is the file with an `@` in front of it
    semantics.source = source;
    semantics.chunk_name = std.fmt.allocPrint(parse_arena.allocator(), "@{s}", .{filename}) catch return error.OutOfMemory;

    if (diagnostics.errors.items.len == 0 and !check_only) {
        var tracker: lualite.Object.Tracker = .init(allocator);
        defer tracker.deinit();
        var interner = try lualite.Str.Interner.init(allocator, &tracker);
        defer interner.deinit();
        var environment = try lualite.VM.Environment.init(allocator, &tracker);
        defer environment.deinit();
        var vm = try lualite.VM.VM.init(allocator, &interner, &semantics, &tracker, environment.table);
        defer vm.deinit();
        vm.io = init.io;
        vm.environ_map = init.environ_map;

        var stdout_buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
        vm.writer = &stdout.interface;
        var stderr_buffer: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(init.io, &stderr_buffer);
        vm.stderr = &stderr.interface;
        _ = vm.run(&chunk) catch |err| switch (err) {
            error.ExitRequested => requested_exit_status = vm.exit_status orelse 0,
            else => {
                // `lua.c`'s `report`: the value an error raised carries its own
                // position, and one that is not a string says so instead
                if (vm.exec.thrown_error) |thrown| {
                    const message = if (thrown == .string) thrown.string.slice() else "(error object is not a string)";
                    std.debug.print("lualite: {s}\n", .{message});
                } else if (vm.exec.error_offset) |offset| {
                    const location = lines.lineCol(source, offset);
                    std.debug.print("{s}:{d}:{d}: runtime error: {s}\n", .{ filename, location.line, location.col, @errorName(err) });
                } else {
                    std.debug.print("lualite: runtime error: {s}\n", .{@errorName(err)});
                }
                stderr.flush() catch {};
                requested_exit_status = 1;
            },
        };
        stdout.flush() catch return error.OutputFailed;
        stderr.flush() catch return error.OutputFailed;
    }

    reportAll(&reporter, &diagnostics, lines, filename, source);
}

fn reportAll(
    reporter: *fehler.ErrorReporter,
    diagnostics: *const Diagnostic.Reporter,
    lines: Lines,
    filename: []const u8,
    source: []const u8,
) void {
    for (diagnostics.errors.items) |e| reportOne(reporter, lines, filename, source, e);

    // A capped list that reads as the whole truth is worse than a long one, since
    // the reader stops looking for what is missing.
    if (!diagnostics.truncated()) return;

    reporter.report(fehler.Diagnostic.init(.err, std.fmt.bufPrint(
        &more_buffer,
        "and {d} more",
        .{diagnostics.dropped},
    ) catch "and more"));
}

// written by reportAll and handed straight to report, which prints before
// returning, so nothing holds the slice past that call
var more_buffer: [64]u8 = undefined;

fn reportOne(
    reporter: *fehler.ErrorReporter,
    lines: Lines,
    filename: []const u8,
    source: []const u8,
    e: Diagnostic.Error,
) void {
    // the message is the expectation where there is one, since that is the part
    // the reader can act on, and the name-spelling one where the check is about
    // a name rather than a kind
    const message = if (e.expected) |expected|
        expectedMessage(expected)
    else if (kindNamePhrase(e)) |phrase|
        phrase
    else
        kindMessage(e);

    reporter.report(
        fehler.Diagnostic.init(.err, message)
            .withRange(sourceRange(filename, lines, source, e.span))
            .withHelp(helpFor(lines, source, e)),
    );
}

// What to say under the message. For a closer that never came, naming the block
// left open beats naming the token the parser happened to stop on.
fn helpFor(lines: Lines, source: []const u8, e: Diagnostic.Error) []const u8 {
    return switch (e.kind) {
        // `opened_at` here is the block that never closed
        .expected_token => if (e.opened_at) |opened|
            unclosedHelp(lines, source, e.opened_name, opened)
        else
            foundOrKind(e),

        // where the other label already is
        .duplicate_label => if (e.opened_at) |opened|
            onLine(lines, source, "the other one", opened)
        else
            kindHelp(e),

        // which local the jump would have brought into scope, which is the more
        // useful thing to point at than the goto itself already is
        .goto_into_local_scope => if (e.opened_at) |opened|
            std.fmt.bufPrint(
                &help_buffer,
                "local '{s}' is declared on line {d}",
                .{ e.opened_name, lines.lineCol(source, opened.start).line },
            ) catch "the local it names is declared further down"
        else
            kindHelp(e),

        else => foundOrKind(e),
    };
}

fn foundOrKind(e: Diagnostic.Error) []const u8 {
    if (e.found) |found| return foundMessage(found);
    return kindHelp(e);
}

// e.g. "the other one is on line 3"
fn onLine(lines: Lines, source: []const u8, what: []const u8, at: Token.Span) []const u8 {
    return std.fmt.bufPrint(
        &help_buffer,
        "{s} is on line {d}",
        .{ what, lines.lineCol(source, at.start).line },
    ) catch "the other one is elsewhere in the file";
}

// e.g. "to close the `if` that starts on line 4"
fn unclosedHelp(lines: Lines, source: []const u8, name: []const u8, opened: Token.Span) []const u8 {
    return std.fmt.bufPrint(
        &help_buffer,
        "to close the `{s}` that starts on line {d}",
        .{ name, lines.lineCol(source, opened.start).line },
    ) catch "to close a block that starts earlier in the file";
}

// written by unclosedHelp and handed straight to report, which prints before
// returning. Nothing holds the slice past that call, which is what lets the
// buffer be shared rather than per-diagnostic.
var help_buffer: [128]u8 = undefined;
