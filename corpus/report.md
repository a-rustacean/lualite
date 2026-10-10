# Corpus run — findings

Findings on their own, for when that is all that is wanted. `RUN-REPORT.md` is
the full account: the goal, how the harness was built, what it verified, and
what it cannot see.

The run behind this is `corpus/run.sh`; see `README.md` there for what the
classes mean and how to reproduce it.

**All five findings below are fixed.** The run that produced them is kept as it
was, since a report of a run is evidence and re-running it overwrites that. What
follows each finding says what was done.

- reference: Lua 5.4.7
- 2393 files across 9 sources, ~21 MB
- `OK 2388  MISS 0  EXTRA 4  LOC 0  CRASH 1  SLOW 0`

Five findings. Three are the gaps `PLAN.md` already lists, so the run mostly
confirms the list is right and puts a number on it. Two are not on it, and one
of those is a false rejection on real code that both of the two largest sources
ship.

Findings are numbered `F1`… and were meant to be lifted into
`differential/cases/` as each is fixed. All but F5 have been; F5 is a wording
change to `PLAN.md` rather than a code change, since the reference rejects those
suffixes too.

A sixth finding, **F6**, came out of reviewing this run rather than from it, and
is at the end. It is a crash, and neither harness would have found it.

---

## F1 — a goto is refused when a label name is reused in a nested block

`EXTRA`, 2 files, both of them the same file: `script/vm/compiler.lua` from
lua-language-server, present twice in the corpus because the Zed extension
bundles the same project.

```lua
do
    goto CONTINUE
    local tbl = def.bindSource
    do
        ::CONTINUE::
    end
    ::CONTINUE::
end
```

Lua accepts. lualite reports:

```
error: `<goto CONTINUE>` jumps into the scope of local 'tbl'
```

Two labels of one name, an inner and an outer, and a goto written before both.
The goto should be claimed by the outer `::CONTINUE::`, which is the last
statement in its block and so counts its block's locals as gone — the rule
`PLAN.md` already records and `Goto.zig:104` already tests. Instead the inner
label claims it first and the scope check fires.

It is not the duplicate-label rule, which is about labels visible at the same
point and is correct here: the two labels are in different blocks, so the
inner one is not a duplicate. The minimal form is three lines:

```lua
do goto c
local t = 1
do ::c:: end
::c::
end
```

**Where.** `claimGotos` at `src/Semantic.zig:641`. A label claims gotos by name
across the whole function, and the branch there is meant to let a goto that
lies outside the label's block survive to a block further out. It does the
opposite: it resolves the goto and reports it. The comment at
`src/Semantic.zig:642-644` describes the intent — "a goto further out than the
label may still be carried out to a block that holds the label after all" — and
the code below it takes the goto out of the waiting list instead.

Confirmed by removing the branch: `if (!within(goto.scope, semantic.scope)) { continue; }`.
That makes all fourteen shapes below agree with the reference, drops `EXTRA`
from 4 to 2, and leaves the 52 existing differential cases and the 192 unit
tests green. The revert was in place when this was written; it is now the
permanent fix. Four cases were added covering the shapes below.

Shapes checked, all agreeing after the one-line change:

| shape | reference |
| --- | --- |
| goto before an inner and an outer label of one name | accepts |
| inner label only, none outside | `no visible label` |
| inner label with its own local, outer label last | accepts |
| same, outer label not last | `jumps into the scope of local 'a'` |
| plain `goto out` then `local x` then `::out::` | `jumps into the scope of local 'x'` |
| the same inside a `do` block | same |
| `goto` with no label at all | `no visible label` |
| label at the end of a `repeat` body | `jumps into the scope of local 'y'` |
| label at the end of a `while` body, one outside | accepts |
| goto after a block that held a label | `no visible label` |
| goto crossing into a function | `no visible label` |
| two gotos to one label | accepts |
| backward goto from a nested block | accepts |

This is the one finding that changes what lualite accepts about code that is
perfectly ordinary. Every other file in the corpus that uses `goto` agrees, so
it took a project that reuses a label name in a nested loop to turn up.

