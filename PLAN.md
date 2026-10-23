# lualite — roadmap to a Lua 5.4 runtime

## Where we are

The front-end is complete for its scope and has no stubs:

- `src/Lexer.zig` — zero-alloc lexer over a borrowed source slice. Full Lua 5.4
  numerals (including hex floats), long strings at any `=` level, `\z`, all 22
  keywords, every operator. Reports the four lexer diagnostics in
  `Diagnostic.Error.Kind`.
- `src/Parser.zig` + `src/Parser/*.zig` — recovering parser. `synchronize`
  resumes at the next statement start, a 200-deep recursion cap mirrors
  `LUAI_MAXCCALLS`, and an open-block stack lets a missing `end` point back at
  the keyword that opened the block.
- `src/Ast.zig` — the tree, arena-allocated, every construct carrying the spans
  a later pass might want.
- `src/Diagnostic.zig` + `src/main.zig` — diagnostics collected across the whole
  file and rendered at the end through `fehler`.
- `src/Semantic.zig` + `src/Semantic/*.zig` — the resolver, its scope tree and
  the checks Lua performs. See Phase 1 below.

262 tests pass (`zig build test`), 68 differential cases against a reference Lua
5.4 agree (`differential/run.sh`), 2393 corpus files agree (`corpus/run.sh`), and
17 runtime cases compare stdout, stderr and exit status against the reference
(`runtime/run.sh`).
`grep` for `TODO`, `unimplemented`, `@panic` across `src/` finds nothing.

**In progress:** a simple tree-walking VM evaluates the resolved AST directly.
It currently handles literals, number and string operations, locals, globals,
table construction/indexing/assignment, recursive functions and closures,
dotted and method definitions, table/string call sugar, and `<close>` locals
with `__close` handlers. Varargs and
multiple-result expansion work in
calls, returns, local and assigned expression lists, and the final table field.
Resolved `goto` statements support forward and backward jumps and unwind nested
blocks or loops to their target label.
Base functions are first-class values in `_G`, with `_VERSION` set to `Lua 5.4`.
Parenthesized calls adjust to one value; `assert`, `select`, and `next` preserve
their multiple results, and `print` expands its final argument. Generic `for`
also supports first-class `pairs`, `ipairs`, and `next` iterators, including
storing and calling their returned iterator functions. `pcall` catches runtime
errors, preserves the value passed to `error`, and returns all successful call
results. The CLI provides `print`, `type`, `tostring`, `tonumber`, `assert`,
`rawequal`, `rawget`, `rawset`, `select`, `next`, `pairs`, `ipairs`, `pcall`,
`xpcall`, and `error`. The `table` library provides `insert`, `remove`, `concat`,
`sort`, `unpack`, `pack`, and `move`; `rawlen` supports strings and tables. The
`string` library provides byte-oriented `len`, `sub`, `rep`, `byte`, `char`,
`format`, pattern-aware `find`, `match`, `gmatch`, `gsub`, `upper`, `lower`, and
`reverse`; string methods such as
`("text"):upper()` work. Runtime errors follow the reference's wording and
positions, and `string.format` delegates its numeric conversions to the C
library as the reference does. The `io` library covers files and the standard
streams, and `os` covers time, environment, and simple file operations. What
remains open is mostly edge-case compatibility, listed under Phase 6.

## Gaps to close in the front-end first

These are on the list before runtime work rather than after, because the value
model would otherwise bake the mistakes in. Items 2 to 5 are
closed; the corpus run and the differential harness in `corpus/` and
`differential/` are what found them.

1. ~~**Numbers are `f64`.**~~ **Closed** in Phase 2 increment 1. Lua 5.4 is
   integer-or-float: `1` and `1.0` are different types, `//` and the bitwise
   operators require integers, `math.type` tells them apart, and integer overflow
   wraps rather than becoming `inf`. `Ast.NumberExpression.value` is a tagged
   `Number` now, filled in by `num.parse` in `src/Parser/Expression.zig`, and the
   semantics live in `src/Number.zig`. Verified against 84 cases generated from
   the reference.
   - The `i`, `f` and `n` suffixes belong here rather than being a separate gap.
     The lexer rejects all three as malformed numbers, and so does Lua 5.4.9, so
     nothing is broken today; the suffix is simply part of what this item has to
     decide, and the answer is that 5.4 has none of them.
