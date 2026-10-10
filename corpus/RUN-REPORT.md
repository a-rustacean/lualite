# Corpus differential run — full report

Date: 2026-10-09. Tree at `d88f32e` plus the untracked `src/Semantic*` work.
Working state: 192/192 unit tests pass, 52/52 `differential/` cases pass, and
`src/Semantic.zig:641` is as found — see F1.

---

## 1. The goal

Test lualite against real-world Lua rather than against files written to make
it fail.

`PLAN.md` describes a front end with no stubs and a test story that is entirely
self-referential: 192 unit tests and 52 hand-written differential cases, all
written by the same person who wrote the code being tested. `differential/run.sh`
was built during Phase 1 and paid for itself immediately — it found two real
divergences in the resolver, both recorded in `PLAN.md`. But its inputs are
cases chosen because they were already suspected to be interesting. It cannot
find a bug nobody thought to look for, and a front end that has never seen
someone else's Lua has an unbounded number of those.

So the goal was a harness that runs the front end over a corpus of real
projects, compares it against a reference Lua 5.4, and says where the two
disagree — with the explicit expectation that the answer would not be "nowhere".

### What "test" could mean here, and what it could not

lualite stops after `Semantic.analyze` (`src/main.zig:317`). There is no
bytecode, no call frame, no value representation, no standard library. **The
runtime does not exist yet**, so nothing can be executed and no output can be
compared. The only meaningful test at this point is whether the front end
accepts and rejects the same files as a reference implementation does — which
is exactly the shape `differential/run.sh` already had, at a scale it was not
built for.

That constraint is worth stating plainly rather than burying, because it bounds
what the whole exercise can conclude. Every finding below is about the front
end. None of it is evidence about codegen or execution, because there is
nothing yet to be wrong.

### Scope, as agreed

- **Report and triage, no fixes.** The harness, the run, and a written account
  of each divergence with a minimal repro. Fixes are the user's call.
- **Local files plus pinned GitHub clones.** Cheap and diverse, reproducible by
  sha.
- **Reference via `nix build nixpkgs#lua5_4`.**

## 2. What was done

### Reference interpreter

`nix build nixpkgs#lua5_4` → `/nix/store/lxhmwznlw4lbv0h...-lua-5.4.7`. The
attribute is `lua5_4`, not `lua54` as first guessed.

The version came out as exactly **5.4.7**, the same one the 52 existing cases
were written against, so `differential/run.sh` was re-run against it as a
version-drift check first: 52 matching, 0 differing. Worth doing before
building anything on top, since a different patch level would have muddied
every result afterwards.

### Corpus

`corpus/manifest.txt` lists 9 sources, each with a pinned sha. Seven are
GitHub repos chosen for stylistic spread rather than size — 5.4-modern,
5.1-era, generated, hand-written, and one deliberately tiny:

| source | files | size | why |
| --- | --- | --- | --- |
| Zed `lua-language-server-3.19.1` | 1197 | 15.1 MB | already on disk; `meta/` is generated C API stubs, `script/` is hand-written |
| `LuaLS/lua-language-server` | 480 | 3.1 MB | same project upstream, plus its test suite |
| `luvit/luvit` | 199 | 0.6 MB | hybrid, idiomatic, older style |
| `luarocks/luarocks` | 162 | 1.0 MB | real CLI, heavy string and `os` use |
| `TheAlgorithms/Lua` | 151 | 0.3 MB | 151 small independent scripts, widest syntactic spread |
| `lunarmodules/Penlight` | 115 | 0.7 MB | 5.1-compatible, metaprogramming |
| `rxi/lite` | 44 | 0.1 MB | tiny, dense, hand-tuned |
| `openresty/lua-resty-core` | 38 | 0.2 MB | modern, has `goto` |
| `~/.config/nixos-config` | 7 | 0.1 MB | real config, already on disk |

**2393 files, 21.2 MB.** Checkouts live in `~/.cache/lualite-corpus`, outside
the repository, so a run does not leave hundreds of megabytes of other people's
code in the working copy. `fetch.sh` is idempotent — a source already at its
pinned sha is skipped.

Two enumeration details that cost real debugging:

- **Paths must be NUL-delimited throughout.** The Zed bundle alone has
  `Application Support` in all 1197 of its paths. `differential/run.sh:27`
  interpolates a path into a single-quoted shell string and would break on
  every one of them. Everything in the new harness goes through a binary file.