## F2 — the front end exits non-zero on a file over 1 MiB

`CRASH`, 1 file: `meta/default utf8/UnityEngine.lua` from the Zed bundle,
2.5 MB of generated Lua. lualite exits 1 with a stack trace:

```
error: StreamTooLong
/nix/store/.../zig/lib/std/Io/Reader.zig:386:5: in appendRemainingAligned
```

**Where.** `src/main.zig:285`, `.limited(1 << 20)`. The reference reads the
same file without trouble — it refuses it, but for a real reason, at line
23802, where a parameter is named `end`.

The limit is not in `PLAN.md`. It is a reasonable thing for a CLI to have and
an unreasonable thing to have at 1 MiB, since real Lua files are larger than
that: this one is 2.5 MB, and it is generated API stub data rather than an
outlier. It is also silent about the cap, so the failure reads as a bug in the
reader rather than a policy.

No fetched source has a file this big; only the Zed bundle does. Worth fixing
because the harness now exits non-zero on it, which makes it the loudest thing
in the run.

**Fixed.** The cap is gone; `readFileAlloc` is `.unlimited` now. A read that
fails for any reason prints `lualite: cannot read <path>: <error>` and returns,
rather than escaping `main` and having Zig print a stack trace through the
reader. `FileNotFound` was doing the same thing and is fixed the same way.

That turned out to be one of two things the cap was hiding. The other is F6.

## F3 — no shebang line

`EXTRA`, 2 files: `luarocks/spec/util/mock-server.lua` and
`penlight/run.lua`. Both start:

```lua
#!/usr/bin/env lua
```

lualite reports `expected a statement` at 1:1. Lua skips a first line starting
with `#`.

`PLAN.md` gap 3. Two of three shebangs in the corpus are caught by this;
`luvit/examples/http-keepalive.lua` has one inside a `--[[` comment, so it is
not one.

**Fixed.** `scan` skips the first line when the source begins with `#`. Note
that it is `#` and not `#!` that opens it: `skipcomment` in `lauxlib.c` tests
for the hash alone, so `# a comment` as a first line is skipped too, and a
second `#!` line is a syntax error rather than a second shebang. Both are cases
in `differential/cases/`.

## F4 — string escapes Lua refuses are accepted

`MISS`, 0 files in this corpus, but the gap is real and the harness confirms it
is the only thing keeping this class empty. Lua refuses all three:

```lua
local s = "\d"      -- invalid escape sequence
local s = "\999"    -- decimal escape too large
```

lualite accepts both silently — `\d` decodes to `d`, `\999` truncates. The
third, `"\u{1F600}"`, is accepted by both and decodes wrongly, which the
harness cannot see (see "What it cannot see" in `README.md`).

`PLAN.md` gap 2, the first three bullets. Zero hits here is luck rather than
correctness: the corpus is modern Lua that has largely stopped writing `"\d"`,
whereas a 5.1-era codebase would trip it on nearly every file.

**Fixed**, and the third one was worse than a silent mismatch. The decoder now
follows `read_string` in `llex.c`: an unknown escape, a `\ddd` over 255, a `\x`
without two digits, a `\u` without its braces, and a code point past
`0x7FFFFFFF` are each refused with their own diagnostic. `\u{...}` decodes to
UTF-8 by way of `luaO_utf8esc`, including the parts that are easy to get wrong —
a surrogate is allowed here even though `utf8.char` refuses one, and the code
point is range-checked before the shift rather than after. A bad escape is
reported and the decoder carries on, so it costs the rest of its string rather
than the rest of the chunk.

Long strings still do not normalize line endings, which is the rest of that gap
and is the only part of F4 left open.

## F5 — integer and float suffixes

`EXTRA`, 0 files here. Both sides refuse:

```lua
local x = 3i   -- malformed number, from both
```

`PLAN.md` gap 4 lists `i`, `f` and `n` as "rejected as malformed numbers
rather than recognised as valid Lua 5.4 source", which reads as lualite being
wrong. It is not: Lua 5.4.7 rejects these too. The suffix is part of what Phase
2's tagged integer/float needs to decide, but the lexer is not wrong to reject
it today, and the corpus agrees.

