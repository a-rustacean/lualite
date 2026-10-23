#!/usr/bin/env bash
# Regenerates src/Number.golden.txt by running src/Number.golden.lua through a
# reference Lua 5.4.
#
# The result is what `src/Number.golden.zig` compares against, which is what makes
# the number rules Lua's rather than a reading of lobject.c. Never edit the
# output; rerun this instead.

set -euo pipefail

LUA=${LUA:-}
HERE=$(cd "$(dirname "$0")" && pwd)

# /tmp is wiped between sessions, so prefer a nix-provided lua and fall back
# to the other locations the harnesses know about
if [ -z "$LUA" ]; then
  nix_lua=$(nix eval --raw nixpkgs#lua5_4.outPath 2>/dev/null)/bin/lua
  for candidate in \
    "$nix_lua" \
    /tmp/lua-5.4.7/src/lua \
    /var/folders/97/_qcnlbz94c311tpc5jsvnyyh0000gn/T/opencode/lua/lua-5.4.7/src/lua
  do
    if [ -x "$candidate" ]; then
      LUA=$candidate
      break
    fi
  done
fi
SOURCE="$HERE/../src/Number.golden.lua"
TARGET="$HERE/../src/Number.golden.txt"

if [ ! -x "$LUA" ]; then
  echo "no reference interpreter at $LUA; see differential/README.md" >&2
  exit 1
fi

"$LUA" "$SOURCE" > "$TARGET"

lines=$(grep -c '^\(ok\|err\)\b' "$TARGET")
echo "wrote $TARGET ($lines results)"