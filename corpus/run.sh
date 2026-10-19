#!/usr/bin/env bash
# Runs the front end over the corpus and compares it against a reference Lua 5.4.
#
# This is the corpus-scale sibling of differential/run.sh. That one answers
# "does lualite agree about this file I wrote to make it disagree", and it
# compares a keyword because the wording of the two messages cannot be
# matched. This one takes the opposite approach: files nobody wrote to be
# pathological, and it compares where each side says the error is, since a
# compiler that refuses a file for the wrong reason has not agreed with one
# that refuses it for the right one.
#
# Neither side executes anything. The reference runs loadfile and lualite parses
# and stops, so only the diagnostics are being compared.
#
# Every file lands in one class:
#
#   OK      both accept, or both refuse at the same line
#   MISS    the reference refuses, lualite accepts
#   EXTRA   lualite refuses, the reference accepts
#   LOC     both refuse, at different lines
#   CRASH   lualite exits non-zero: a panic, an out of memory, or a file it
#           could not read
#   SLOW    lualite took longer than SLOW_SECONDS on the file
#
# MISS and EXTRA are the front-end gaps PLAN.md lists. CRASH is the class that
# matters most, since nothing about the front end should take the process down,
# and the run exits non-zero if any file lands in it.
#
# LOC is reported rather than failed on. The two do not number lines the same
# way for every construct, and telling those apart needs reading the message,
# which is what report.md is for. Every LOC line lands in out/LOC.txt to be
# looked at by hand.

set -uo pipefail

here=$(dirname "$0")
LUA=${LUA:-$(command -v lua5.4 || command -v lua)}
LUALITE=${LUALITE:-$here/../zig-out/bin/lualite}
MANIFEST=${MANIFEST:-$here/manifest.txt}
LUA_CORPUS=${LUA_CORPUS:-$HOME/.cache/lualite-corpus}
OUT=${OUT:-$here/out}
SLOW_SECONDS=${SLOW_SECONDS:-5}

if [ -z "$LUA" ] || [ ! -x "$LUA" ]; then
  echo "no reference lua; set LUA, or see $here/README.md" >&2
  exit 1
fi
if [ ! -x "$LUALITE" ]; then
  echo "no lualite at $LUALITE; run 'zig build' first" >&2
  exit 1
fi

mkdir -p "$OUT"
list=$OUT/files.bin
results=$OUT/results.tsv
: > "$list"
: > "$results"

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf %s "$s"
}

