#!/usr/bin/env bash
# Compares what lualite's interpreter computes against a reference Lua 5.4.
#
# This is the runtime sibling of differential/run.sh, which only compares
# front-end verdicts. Here both sides execute each file under cases/ and what is
# compared is stdout, stderr and the exit status. It is the harness that can see
# an evaluator bug, which a verdict never can.
#
# Two things are normalised before the comparison, since neither can be made to
# agree and neither says anything about the interpreter:
#
#   - object addresses in `tostring` output, `table: 0x7f...`, which differ per
#     process on both sides and are rewritten to `0xADDR`;
#   - nothing else. In particular the reference seeds its string hash from time
#     and ASLR, so `pairs` over string keys comes out in a different order on
#     every run. Cases avoid depending on that order, and a case that wants to
#     print string keys sorts them first.
#
# Each case is a plain Lua file that writes to stdout. Set LUA or LUALITE to
# point at other binaries. `differential/README.md` says how to build the
# reference.

set -uo pipefail

LUA=${LUA:-/tmp/lua-5.4.7/src/lua}
HERE=$(cd "$(dirname "$0")" && pwd)
LUALITE=${LUALITE:-$HERE/../zig-out/bin/lualite}
CASES=${1:-$HERE/cases}

if [ ! -x "$LUA" ]; then
  echo "no reference interpreter at $LUA; see differential/README.md" >&2
  exit 1
fi
if [ ! -x "$LUALITE" ]; then
  echo "no lualite at $LUALITE; run 'zig build' first" >&2
  exit 1
fi

normalize() {
  sed -E \
    -e $'s/\033\\[[0-9;]*m//g' \
    -e 's/0x[0-9a-fA-F]+/0xADDR/g'
}

pass=0
fail=0
failed_names=()

for file in "$CASES"/*.lua; do
  name=$(basename "$file" .lua)

  lua_out=$("$LUA" "$file" 2>/tmp/lualite-runtime-lua-err); lua_status=$?
  lua_err=$(normalize </tmp/lualite-runtime-lua-err)

  lite_out=$("$LUALITE" "$file" 2>/tmp/lualite-runtime-lite-err); lite_status=$?
  lite_err=$(normalize </tmp/lualite-runtime-lite-err)

  lua_out=$(printf '%s' "$lua_out" | normalize)
  lite_out=$(printf '%s' "$lite_out" | normalize)

  if [ "$lua_out" != "$lite_out" ]; then
    echo "OUT   $name: stdout differs"
    diff <(printf '%s\n' "$lua_out") <(printf '%s\n' "$lite_out") | head -20 | sed 's/^/      /'
    fail=$((fail + 1))
    failed_names+=("$name")
    continue
  fi

  if [ "$lua_status" != "$lite_status" ]; then
    echo "EXIT  $name: exit status $lite_status, reference says $lua_status"
    echo "      lite stderr: $(printf '%s' "$lite_err" | head -1)"
    fail=$((fail + 1))
    failed_names+=("$name")
    continue
  fi

  if [ "$lua_status" != 0 ]; then
    # both failed; the wording of neither message is required to match, but
    # something has to have been said
    if [ -z "$lite_err" ]; then
      echo "QUIET $name: both refuse, lualite says nothing"
      fail=$((fail + 1))
      failed_names+=("$name")
      continue
    fi
  elif [ -n "$lite_err" ]; then
    echo "NOISE $name: lualite wrote to stderr with status 0"
    echo "      lite stderr: $(printf '%s' "$lite_err" | head -1)"
    fail=$((fail + 1))
    failed_names+=("$name")
    continue
  fi

  pass=$((pass + 1))
done

echo
echo "matching: $pass   differing: $fail"
if [ "$fail" -gt 0 ]; then
  printf '  %s\n' "${failed_names[@]}"
  exit 1
fi
