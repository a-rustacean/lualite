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

229 tests pass (`zig build test`), 68 differential cases against a reference Lua
5.4 agree (`differential/run.sh`), and 2393 corpus files agree (`corpus/run.sh`).
`grep` for `TODO`, `unimplemented`, `@panic` across `src/` finds nothing.

**Absent:** every layer between the resolved AST and executing code. No bytecode,
no call frames, no closures, no standard library. The value model below has
landed, but nothing produces a `Value` yet and nothing consumes one.

## Gaps to close in the front-end first

These are on the list before codegen rather than after, because bytecode and
value representations would otherwise bake the mistakes in. Items 2 to 5 are
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
     The lexer rejects all three as malformed numbers, and so does Lua 5.4.7, so
     nothing is broken today; the suffix is simply part of what this item has to
     decide, and the answer is that 5.4 has none of them.
2. ~~**String decoding is not Lua-faithful.**~~ **Closed.** The decoder now
   follows `read_string` in `llex.c`: an unknown escape, a `\ddd` over 255, a
   `\x` without two digits, a `\u` without its braces and a code point past
   `0x7FFFFFFF` are each refused with their own diagnostic, and `\u{...}`
   decodes to UTF-8 with `luaO_utf8esc`. A bad escape is reported and the decoder
   carries on, so it costs the rest of its string rather than the rest of the
   chunk.
   - **Still open:** long strings do not normalize line endings. Lua 5.4 converts
     every EOL sequence in a long string to `\n` and this does not.
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
  mark-sweep, so a value can be overwritten with no bookkeeping and no write
  barrier; only the shape is here, and the sweep arrives with tables, which are
  the first thing that can make a cycle.
- `src/Str.zig` — short strings interned behind a content-keyed table at Lua's
  40-byte split, laid out in a bump arena so a pointer stays a key; long
  strings are not interned and compare by content, the same trade Lua makes.
  Hashed with `luaS_hash` so a table keyed by strings comes out in the order
  the reference would give it.
- `src/Value.zig` — the union, `type`/`math.type`, `==` across the two number
  types, and truthiness. Tables, closures and threads are placeholders holding
  only the header, since their contents arrive with the collector.

**Still open in Phase 2:** the array/hash table parts, the mark and sweep
itself, and `--dump-literals` so the corpus can be re-run against tagged
numbers rather than just the ones the golden file names.

## Phase 3 — bytecode format

Register-based, one 32-bit instruction word, following `lopcodes.h` closely:
`MOVE`, `LOADK`, `LOADNIL`, `LOADBOOL`, `LOADINT`, arithmetic and comparison,
`GETTABLE`/`SETTABLE`, `GETFIELD`/`SETFIELD`, `GETUPVAL`/`SETUPVAL`,
`NEWTABLE`, `CLOSURE`, `VARARG`, `CALL`/`TAILCALL`/`RETURN`, `JMP`, `EQ`,
`LT`, `LE`.

Constants and nested prototypes live in a per-function array. Shaped like Lua's
so `lvm.c` and `lopcodes.c` can be read alongside while implementing.

**Done when:** a hand-assembled prototype round-trips through the decoder and
disassembles legibly.

## Phase 4 — compiler pass

AST to bytecode, taking the slot assignments from Phase 1 as input.

- Register allocation over the active locals, with the temporaries Lua reserves
  for binary-operator intermediates.
- An expression compiler honouring the precedence table, which is already
  correct and tested at `src/Parser/Expression.zig:23-48` — including the
  counter-intuitive ordering where `<<` binds looser than `==`.
- A statement compiler for every form: `repeat` closes at its condition,
  multiple-return adjustment on a last expression, method-call argument
  shifting for `object:name(...)`.
- Short-jump optimisation with the deferred-jump pattern `lopcodes.c` uses.

Depends on Phase 1 for slot assignment. Starting before Phase 1 finishes means
retrofitting a resolver onto emitted bytecode, which is worse than writing it
once.

## Phase 5 — VM core

A dispatch loop over the instruction stream.