# ---------------------------------------------------------------- enumerate
#
# Paths are collected NUL-separated. They come off disk and out of git and can
# contain spaces, tabs and newlines, so nothing here goes through word splitting
# or a shell string: the list is a binary file the reference splits on NUL.
#
# Each record is "<source>\t<path>\0", so the harness knows which project a
# file came from, since a divergence in one is usually not a divergence in all.
sources=()
while IFS='|' read -r name url sha; do
  name=$(trim "$name")
  url=$(trim "$url")
  case $name in '' | \#*) continue ;; esac

  if [ "${url#local:}" != "$url" ]; then
    dir=${url#local:}
    if [ ! -d "$dir" ]; then
      echo "skip $name: $dir is not there"
      continue
    fi
    while IFS= read -r -d '' f; do
      printf '%s\t%s\0' "$name" "$f" >> "$list"
    done < <(find "$dir" -name '*.lua' -type f -print0)
    sources+=("$name")
    continue
  fi

  dir=$LUA_CORPUS/$name
  if [ ! -d "$dir/.git" ]; then
    echo "skip $name: not fetched, run $here/fetch.sh"
    continue
  fi
  # only what the pinned checkout tracks, so vendored blobs and generated output
  # do not drift into the run
  #
  # --stage filters out the submodules: git records those as gitlinks with mode
  # 160000 and no content, and a submodule whose own name ends in .lua would
  # otherwise arrive here as a directory. [f] is a regular file on disk, which
  # is the other half of the same check.
  while IFS= read -r -d '' f; do
    [ -f "$dir/$f" ] && printf '%s\t%s\0' "$name" "$dir/$f" >> "$list"
  done < <(git -C "$dir" ls-files -z --stage -- '*.lua' | awk -v RS='\0' -v ORS='\0' '$1 != "160000" {sub(/^[^\t]*\t/, ""); print}')
  sources+=("$name")
done < "$MANIFEST"

total=$(tr -dc '\0' < "$list" | wc -c | tr -d ' ')
if [ "$total" -eq 0 ]; then
  echo "no files in the corpus" >&2
  exit 1
fi

echo "lualite:   $LUALITE"
echo "files:     $total from ${#sources[@]} sources"
echo

# ----------------------------------------------------------------- reference
#
# One process for the whole corpus. A process per file would mean thousands of
# forks, which is most of a run's time for nothing.
#
# loadall.lua takes the path-only list and reports per path, in order, so the
# tag is stripped here rather than passed through. A bash loop rather than cut,
# since a path may hold a tab and cut would split the record in the wrong place.
: > "$OUT/paths.list"
while IFS= read -r -d '' record; do
  printf '%s\0' "${record#*$'\t'}" >> "$OUT/paths.list"
done < "$list"

"$LUA" "$here/loadall.lua" "$OUT/paths.list" > "$OUT/lua.tsv" 2> "$OUT/lua.err"
if [ ! -s "$OUT/lua.tsv" ]; then
  echo "the reference produced nothing:" >&2
  cat "$OUT/lua.err" >&2
  exit 1
fi

reported=$(head -1 "$OUT/lua.tsv" | cut -f1)
# _VERSION is "Lua 5.4", with no patch level, so -v is where the exact one comes
# from. The corpus is pinned against 5.4.7 and a later patch is worth seeing.
lua_version=$("$LUA" -v 2>&1 | head -1)
if [ "$reported" != "$total" ]; then
  echo "the reference looked at $reported of $total files; the list is malformed" >&2
  exit 1
fi

echo "reference: $lua_version"
echo

# Pulled into arrays so the per-file loop below is a lookup rather than a scan:
# a scan would make the run quadratic in the corpus, which is several thousand
# files.
declare -A lua_verdict lua_lineno lua_message
while IFS=$'\t' read -r path rest; do
  lua_verdict["$path"]=ok
done < <(awk -F'\t' 'NR>1 && $1 == "ok" {print $2 "\t" "ok"}' "$OUT/lua.tsv")
while IFS=$'\t' read -r path line message; do
  lua_verdict["$path"]=err
  lua_lineno["$path"]=$line
  lua_message["$path"]=$message
done < <(awk -F'\t' 'NR>1 && $1 == "err" {print $2 "\t" $3 "\t" $4}' "$OUT/lua.tsv")

# ------------------------------------------------------------------- lualite
#
# One process per file, which is what a compiler is: the file is the unit of
# work and there is no way to hand it a batch. The colour codes come off first,
# since everything below reads the output.
#
# A file that takes longer than SLOW_SECONDS is recorded rather than killed: a
# timeout would hide how much slower it is, and the number is the finding.
#
# The exit status is what separates CRASH from a refusal, and it is the whole
# test. main prints its diagnostics and returns void, so it exits 0 whatever it
# found; anything else means the front end could not finish the file, whether
# that is a panic, an out of memory or a read that failed. A crash still prints
# a line starting with `error:`, so the message cannot be what decides this.
declare -A counts
for c in OK MISS EXTRA LOC CRASH SLOW; do counts[$c]=0; done

: > "$OUT/slow.txt"
i=0
while IFS= read -r -d '' record; do
  i=$((i + 1))
  source=${record%%$'\t'*}
  path=${record#*$'\t'}

  start=$EPOCHREALTIME
  lite=$("$LUALITE" --check "$path" 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
  status=${PIPESTATUS[0]}
  elapsed=$(perl -e "printf '%.3f', $EPOCHREALTIME - $start")

  # lualite's verdict: the first error's position and message, if it reported
  # one. The position is line:col, the line being what the class turns on.
  lite_error=$(printf '%s\n' "$lite" | grep -m1 '^error:' | sed 's/^error: //')
  lite_lineno=$(printf '%s\n' "$lite" | grep -m1 -oE '\.luac?:[0-9]+:[0-9]+' | head -1 | grep -oE '[0-9]+' | head -1)

  lv=${lua_verdict["$path"]:-ok}
  ll=${lua_lineno["$path"]:-}
  lm=${lua_message["$path"]:-}

  size=$(wc -c < "$path" | tr -d ' ')

  if [ "$status" -ne 0 ]; then
    class=CRASH
  elif [ -z "$lite_error" ] && [ "$lv" = err ]; then
    class=MISS
  elif [ -n "$lite_error" ] && [ "$lv" = ok ]; then
    class=EXTRA
  elif [ -n "$lite_error" ] && [ "$lv" = err ]; then
    # both refuse. The same line is agreement on where the problem is; a
    # different one is the two numbering the same construct differently, which
    # only reading the message can settle.
    if [ -n "$ll" ] && [ "$ll" = "$lite_lineno" ]; then
      class=OK
    else
      class=LOC
    fi
  else
    class=OK
  fi

  if [ "$elapsed" ] && perl -e "exit(($elapsed > $SLOW_SECONDS) ? 0 : 1)"; then
    [ "$class" = OK ] && class=SLOW
    printf '%s\t%s\t%s\n' "$elapsed" "$source" "$path" >> "$OUT/slow.txt"
  fi

  counts[$class]=$((counts[$class] + 1))
  # class, source, path, size, seconds, lua line, lualite line, lua message,
  # lualite message
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$class" "$source" "$path" "$size" "$elapsed" \
    "$ll" "$lite_lineno" "$lm" "$lite_error" >> "$results"

  if [ $((i % 250)) -eq 0 ]; then
    printf '  %d/%d\n' "$i" "$total" >&2
  fi
done < "$list"

# ------------------------------------------------------------------- report
echo
for c in OK MISS EXTRA LOC CRASH SLOW; do
  printf '%-6s %s\n' "$c" "${counts[$c]}"
done
echo

for c in MISS EXTRA LOC CRASH; do
  out=$OUT/$c.txt
  awk -F'\t' -v c="$c" '$1 == c' "$results" > "$out"
  if [ -s "$out" ]; then
    echo "$c (${counts[$c]}) by source:"
    cut -f2 "$out" | sort | uniq -c | sort -rn
    echo
  fi
done

if [ -s "$OUT/slow.txt" ]; then
  echo "slowest:"
  sort -rn "$OUT/slow.txt" | head -5 | cut -f1,2,3
  echo
fi

bytes=$(awk -F'\t' '{s += $4} END {print s + 0}' "$results")
secs=$(awk -F'\t' '{s += $5} END {printf "%.1f", s + 0}' "$results")
printf 'parsed %s MB in %s s of lualite time\n' \
  "$(perl -e "printf '%.1f', $bytes / 1048576")" "$secs"
echo "results: $results"

{
  echo "reference $lua_version"
  echo "lualite $LUALITE"
  echo "files $total"
  for c in OK MISS EXTRA LOC CRASH SLOW; do echo "$c ${counts[$c]}"; done
} > "$OUT/summary.txt"

if [ "${counts[CRASH]}" -gt 0 ]; then
  echo
  echo "CRASH means the front end took the process down on a real file"
  exit 1
fi
