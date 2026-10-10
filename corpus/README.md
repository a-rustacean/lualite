# Corpus differential testing

`run.sh` runs lualite's front end over a corpus of real Lua and compares it
against a reference Lua 5.4. Neither side executes anything: the reference runs
`loadfile` and lualite parses and stops, so only the diagnostics are compared.
This is the same shape as `differential/run.sh`, at a scale it is not built
for.

The difference in what is compared is the point. `differential/run.sh` holds
52 files written to make the two front ends disagree, and it compares a keyword
from an `.expect` file, since the wording of the two messages cannot be
matched. Nothing here was written by hand: the files are whatever the projects
ship. That buys the thing the hand-written cases cannot give, which is finding
divergences nobody thought to look for, at the cost of not being able to say
what the right answer is for a file that only one side refuses.

## Classes

| class | meaning |
| --- | --- |
| `OK` | both accept, or both refuse at the same line |
| `MISS` | the reference refuses, lualite accepts |
| `EXTRA` | lualite refuses, the reference accepts |
| `LOC` | both refuse, at different lines |
| `CRASH` | lualite exits non-zero: a panic, an out of memory, a file it could not read |
| `SLOW` | lualite took longer than `SLOW_SECONDS` (default 5) |

`MISS` and `EXTRA` are the front-end gaps `PLAN.md` lists. `CRASH` is the class
that matters most, since nothing about the front end should take the process
down, and the run exits non-zero if any file lands in it.

`LOC` is reported rather than failed on. Lua stops at the first syntax error
while lualite recovers and keeps going, and Lua counts a construct by where the
parser had got to while lualite counts it by where the construct is written, so
the two disagree about which line an error is on often enough that treating it
as a failure would be noise. Every `LOC` line lands in `out/LOC.txt` to be read
by hand.

`SLOW` measures wall time, so on a loaded machine it catches the scheduler
rather than the parser: one run flagged a 71-byte file at 134 s that takes
17 ms on its own, and the next run of the same tree was clean. Treat a lone
`SLOW` as something to re-run before believing, and `SLOW_SECONDS` is there to
move the line if a machine is slow enough that this keeps happening.

## Running it

The reference has to be built or otherwise provided. No `lua` is assumed to be
on `PATH`, and the version matters, since the cases in `differential/` were
written against 5.4.7 and a later patch can word things differently.

```sh
nix build nixpkgs#lua5_4 --no-link --print-out-paths
export LUA=/nix/store/...-lua-5.4.7/bin/lua
```

`fetch.sh` has to have been run first, and it wants `git`:

```sh
corpus/fetch.sh
zig build
corpus/run.sh
```

`LUA`, `LUALITE`, `MANIFEST`, `LUA_CORPUS`, `OUT` and `SLOW_SECONDS` all
override their defaults.

## The corpus

`manifest.txt` is the list: name, url and pinned sha per source, or `local:`
plus a path for something already on the machine. Checkouts go to `$LUA_CORPUS`
(default `~/.cache/lualite-corpus`), outside the repository, so a run does not
leave several hundred megabytes of other people's code in the working copy.
Rerunning `fetch.sh` is cheap: a source already at its pinned sha is left alone.

Two details in the enumeration are worth knowing about if it is edited. Paths
are collected NUL-separated throughout, because they come off disk and out of
git and can contain spaces — the Zed bundle alone has `Application Support` in
every one of its 1197 paths — so nothing goes through word splitting or a shell
string. And `--stage` filters submodules, since git records those as gitlinks
with mode 160000 and no content, and lua-language-server has two of them named
`bee.lua` and `json.lua`, which would otherwise arrive as directories.

At the time of writing, 2393 files across 9 sources, about 21 MB.

## What it cannot see

Only verdicts. lualite parses and discards, so every one of these passes the
harness whether or not it is right:

- how a string literal decodes — `"\u{1F600}"` is accepted with the wrong bytes
- `\z`, and line-ending normalisation inside long strings
- integer versus float, and overflow wrapping rather than becoming `inf`
- anything about what the code computes, which needs a runtime to exist first

So the harness is evidence about the front end and nothing else. The natural
follow-up, once numbers are tagged per Phase 2, is a `--dump-literals` mode on
lualite compared against `lua -e print` over literal-only files.