2. ~~**String decoding is not Lua-faithful.**~~ **Closed.** The decoder now
   follows `read_string` in `llex.c`: an unknown escape, a `\ddd` over 255, a
   `\x` without two digits, a `\u` without its braces and a code point past
   `0x7FFFFFFF` are each refused with their own diagnostic, and `\u{...}`
   decodes to UTF-8 with `luaO_utf8esc`. A bad escape is reported and the decoder
   carries on, so it costs the rest of its string rather than the rest of the
   chunk.
   - Long strings normalize CR, LF, and CRLF to `\n`, and drop the first
     newline sequence after the opening delimiter, matching Lua 5.4.
3. ~~**No shebang handling.**~~ **Closed.** `scan` skips a first line beginning
   with `#`, not just `#!` — `skipcomment` in `lauxlib.c` checks for the `#`
   alone, which is a detail worth having read off the source rather than guessed.
4. ~~**No diagnostic cap.**~~ **Closed.** `Diagnostic.Reporter` keeps the first
   100 and counts the rest, and the CLI says how many were dropped. This became
   load-bearing rather than tidy: with the slots widened to `u32` (item 5) the
   overflow stopped being a crash, and the chunk it fixed then took about seven
   hours to render fifty thousand diagnostics.
5. ~~**Slots were `u16`, and a chunk with 65536 locals in one function
   overflowed.**~~ **Closed.** `slot`, `n_actvar` and `frame_size` are `u32`.
   Lua's own caps stay `u16` since they are Lua's constants rather than counts.
   Found by hand rather than by the corpus, and worth noting that neither harness
   would: it needs a generated file, and the corpus has none.

Two more came out of the same review and are also closed: the front end exits
non-zero with a stack trace on any file over 1 MiB, and a `\` before a CRLF
inside a short string was an error where Lua reads it as one newline.

## Phase 1 — semantic analysis

**Done.** `src/Semantic.zig` walks the AST and builds a scope tree, assigning
every name a local slot or an upvalue index. Kept as a pass over the AST rather
than folded into the parser: the parser is purely syntactic and cleanly so, and a
resolver has a different error surface.

Reports the checks Lua performs and lualite used to accept silently:

- `break` outside a loop
- `goto` to an undefined label
- a label defined twice
- a `goto` jumping into the scope of a local
- assigning to a `<const>` local
- `...` outside a vararg function
- unknown attributes (`local x <bogus>`)
- more than one `<close>` variable in a local list
- 200 local variables and 255 upvalues per function

Two subtleties the differential harness caught, both read off `lparser.c` rather
than guessed:

- **A label at the end of a block is measured against the block's entry**, not
  against the locals live where it is written, so
  `do goto out; local y = 2; ::out:: end` is legal while adding one statement
  after the label makes it an error.
- **`until` is not `end`.** The same rule does not apply to a `repeat` body, since
  a label at the end of one is followed by the `until` condition, so its locals do
  still count.
- **A label claims only the gotos inside its own block.** Two labels of one name,
  an inner and an outer, are not a duplicate, and a goto written before both is
  claimed by whichever comes first in the enclosing chain. The corpus run found
  this one refusing `script/vm/compiler.lua` from lua-language-server, which
  reuses a label name across nested blocks, so it was a false rejection on code
  two of the corpus sources ship.

Which means the walk has to know each construct's terminator tokens, and the
statement walk has to know whether a statement is the last in its block.

Output is a `Semantic.Program`: the functions with their parameters, upvalues and
frame sizes, the block tree with its locals and labels, and a resolution per name
keyed by where it was written.

## Phase 2 — value model

`Value` as a tagged union: nil, bool, int (`i64`), float (`f64`), string, table,
function, thread.

- Interned short strings behind a hash table, so string equality is a pointer
  compare and table keys are cheap.
- Tables with an array part plus a hash part, which is what `next`/`ipairs` and
  the `#` operator need to behave like Lua's.
- A garbage collector. The choice of collector constrains object layout, so it
  gets decided here rather than deferred: bump allocation for the prototype,
  mark-sweep with a write barrier before closures and threads make cycles
  reachable.

Independent of Phase 1, so the two can proceed in parallel.

### Increment 1 — numbers, strings, object headers (done)

