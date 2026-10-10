# Differential testing against a reference Lua

`run.sh` compares what the reference Lua 5.4 compiler says about each file in
`cases/` against what lualite's lexer, parser and semantic pass report. Neither
side executes anything: the reference runs `loadfile` and lualite parses and
stops, so only the diagnostics are being compared.

A case passes when the two agree on the verdict — both accept, or both refuse —
and, where both refuse, when lualite's message names the construct the case is
about. The word to look for is in `cases/NAME.expect`, so the wording of either
message is free to change without touching the harness.

## Running it

The reference interpreter has to be built once. No `lua` is assumed to be on
`PATH`, and the version matters, since `5.4.7` is what the cases were written
against.

```sh
curl -sL -o /tmp/lua.tar.gz https://www.lua.org/ftp/lua-5.4.7.tar.gz
tar xzf /tmp/lua.tar.gz -C /tmp
make -C /tmp/lua-5.4.7 posix        # 'linux' links with flags macOS ld rejects
```

Then, from the repository root:

```sh
zig build
differential/run.sh
```

`LUA` and `LUALITE` override the two binaries if either is somewhere else.

## What it found

The harness earned its place during Phase 1. Two of the divergences it turned up
were not in lualite's favour:

- **A label at the end of a block.** `lparser.c` measures a goto against the
  block's entry `nactvar` when the label is the last statement in it, rather than
  against the locals live where the label is written. That is what makes
  `do goto out; local y = 2; ::out:: end` legal while adding one statement after
  the label makes it an error. lualite reported both, since it measured the label
  the obvious way. `Semantic.zig` now takes `is_last` from the statement walk and
  measures against the block, which means the walk has to know each construct's
  terminator tokens.

- **`until` is not `end`.** The same rule does not apply to a `repeat` body, since
  a label at the end of one is followed by the `until` condition rather than by
  the end of the block, so its locals do still count.

One divergence is lualite being stricter than the reference, which is a known
front-end gap and listed in `PLAN.md`: the escape sequences and line-ending
normalisation inside strings are not Lua-faithful yet, so `"\q"` decodes instead
of failing.

## Adding a case

A file in `cases/` named `ok_*` or `err_*` for what it is. `err_*` needs an
`.expect` file beside it holding the word the message has to contain, since the
two sides word everything differently.

Reach for a case whenever a check is added, and whenever a reading of the
reference's source is at all uncertain — `lparser.c` is the authority and a guess
about it will usually be wrong about something.