No Lua source in the corpus uses a numeric suffix, so there is no pressure here
either way.

**Fixed as wording, not code.** `PLAN.md` now folds the suffix into gap 1 and
says plainly that Lua 5.4.7 rejects these too, so the lexer is not wrong today
and the suffix is simply part of what Phase 2's tagged number has to decide.

---

## F6 — a chunk with 65536 locals in one function crashes

Not found by this run, and worth saying so plainly: the corpus has no file like
it, and neither would a hand-written set of cases. It came out of reviewing the
run rather than from it.

A chunk declaring 65536 locals in one function panics:

```
thread 900586 panic: integer overflow
/Users/dilshad/Dev/lualite/src/Semantic.zig:446:52: in declare
    state.max_actvar = @max(state.max_actvar, slot + 1);
```

The threshold is sharp. 65534 locals produces 100 diagnostics and exits 0; 65536
panics with exit 134. `declare` reports the 200-local limit and then keeps
declaring anyway — deliberately, so the rest of a refused chunk still walks a
scope it can read — so the count goes on past `u16::MAX` and `slot + 1`
overflows. The reference refuses both cleanly with *too many local variables*.

**Why neither harness found it.** The corpus is real projects, none of which
declare 65536 locals in one function. The differential cases are written to make
the two disagree on a *verdict*, and a file like this needs a generated name per
local and is awkward to keep in the tree. It also needs a source big enough to
be interesting and small enough to stay quick, which is exactly the gap between
1 KB and 450 KB.

**Fixed.** `slot`, `n_actvar`, `frame_size` and the upvalue indices are `u32`
now. Lua's own caps stay `u16`, since they are Lua's constants rather than
counts — `max_locals` and `max_upvalues` never were the thing that could overflow.

Two things came out of fixing it that are worth more than the fix:

- **The u32 alone was not a fix.** It turned a crash into a hang: the chunk
  carries on declaring, so it produces 65336 diagnostics, and rendering those
  took about seven hours. `PLAN.md` gap 5 — no diagnostic cap — was tidying
  before and became load-bearing after. The reporter now keeps the first 100,
  counts the rest, and the CLI says how many it dropped. The same file takes
  0.67 s.
- **Most of the cost was not lualite's.** Turning an offset into a line and a
  column rescanned the source from the start for every diagnostic, which is
  quadratic in a file with many of them. `Lines` in `main.zig` now indexes the
  line starts once. That turned out to be a small part of it: the dominant cost
  is fehler re-rendering the whole source line for each diagnostic, so 3800
  diagnostics on one long line takes 90 s while 2000 across short lines takes
  0.73 s. That is a dependency's cost and it is not fixed here — but it is also
  not lualite's, and worth knowing before blaming the front end for a slow run.

---

## What the run says about the rest

2388 of 2393 files agree, and the agreement is not shallow: it covers 5.4-era
goto and label work, integer division, bitwise operators, long strings at
several `=` levels, `repeat`, generic for, varargs, and a great deal of
generated API-stub code. The front end is not fragile in the way a partial
implementation usually is.

`LOC 0` is worth a note, since the class exists to catch a compiler refusing a
file for the wrong reason. It is empty because the only files both sides refuse
are ones where lualite is right for a different reason, and because a false
rejection is rarer than a false acceptance here. The class is not redundant: it
fires on `local s = "a\q"` followed by `break`, where Lua stops at the escape
on line 1 and lualite recovers and reports the `break` on line 2.

Throughput, for a size of input where a slow front end would start to matter:
21.2 MB in 47 s, and no file took longer than 0.12 s. The cost is dominated by
process startup, not parsing — the largest file, 2.5 MB, is the one that fails
to load at all.

## Not covered

Everything about what the code computes. The reference never runs anything and
lualite has no runtime, so this is a statement about front ends only. See
"What it cannot see" in `README.md`.