- Frame stack: registers, varargs, open upvalues shared across closures.
- Call, return, and tail calls.
- Closures with upvalue capture, and upvalue closing as scopes exit.
- `pcall`/`xpcall`/`error` over a protected-frame mechanism.
- A call-depth limit to replace the parser's `max_depth` at runtime.

**Done when:** a Lua program with functions, closures, recursion, varargs and
multiple returns prints the same output as the reference implementation.

## Phase 6 — minimal standard library

Enough to run real scripts:

- base: `print`, `type`, `tostring`, `tonumber`, `pairs`, `ipairs`, `next`,
  `select`, `error`, `pcall`, `assert`, `rawget`, `rawset`, `rawequal`,
  `setmetatable`, `getmetatable`
- `string`: `format`, `len`, `sub`, `rep`, `byte`, `char`, `upper`, `lower`,
  `find`, `gmatch`, `match`, `reverse`, `gsub`
- `table`: `insert`, `remove`, `concat`, `sort`, `unpack`
- `math`

## Phase 7 — widen

Metatables and the full metamethod set, coroutines, `io`, `os`, `utf8`, and the
string pattern library in full — Lua's matcher is ~300 lines and the fiddliest
part of the stdlib.

## Verification

Three harnesses, at three scales, and they are not interchangeable.

- **`differential/run.sh`** — 68 files written by hand to make the two front ends
  disagree, compared against a reference Lua 5.4.7. Where both refuse, it checks
  that lualite names the right construct, from a keyword in an `.expect` file.
  This is the one that can say what the right answer *is*.
- **`corpus/run.sh`** — 2393 files across 9 sources, ~21 MB, nothing written by
  hand. It compares the verdict only, which is the trade for finding divergences
  nobody thought to look for. It found the false rejection on a reused label name
  and the crash on an oversized file. See `corpus/RUN-REPORT.md`.
- **Unit tests**, colocated, 229 of them.

What the harnesses cannot see is everything about what the code computes, since
the reference never runs anything and there is no runtime yet. That is also why
two bugs in this pass were found by hand rather than by either: the `u16` slot
overflow needs a generated file with 65536 locals, and the `\` before a CRLF needs
a string literal nobody writes by accident.

Going forward:
- **Output comparison** once there is a runtime: run a corpus through both and
  diff what they print. That is what will catch codegen bugs.
- **`--dump-literals`** on lualite against `lua -e print` over literal-only
  files, which is what would have caught the escape work rather than leaving it to
  unit tests. The decoder is the one place where "accepted" and "right" are
  different questions, and verdicts cannot tell them apart.
- **Lua's own test suite** as the Phase 7 target. Most of it is version-agnostic
  Lua source, and it would exercise every phase rather than only the last.
- Fuzzing the lexer and parser with random and mutated inputs; the existing
  invariants (the cursor never moving backwards, error recovery always making
  progress) are already the kind of thing a fuzzer confirms cheaply.

## Dependency order

Phase 2 is independent of Phase 1, which is done, so they can run in parallel.
Phase 3 gates Phases 4 and 5. Phase 4 needs the slot assignments from Phase 1.
Phase 5 depends on Phases 2 and 3. Phase 6 follows 5. Phase 7 follows 6.

```
front-end gaps ─┬─> Phase 1 (semantics) DONE ─┐
                └─> Phase 2 (values) ─────────┼─> Phase 4 (compiler) ─┐
                       Phase 3 (bytecode) ────┴───────────────────────┴─> Phase 5 (VM) ─> Phase 6 (stdlib) ─> Phase 7 (widen)
```

## Where to pick up

Phase 1 is done, and so is Phase 2 increment 1 (numbers, strings, object
headers). Increment 1a is the obvious next piece of Phase 2: the table's array
and hash parts, and the mark-sweep that needs them. That closes the loop the
headers were laid down for — right now `Tracker` has the list a sweep walks but
nothing walking it, and `Table` has nothing inside it.

Phase 3, the bytecode format, is the other candidate: it constrains the compiler
and the VM, and it is easier to change before there is code emitting it.

`zig build test && differential/run.sh` before committing anything that touches
either.