- `src/Number.zig` — the tagged integer/float split, which gap 1 above is.
  Wrapping integer arithmetic, `/` and `^` always float, floored `//` and `%`,
  bitwise operators over integral floats but not strings, and Lua's `%.14g`
  float formatting. `Ast.NumberExpression.value` is a `Number` now, and the
  parser fills it in through `num.parse`. Checked against 84 cases generated
  from the reference (`src/Number.golden.*`).
- `src/Object.zig` — the header every heap object starts with (`kind`, `mark`,
  and the list links) plus the tracker that owns them. Stop-the-world
  mark-sweep means a value can be overwritten with no bookkeeping and no write
  barrier; the collector implementation is in `src/Collector.zig`.
- `src/Str.zig` — short strings interned behind a content-keyed table at Lua's
  40-byte split, laid out in a bump arena so a pointer stays a key; long
  strings are not interned and compare by content, the same trade Lua makes.
  Hashed with `luaS_hash` at a zero seed. The reference seeds that hash per
  state from time and ASLR, so `pairs` over string keys comes out in a different
  order on every run and there is no order to match. Integer and float keys do
  not go through it and their order is reproducible.
- `src/Value.zig` — the union, `type`/`math.type`, `==` across the two number
  types, truthiness, AST function closures, and shared captured cells. Collector
  tracing follows values held by closure captures.

The table array/hash parts, Lua-compatible key normalization, `#`, iteration,
and rehashing are implemented in `src/Table.zig`. `src/Collector.zig` provides
stop-the-world mark-and-sweep with roots supplied explicitly at a safepoint.
Short interned strings remain arena-owned for the interner lifetime. Still open
is `--dump-literals`, so the corpus can be re-run against tagged numbers rather
than just the ones the golden file names.

## Phase 3 — AST runtime (in progress)

The runtime starts as a tree-walker over the existing AST and semantic
resolution data. This keeps the execution model direct and easy to inspect. Add
an IR only when it has a concrete use, such as simplifying control flow or
supporting a second backend.

`src/VM.zig` evaluates the resolved AST directly with a step limit, including
closures with shared upvalue cells, dotted and method definitions, and
method-call and table/string call sugar. Captured locals get a fresh cell per
declaration, so closures made in a loop body capture each iteration separately.
Varargs and multiple-result expansion work in common list contexts. Runtime
behavior includes table metatables, arithmetic metamethods, generic iteration,
protected calls, and the libraries described in Phase 5. Free names resolve
through lexical `_ENV` bindings, and closures preserve their environment when it
is inherited through nested functions. Runtime errors follow the reference
wording and blame the right operand, carrying the `getobjname` suffixes of
`ldebug.c` such as `(constant 'x')` and `(field 'missing')` when a name is
traceable; native errors add a position only when a Lua function called them
directly, the way `luaL_where` sees it. Some Lua runtime semantics, less common multiple-result
contexts, and broad standard library coverage remain open.

Indexing failures follow `luaV_finishget`/`finishset`: the message names only
the value at the head of the chain — `attempt to index a nil value (field 'a')`
even when it was `t.a.b` that failed — and the traceable suffix follows
`getobjname`, with locals and upvalues by name, constants by value, globals
through their key, and parentheses transparent. A global name is looked up
through `_ENV`, so a nil environment is reported as the binding it is: a
shadowing local as `(local '_ENV')`, a function's own environment as
`(upvalue '_ENV')`. Metatable chains stop at `MAXTAGLOOP` (2000) with
`'__index' chain too long; possible loop` (or `'__newindex'`). The position
such an error carries is the caller's own line: it survives calls into
`__index` functions and `pcall`, the way the reference reads `currentline`
from the caller's frame rather than the callee's last expression.

Dynamic text chunks are now supported through `load`, `loadfile`, and `dofile`.
Each compiled chunk keeps its parse arena and semantic program alive for
returned closures, and `load` can bind an explicit environment. A reader's
pieces join the way the reference joins them: a number is appended like a
string, `nil` or an empty string ends the chunk and compiles what there is, and
anything else stops with `reader function must return a string`. What the
caller then sees follows `lua_load`'s errfunc: called from the main chunk the
message carries that chunk's line *and* the top-level handler's traceback
inside it, while under `pcall` it comes back bare — no position, no traceback —
and a table the reader raised comes back as the same table. Such failures are
returned as `nil, message`, not raised. A refused parse renders its expected
side the way `luaX_token2str` does: `<name> expected near '1'`, with the class
tokens (`<eof>`, `<string>`, `<integer>`, `<number>`) bare and keywords and
punctuators quoted. Binary chunks are refused in both directions — by mode
(`attempt to load a text chunk (mode is 'x')`) and by header before the body is
read — and `string.dump` refuses the functions it is given, so no dump from the
reference can execute here.