- **Submodules must be filtered.** git records lua-language-server's `bee.lua`
  and `json.lua` as gitlinks (mode 160000) with no content. `git ls-files '*.lua'`
  reports them; on disk they are empty directories. The first run counted them
  as `CRASH` with the message `wc: 'standard input': Is a directory`. Fixed
  with `--stage` plus an `-f` check. Worth knowing, since the failure presented
  as a compiler crash rather than as a harness bug.

### Harness

- `corpus/loadall.lua` — the reference side. One `lua5.4` process `loadfile`s
  all 2393 files. A process per file would be 2393 forks, which is most of a
  run's time for nothing. Outputs `verdict \t path \t line \t message`.
- `corpus/run.sh` — enumerates, joins, classifies, reports.

Two things in the reference driver that were not obvious:

- **`_VERSION` has no patch level** (`"Lua 5.4"`), so the exact version comes
  from `lua -v`.
- **The line in Lua's error message is not always the line of the construct.**
  For semantic errors, Lua reports both, and they differ:
  `goto x` on line 1 followed by four blank lines and a `print` gives prefix line
  6 and message `at line 1`. The prefix is where the parser had got to; the
  line inside the message is the construct's. The driver prefers the one inside
  the message, since that is what a line comparison should be against.

Classification, one class per file:

| class | meaning |
| --- | --- |
| `OK` | both accept, or both refuse at the same line |
| `MISS` | reference refuses, lualite accepts |
| `EXTRA` | lualite refuses, reference accepts |
| `LOC` | both refuse, at different lines |
| `CRASH` | lualite exits non-zero — panic, OOM, unreadable file |
| `SLOW` | over `SLOW_SECONDS` (default 5) |

`LOC` is new relative to `differential/run.sh`, which only greps a keyword and
never checks *where* an error is. It is reported rather than failed on, since
Lua stops at the first syntax error while lualite recovers and continues — the
two disagree about line numbering often enough that failing the run on it would
be noise. `CRASH` is the class that fails the run: nothing about a front end
should take the process down.

### Verification

Before trusting the harness, three checks:

1. Ran it against five synthetic files with known answers (bad escape, shebang,
   numeric suffix, duplicate-label goto, valid file) and confirmed each landed
   in the class it should — `MISS 2`, `EXTRA 2`, `OK 1`.
2. Confirmed `LOC` fires when it should, on
   `local s = "a\q"` followed by `break`, where Lua stops at the escape on line
   1 and lualite recovers and reports the `break` on line 2.
3. Confirmed the `CRASH` class catches the read-cap failure and that the
   exit-status test alone decides it — a crash still prints a line starting with
   `error:`, so the message cannot.

## 3. Observations

**OK 2388, MISS 0, EXTRA 4, LOC 0, CRASH 1, SLOW 0.**

Five findings. Three are gaps `PLAN.md` already lists; two are not, and one of
those changes what lualite accepts about ordinary code.

---

### F1 — a goto is refused when a label name is reused in a nested block

`EXTRA`, 2 files — both `script/vm/compiler.lua`, present twice because the Zed
extension bundles the same project.

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

Two labels of one name, inner and outer, with the goto written before both. The
goto should be claimed by the **outer** `::CONTINUE::`, which is the last
statement in its block and therefore counts its block's locals as gone — the
rule `PLAN.md` records and `src/Semantic/Goto.zig:104` already tests. Instead
the inner label claims it first and the scope check fires.

Minimal form, three lines:

```lua
do goto c
local t = 1
do ::c:: end
::c::
end
```

**Not the duplicate-label rule.** That is about labels visible at the same
point, and is correct here: the two labels are in different blocks, so the inner
one is not a duplicate. Adding or removing the inner `do` block flips lualite's
answer while Lua's stays put.

**Where.** `claimGotos`, `src/Semantic.zig:641`. A label claims gotos by name
across the whole function; this branch is supposed to let a goto lying outside
the label's block survive outward to a block that holds the label after all. The
comment at `src/Semantic.zig:642-644` says so in as many words — "a goto
further out than the label may still be carried out to a block that holds the
label after all" — and the code below it resolves the goto and reports it.

**Confirmed by experiment.** Replacing the branch body with `continue` makes all
14 shapes below agree, drops `EXTRA` from 4 to 2, and leaves 192/192 unit tests
and 52/52 differential cases green. **The change was reverted; the tree is as
found.**

