#!/usr/bin/env bash
# Compares what the reference Lua 5.4 compiler says about a file against what
# lualite's front-end reports. Both are loaders here, not runtimes: neither
# executes anything, so only the diagnostics are compared.
#
# Each case is a .lua file under cases/. lualite reports what its lexer, parser
# and semantic pass found and exits 0 either way; the reference reports its own
# messages to stderr. What is compared is the verdict, empty or not empty, and
# for the failing cases the reason in words.

set -uo pipefail

# the reference has to be built; see README.md
LUA=${LUA:-/tmp/lua-5.4.7/src/lua}
LUALITE=${LUALITE:-$(dirname "$0")/../zig-out/bin/lualite}
CASES=${1:-$(dirname "$0")/cases}

pass=0
fail=0
failed_names=()

for file in "$CASES"/*.lua; do
  name=$(basename "$file" .lua)

  # loadfile returns nil and the reason, so the chunk is never run: this compares
  # what the two front-ends say about the file, not what either does with it
  lua_out=$("$LUA" -e 'local _, e = loadfile("'"$file"'") if e then io.stderr:write(e) end' 2>&1)

  # the diagnostics are coloured, which the greps below would trip over
  lite_out=$("$LUALITE" --check "$file" 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

  if [ -n "$lua_out" ]; then
    # the reference refuses the file, so lualite has to as well
    if [ -z "$lite_out" ]; then
      echo "MISS  $name: lua refuses, lualite accepts"
      echo "      lua: $(echo "$lua_out" | head -1)"
      fail=$((fail + 1))
      failed_names+=("$name")
      continue
    fi

    # both refuse. The messages differ in wording, so what is compared is that
    # each names the construct the case is about
    keyword=$(head -1 "$CASES/$name.expect" 2>/dev/null)
    if [ -n "$keyword" ] && ! echo "$lite_out" | grep -qi -- "$keyword"; then
      echo "WORD  $name: both refuse, but lualite does not mention '$keyword'"
      echo "      lua: $(echo "$lua_out" | head -1)"
      echo "      lite: $(echo "$lite_out" | head -1)"
      fail=$((fail + 1))
      failed_names+=("$name")
      continue
    fi

    pass=$((pass + 1))
    continue
  fi

  if [ -n "$lite_out" ]; then
    echo "EXTRA $name: lua accepts, lualite reports"
    echo "      lite: $(echo "$lite_out" | grep -m1 error:)"
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