Numeric `for` follows `forprep` in `lvm.c`. An integer initial value *and*
step take the integer path, where only the limit converts: floored, or raised
to a ceil for a descending loop, numeric strings included, with a float outside
the integer range clipped to the nearest bound or skipping the loop entirely.
Anything else takes the float path, where all three values become floats
whatever could have been integral, so `for i = 1, "3", "1"` counts `1.0, 2.0,
3.0` and a float step makes the control variable float even with integer ends.
The float path checks limit, then step, then initial value, and a value that
will not convert names itself through `luaG_forerror`:
`bad 'for' limit (number expected, got string)`, with `'for' step is zero`
after the conversions — and an integer path still checks the step first, the
way the reference orders it.

Coroutines are `std.Io.fiber` threads sharing one VM between them: a yield
parks the whole Zig call stack on its own host stack and the next resume
continues inside it. `create`, `resume`, `yield`, `status`, `running`,
`isyieldable`, `close` and `wrap` behave as in 5.4.9, including error returns
from `resume`, positions on `wrap` errors, `__close` handlers during `close`,
and `cannot resume dead/non-suspended coroutine` guards.

**Done when:** the CLI executes the language subset consistently and reports
runtime errors with source locations.

## Phase 5 — minimal standard library

Enough to run real scripts:

- base: `print`, `type`, `tostring`, `tonumber`, `pairs`, `ipairs`, `next`,
  `select`, `error`, `pcall`, `xpcall`, `assert`, `rawget`, `rawset`, `rawequal`,
  `rawlen`, `setmetatable`, `getmetatable`, `warn`, `load`, `loadfile`, `dofile`,
  `collectgarbage`
- `string`: `format`, `len`, `sub`, `rep`, `byte`, `char`, `upper`, `lower`,
  `find`, `gmatch`, `match`, `reverse`, `gsub`
- `table`: `insert`, `remove`, `concat`, `sort`, `pack`, `move`, `unpack`
- `math`: numeric constants and common scalar functions
- `utf8`: `char`, `len`, `codepoint`, `offset`, `codes`, and `charpattern`