| shape | reference, before and after |
| --- | --- |
| goto before an inner and an outer label of one name | accepts |
| inner label only, none outside | `no visible label` |
| inner label with its own local, outer label last | accepts |
| same, outer label not last | `jumps into the scope of local 'a'` |
| plain `goto out`, `local x`, `::out::` | `jumps into the scope of local 'x'` |
| the same inside a `do` block | same |
| `goto` with no label | `no visible label` |
| label at end of a `repeat` body | `jumps into the scope of local 'y'` |
| label at end of a `while` body, one outside | accepts |
| goto after a block that held a label | `no visible label` |
| goto crossing into a function | `no visible label` |
| two gotos to one label | accepts |
| backward goto from a nested block | accepts |

Before the fix: 2 of these 14 disagreed. After: 0.

**Why this matters more than the other four.** Every other finding is a
documented gap with a known shape. This is a false rejection of valid, ordinary
Lua in a file that two of the corpus's largest sources ship. It took a project
that reuses a label name across nesting levels to turn up, which is exactly the
class of bug a hand-written case set misses.

### F2 — the front end exits non-zero on a file over 1 MiB

`CRASH`, 1 file: `meta/default utf8/UnityEngine.lua`, 2.5 MB of generated Lua in
the Zed bundle. lualite exits 1 with a Zig stack trace:

```
error: StreamTooLong
/nix/store/.../zig/lib/std/Io/Reader.zig:386:5: in appendRemainingAligned
```

**Where.** `src/main.zig:285`, `readFileAlloc(..., .limited(1 << 20))`. The
reference reads the same file fine — it refuses it, but for a real reason, at
line 23802 where a parameter is named `end`.

**Not in `PLAN.md`.** A size limit is a reasonable thing for a CLI to have and
an unreasonable one to have at 1 MiB: this file is 2.5 MB of machine-generated
API stubs, not an outlier. It is also silent about the cap, so the failure
presents as a bug in the reader rather than as a policy.

No fetched repo has a file this large — only the Zed bundle does — which is why
the fetched half of the corpus scored zero here. It is also the loudest item in
the run, since it is what makes `run.sh` exit non-zero.

### F3 — no shebang line

`EXTRA`, 2 files: `luarocks/spec/util/mock-server.lua`, `penlight/run.lua`.

```lua
#!/usr/bin/env lua
```

lualite: `expected a statement` at 1:1. Lua skips a first line starting with `#`.

`PLAN.md` gap 3, confirmed. Two of the corpus's three shebangs are caught;
`luvit/examples/http-keepalive.lua` has one inside a `--[[` comment, so it is
not a case.

### F4 — string escapes Lua refuses are accepted

`MISS`, 0 files in this corpus, but the gap is real — the class is empty only
because nothing in the corpus trips it.

| source | Lua 5.4.7 | lualite |
| --- | --- | --- |
| `local s = "\d"` | `invalid escape sequence` | accepts, decodes to `d` |
| `local s = "\999"` | `decimal escape too large` | accepts, truncates via `@truncate` |
| `local s = "\u{1F600}"` | accepts | accepts, **wrong bytes** |

`PLAN.md` gap 2, first three bullets. Note the third row: both accept, so the
harness cannot see it at all — a correct verdict on a wrong value. See §5.

Zero hits is luck, not correctness. The corpus is modern Lua that has largely
stopped writing `"\d"`; a 5.1-era codebase would trip this on nearly every
file, since it was idiomatic for a decade.

### F5 — integer and float suffixes

`EXTRA`, 0 files. **A correction to `PLAN.md`, which lists this as a gap.**

| source | Lua 5.4.7 | lualite |
| --- | --- | --- |
| `local x = 3i` | `malformed number` | `malformed number` |
| `local x = 1f` | `malformed number` | `malformed number` |
| `local x = 1n` | `malformed number` | `malformed number` |

`PLAN.md` gap 4 says `i`/`f`/`n` are "rejected as malformed numbers rather than
recognised as valid Lua 5.4 source", which reads as lualite being wrong. It is
not — the reference rejects all three identically. The suffix is genuinely part
of what Phase 2's tagged integer/float must decide, but the lexer is not wrong
today, and the item should be reworded to say so, or it will send someone
looking for a bug that is not there.

