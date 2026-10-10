#!/usr/bin/env bash
# Materialises the corpus described by manifest.txt.
#
# Checkouts land outside the repository, under $LUA_CORPUS (default
# ~/.cache/lualite-corpus), so that a run is reproducible without the source
# trees sitting in the working copy. Re-running is cheap: a source already
# checked out at the pinned sha is left alone.

set -uo pipefail

LUA_CORPUS=${LUA_CORPUS:-$HOME/.cache/lualite-corpus}
MANIFEST=${1:-$(dirname "$0")/manifest.txt}

mkdir -p "$LUA_CORPUS"

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf %s "$s"
}

# the fields are split on | rather than whitespace, since a local path may
# contain spaces
while IFS='|' read -r name url sha; do
  # trim the padding the manifest is written with for readability
  name=$(trim "$name")
  url=$(trim "$url")
  sha=$(trim "$sha")

  # comments and blank lines
  [ -z "${name:-}" ] && continue
  case $name in \#*) continue ;; esac

  if [ "${url#local:}" != "$url" ]; then
    dir=${url#local:}
    if [ -d "$dir" ]; then
      echo "have $name ($dir)"
    else
      echo "skip $name: $dir is not there"
    fi
    continue
  fi

  dir="$LUA_CORPUS/$name"

  if [ -d "$dir/.git" ]; then
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
    if [ "$head" = "$sha" ]; then
      echo "have $name ($sha)"
      continue
    fi
    echo "moving $name off $head"
    rm -rf "$dir"
  fi

  # the sha is a commit, not a branch, so a shallow clone cannot ask for it
  # directly: clone the default branch shallow, then fetch the one commit
  echo "fetch $name"
  git clone --quiet --no-checkout --filter=blob:none "$url" "$dir" || {
    echo "  clone failed"
    continue
  }
  if ! git -C "$dir" fetch --quiet --depth 1 origin "$sha"; then
    echo "  cannot reach $sha"
    continue
  fi
  git -C "$dir" checkout --quiet "$sha" || echo "  checkout failed"
done < "$MANIFEST"

echo
echo "corpus at $LUA_CORPUS"