Implemented so far: all seven listed `table` functions; string `len`, `sub`, `rep`,
`byte`, `char`, common printf-style `format`, pattern-aware `find`, `match`,
`gmatch`, `gsub`, `upper`, `lower`, `reverse`, and binary `pack`, `unpack`, and
`packsize`; and math
`abs`, `floor`, `ceil`, `sqrt`, `fmod`, `max`, `min`, `tointeger`, `type`,
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `exp`, `log`, `deg`, `rad`,
`modf`, unsigned `ult`, `random`, and `randomseed`,
with `pi`, `huge`, `maxinteger`, and `mininteger`. The random functions use
Lua 5.4's xoshiro256** state initialization and unbiased integer projection;
`random(0)` returns a full signed integer. Base `setmetatable` and
`getmetatable` are implemented with protected metatables and table `__index` /
`__newindex`, `__len`, arithmetic, concatenation, comparison, equality, and
unary metamethod behavior, plus callable tables (`__call`), `__tostring`, and
the table iteration hook `__pairs`. Strings share the standard string-library
metatable, so ordinary string indexing, assignment hooks, and `getmetatable`
use Lua's type-level metatable behavior.
The `os` library provides `clock`, `time`, `date`, `difftime`, `getenv`,
`execute` (through the host shell), `remove`, `rename`, `setlocale`, `exit`, and
`tmpname`. `setlocale` answers without a locale database: `"C"` is the only
locale this runtime carries and the one every category starts in, so a query
and a request for `"C"` answer `"C"` while any other name — including the
environment lookup `""` performs — answers nil. `tmpname` follows the POSIX
`mkstemp` template, `/tmp/lua_` plus six characters drawn from a state of its
own (so `math.random`'s stream is untouched), created exclusively and left
closed on disk for the caller to remove.
`date` supports UTC conversion, date tables, and common `strftime` directives;
`time(table)` normalizes and updates calendar fields using UTC. Host-local
timezone conversion, locale, and process-control functions remain open. File
operation errors use Zig's portable error names and a best-effort errno mapping.
`clock` uses the host process CPU clock, `time` uses Unix epoch seconds, and
`getenv` reads the environment passed by the CLI.
The first `io` slice grew into the whole library: `io.open` in read, update,
truncating-write, and append modes; file `read` (`*n`, `*l`, `*L`, `*a`, byte
counts, and several formats at once), `write`, `flush`, `close`, `seek`,
`lines`, and `setvbuf`; `io.open`, `io.tmpfile`, `io.write`, `io.flush`,
`io.close`, `io.type`, `io.read`, `io.input`, `io.output`, and `io.lines`.
Both `io.write` and `file:write` format numbers the way `g_write` does —
integers as digits and floats through `%.14g` with no `.0`, so `1.0` goes out
as `1` where `tostring` keeps the suffix.
File handles are tables over an internal `FileHandle` with a protected
metatable whose `__index` carries the methods, whose `__close` closes, and
whose `__name` is `FILE*` so error messages name the type the way the
reference names its userdata. `io.stdin`, `io.stdout`, and `io.stderr` are the
default files until `io.input`/`io.output` move the defaults, and the two
caches are kept apart so `io.stdout` still means the stream after
`io.output(f)`. Errors follow `liolib.c` closely: `tofile` reports `FILE*
expected, got X` or `attempt to use a closed file`, closing a standard file
answers `nil, "cannot close standard file"`, a failing `opencheck` (what
`io.input(name)`, `io.output(name)`, and `io.lines(name)` use) raises
`cannot open file '%s' (%s)` while plain `io.open` returns `nil, path:
strerror, errno`, and a negative read count tries for a buffer it cannot have
and fails with `not enough memory`. Update files (`w+`, `r+`, `a+`) share one
position between their sides the way a C `FILE*` does: a read flushes a
pending write and starts where it ended, a write jumps to where the reads left
off, and `seek()` reports whichever side last moved. Line iterators are bound
functions over the handle, end without a value at EOF, raise `file is already
closed` when reused after a close, and `io.lines(name)` hands the file back
as its fourth result so a generic for can close it. File handles close when
explicitly closed, when their Lua table is collected, or when the VM shuts
down, and `io.tmpfile()` makes a temporary read/write file removed on close.
The UTF-8 library provides Lua's one-to-six-byte encoding, strict and lax
decoding, byte-indexed length and codepoint access, offsets, iterator triples,
and the standard byte-pattern constant. The formatter covers
Lua's conversions, flags, width and precision, `%q` over every literal type,
and `%p`; the numeric conversions call the C library's `snprintf` exactly as
`l_sprintf` in lstrlib.c does, so rounding, `%a`, and the flag corners are the
platform's own, and the reference's conversion checks (`invalid conversion`,
flag and precision restrictions) are reproduced. The pattern matcher
covers byte classes, sets, anchors, quantifiers,
captures, balanced items (`%b`), frontiers (`%f`), and capture references.
Binary string formats support integer and floating-point values, endian and
alignment controls, fixed and terminated strings, length-prefixed strings, and
packsize rejection for variable-length formats.
The base warning function honors `@on` and `@off` and writes to stderr. The
base `load`, `loadfile`, and `dofile` functions compile and execute text chunks;
binary chunks are not supported, and no-argument `loadfile`/`dofile` read
stdin. `collectgarbage` supports collect, step, stop, restart, count, and
isrunning. Automatic and requested sweeps run at interpreter statement
boundaries to keep temporary AST evaluation values safe. Sweeps are postponed
through nested interpreted calls because caller expression temporaries are held
in the host stack; they resume after the outer statement. The string and file
metatables are explicit roots because only VM fields reach them; without that,
a full collect frees the file metatable and later file handles index freed
memory. The count currently
covers tracked object allocations, not every auxiliary buffer. Incremental and
generational collector modes are still open.

The CLI's `--check` mode runs only the lexer, parser, and semantic pass. The
differential and corpus harnesses use it so accepted scripts are not executed
as a side effect of front-end checks. A first runtime smoke comparison against
the reference also caught and fixed table-constructor list fields being stored
too early when a keyed field uses the same numeric index. Constructors now
size their parts the way `lcode.c` does — the array part exactly the list
fields written to it, the hash part the next power of two over its record
count — evaluate every field in source order, and grow the list part to the
exact size each `SETLIST` needs rather than rounding. Numeric strings now
coerce for arithmetic and unary minus, while bitwise operations and comparisons
keep their stricter Lua behavior; failed numeric coercion still falls through to
the other operand's metamethod.

## Phase 6 — widen

The core metatable hooks and string pattern matcher are implemented, and the
`io` library now covers the file and default-stream surface. The largest
runtime gaps are host-local time and the host locale database (`setlocale`
answers only for `"C"`), edge-case compatibility across Lua's runtime
semantics, and a few
representation differences: file handles are tables rather than userdata (so
`type(io.stdout)` says `table` where the reference says `userdata`), uncaught
errors print no stack traceback anywhere (the cases show reader failures under
`pcall`, where the reference prints none either), `string.dump` refuses every
function — the mirror of the binary-chunk refusal — a table's hash-part
iteration order can differ where the reference's own is not reproducible even
run to run, a native function's printed address is an internal ordinal rather
than a pointer, and rare OS-level `io` failures surface as the host's
`RuntimeError` instead of `nil` plus a message plus an errno.
Dynamic binary chunks and incremental/generational collector modes are also
unsupported.

## Verification

Three harnesses, at three scales, and they are not interchangeable.

- **`differential/run.sh`** — 68 files written by hand to make the two front ends
  disagree, compared against a reference Lua 5.4.9. Where both refuse, it checks
  that lualite names the right construct, from a keyword in an `.expect` file.
  This is the one that can say what the right answer *is*.
- **`corpus/run.sh`** — 2393 files across 9 sources, ~21 MB, nothing written by
  hand. It compares the verdict only, which is the trade for finding divergences
  nobody thought to look for. It found the false rejection on a reused label name
  and the crash on an oversized file. See `corpus/RUN-REPORT.md`.
- **Unit tests**, colocated, 262 of them.

What the parser harnesses cannot see is what a program computes. That is what
`runtime/run.sh` is for: it runs each `runtime/cases/*.lua` under both
interpreters and diffs stdout, stderr and the exit status, after normalising
`0x…` object addresses (reference Lua seeds its string hash per process —
`luai_makeseed` in `lstate.c` — so `pairs` over string keys also differs run to
run; cases avoid depending on that order). Its seventeen cases cover the number
and string models, tables and constructors, functions and closures, control
flow, `goto`, metatables, metamethods, error messages, `string.format`,
strings, the standard library, `load` and its refusals, `io`, coroutines, and
deep recursion. Two front-end bugs were found by hand rather than
by the harnesses: the `u16` slot overflow needs a generated file with 65536
locals, and the `\` before a CRLF needs a string literal nobody writes by
accident.

Going forward:
- **Wider output comparison**: grow `runtime/cases/` and, later, run a corpus of
  whole scripts under both interpreters, diffing what they print.
- **`--dump-literals`** on lualite against `lua -e print` over literal-only
  files, which is what would have caught the escape work rather than leaving it to
  unit tests. The decoder is the one place where "accepted" and "right" are
  different questions, and verdicts cannot tell them apart.
- **Lua's own test suite** as the Phase 6 target. Most of it is version-agnostic
  Lua source, and it would exercise every phase rather than only the last.
- Fuzzing the lexer and parser with random and mutated inputs; the existing
  invariants (the cursor never moving backwards, error recovery always making
  progress) are already the kind of thing a fuzzer confirms cheaply.

## Dependency order

Phase 2 was independent of Phase 1. The AST runtime depends on Phases 1 and 2.
Phase 4 fills runtime gaps and expands output comparison; Phase 5 adds the
standard library; Phase 6 widens language coverage.

```
front-end gaps ──> Phase 1 (semantics) ─┐
Phase 2 (values/tables/collector) ─────┴─> Phase 3 (AST runtime) ─> validation ─> stdlib ─> widen
```

## Where to pick up

Continue `src/VM.zig` as a direct AST evaluator. Improve Lua error behavior,
multiple returns, varargs and generic iterators, then broaden the standard
library. Keep execution tests close to the runtime and add an IR only when a
specific need appears. The collector needs tracing updates as runtime objects
become long-lived. The short-string
interner currently retains its arena until teardown; revisit that policy if
long-running workloads need short-string collection.