No Lua source in the corpus uses a numeric suffix, so there is no pressure here
either way.

---

### What the agreement means

2388 of 2393 files agree, and the agreement is not shallow. It covers 5.4-era
goto and label work, integer division, bitwise operators, long strings at
several `=` levels, `repeat`, generic for, varargs, and a great deal of
generated API-stub code. The front end is not fragile in the way a partial
implementation usually is, which is the main positive result here.

`LOC 0` is worth a note since the class exists to catch a compiler refusing a
file for the wrong reason. Empty because the only files both sides refuse are
ones where lualite is right for a different reason, and because a false
rejection is rarer than a false acceptance here. The class is not redundant —
it fires on the F4 case in §2.

**Throughput.** 21.2 MB in 47 s, no file over 0.12 s. Cost is dominated by
process startup, not parsing; the largest file, 2.5 MB, is the one that fails to
load at all. A CLI-shaped API is the wrong benchmark for parse speed, so this is
a sanity check that nothing is quadratic, not a throughput measurement.

**One harness caveat.** `SLOW` measures wall time and so, on a loaded machine,
catches the scheduler rather than the parser: one run flagged a 71-byte file at
134 s that takes 17 ms on its own, and the next run of the same tree was clean.
Re-run a lone `SLOW` before believing it; `SLOW_SECONDS` moves the line.

## 4. Conclusion

The front end is in better shape than the exercise expected. 99.6% agreement
with the reference across 2393 real files, with no false acceptance of anything
that should have been refused by the front end's own standards and exactly one
false rejection of valid code.

Ranked by what they are worth:

1. **F1, the goto/label bug.** The only finding that rejects correct Lua. One
   branch, `src/Semantic.zig:641`, where the comment describes the correct
   behaviour and the code does the opposite. Fix verified: 14 shapes agree, both
   suites green, `EXTRA` 4→2. Highest value by a wide margin, because it is the
   only one that makes lualite wrong about code that works.
2. **F2, the 1 MiB cap.** One line, `src/main.zig:285`, and it is what makes the
   harness exit non-zero. Raising or removing the limit, or reporting the cap,
   clears it.
3. **F5, reword `PLAN.md` gap 4.** No code. The item currently describes a bug
   that does not exist and will waste someone's time.
4. **F3, shebang.** Known, small, mechanical, and it will be hit by essentially
   every CLI script anyone writes.
5. **F4, escape decoding.** The largest `MISS` class by area — a 5.1-era corpus
   would light it up on nearly every file — but zero hits here, and it is
   invisible to a verdict-comparing harness by construction.

The harness itself is the durable part. It is cheap to run, pinned, and it
complements `differential/run.sh` rather than replacing it: that one takes
files chosen to be pathological and checks *what* is said, this one takes files
nobody chose and checks *whether* it agrees. Running both, plus the 192 unit
tests, before touching the front end would be a reasonable default from here.

**Suggested order:** F1, then F2, then reword gap 4. F1 and F2 are small and
independently verifiable, and each converts one whole class to zero.

## 5. What this run cannot see

Only verdicts. lualite parses and discards; the reference never executes
anything. So every one of these passes the harness whether or not it is right:

- **how a string literal decodes.** `"\u{1F600}"` is accepted with the wrong
  bytes — both sides return "accept", and the harness has nothing to compare.
- **`\z`**, and line-ending normalisation inside long strings.
- **integer versus float**, and overflow wrapping rather than becoming `inf`.
- **anything about what the code computes**, which needs a runtime to exist.

So this is evidence about the front end and nothing else. The natural follow-up,
once numbers are tagged per Phase 2, is a `--dump-literals` mode on lualite
compared against `lua -e print` over literal-only files — cheap, and it would
close the class of bug that accepts-invalid-and-decodes-wrong, which no
verdict-based harness can reach. Until a VM exists, the runtime itself is
untested, and this report should not be read as saying otherwise.

## 6. Files

| file | |
| --- | --- |
| `corpus/README.md` | how to run it, class definitions, enumeration pitfalls |
| `corpus/report.md` | findings on their own, for when only those are wanted |
| `corpus/manifest.txt` | the 9 sources with pinned shas |
| `corpus/fetch.sh` | materialise the corpus |
| `corpus/loadall.lua` | reference side |
| `corpus/run.sh` | join, classify, report; exits non-zero on `CRASH` |
| `corpus/out/` | per-run output, gitignored |
