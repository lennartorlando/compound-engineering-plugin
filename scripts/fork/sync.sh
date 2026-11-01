#!/usr/bin/env bash
# Rebases the fork branch `personal` onto upstream main and puts one fresh
# version commit on top, then runs the fork's checks. Never pushes: it writes
# the outcome for the workflow's push and issue jobs into <out-dir>:
#   result       push | noop | blocked
#   expected     the fork's personal sha at the start (the push lease)
#   report.md    why the run is blocked (blocked only)
#   sync.bundle  the new personal branch (push only)
# Run it from a full clone of the fork with personal checked out and origin
# pointing at the fork. Layout and manual resolution: scripts/fork/README.md.
#   bash scripts/fork/sync.sh <out-dir>
# Env: UPSTREAM_URL (default EveryInc upstream), FORK_SYNC_CHECKS (newline-
# separated commands replacing the default checks; the fixture tests use it).
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/EveryInc/compound-engineering-plugin.git}"
README_URL="https://github.com/lennartorlando/compound-engineering-plugin/blob/personal/scripts/fork/README.md"
CONFIG=".github/release-please-config.json"
MANIFEST=".github/.release-please-manifest.json"
VERSION_SUBJECT="fork: build version "

# The whole script runs from functions, so bash has parsed it before the
# rebase rewrites the working tree this file lives in.

blocked() {   # <title> <details (markdown)>
  echo blocked > "$OUT/result"
  {
    echo "## Fork sync blocked: $1"
    echo
    echo "- Upstream main: \`$UPSTREAM\`"
    echo "- Fork \`personal\` at run start: \`$START\`"
    echo
    printf '%s\n' "$2"
    echo
    echo "Nothing was pushed. Resolve it with the procedure in [scripts/fork/README.md]($README_URL); the next clean run closes this issue."
  } > "$OUT/report.md"
  echo "blocked: $1"
  cat "$OUT/report.md"
  exit 0
}

bullets() { sed '/^$/d; s/^/- `/; s/$/`/'; }

rebase_or_block() {   # <rebase args...>
  local files commit
  if git rebase -q "$@" > "$OUT/rebase.log" 2>&1; then return 0; fi
  files="$(git diff --name-only --diff-filter=U)"
  commit="$(git log -1 --format='%h %s' REBASE_HEAD 2>/dev/null || echo unknown)"
  git rebase --abort
  [ -n "$files" ] || { cat "$OUT/rebase.log" >&2; exit 1; }
  blocked "rebase conflict" "Fork commit \`$commit\` conflicts with upstream main \`$UPSTREAM\`.

Conflicting files:
$(printf '%s\n' "$files" | bullets)"
}

# Every version field release-please maintains, as "<file> <jq path>" lines.
version_fields() {
  jq -r '.packages | to_entries[] | .key as $pkg | .value["extra-files"][]
    | if type == "object" and .type == "json" and (.jsonpath | startswith("$."))
      then [(if $pkg == "." then .path else "\($pkg)/\(.path)" end), (.jsonpath | ltrimstr("$"))] | join(" ")
      else error("unsupported extra-files entry: \(tojson)") end' "$CONFIG"
}

# Marketplace and plugin names in a JSON manifest at a revision.
names_of() {   # <rev> <file>
  git show "$1:$2" 2>/dev/null \
    | jq -c '[.name, ((.plugins // []) | map(.name))]' 2>/dev/null || echo missing
}

default_checks() {
  local f
  echo "bun install --frozen-lockfile"
  echo "bun run release:validate"
  echo "bun run test:skill-guards"
  for f in tests/fork/*.test.ts; do [ -e "$f" ] && echo "bun test $f"; done
  for f in tests/fork/*.test.sh; do [ -e "$f" ] && echo "bash $f"; done
  return 0
}

main() {
  OUT="$1"
  mkdir -p "$OUT"
  rm -f "$OUT/result" "$OUT/report.md" "$OUT/sync.bundle"

  git fetch -q --no-tags "$UPSTREAM_URL" "+refs/heads/main:refs/remotes/upstream/main"
  START="$(git rev-parse refs/remotes/origin/personal)"
  UPSTREAM="$(git rev-parse refs/remotes/upstream/main)"
  echo "$START" > "$OUT/expected"
  git checkout -q -B personal "$START"

  # The old base: the version commit's Upstream-Base trailer, or on the first
  # run (no version commit yet) the merge-base with upstream main.
  local version_commit base
  version_commit="$(git log -1 --format=%H --grep="^$VERSION_SUBJECT" upstream/main..personal)"
  if [ -n "$version_commit" ]; then
    base="$(git log -1 --format='%(trailers:key=Upstream-Base,valueonly)' "$version_commit")"
  else
    base="$(git merge-base personal upstream/main)"
  fi

  if ! git merge-base --is-ancestor "$base" upstream/main; then
    blocked "upstream history rewritten" "The fork's upstream base \`$base\` is no longer an ancestor of upstream main, so upstream rewrote its history. The fork patches cannot be replayed automatically."
  fi

  if [ "$version_commit" = "$START" ] && [ "$base" = "$UPSTREAM" ]; then
    echo noop > "$OUT/result"
    echo "noop: upstream unchanged and no new fork commit"
    exit 0
  fi

  # Drop the old version commit, keeping any fork commits made on top of it,
  # then replay the fork patches onto upstream main.
  if [ -n "$version_commit" ]; then rebase_or_block --onto "$version_commit^" "$version_commit"; fi
  rebase_or_block --onto upstream/main "$base"

  local fields renamed="" file path
  fields="$(version_fields)"
  for file in $(printf '%s\n' "$fields" | cut -d' ' -f1 | sort -u); do
    [ "$(names_of "$START" "$file")" = "$(names_of HEAD "$file")" ] || renamed="$renamed$file
"
  done
  if [ -n "$renamed" ]; then
    blocked "name changed" "Upstream changed a marketplace or plugin name the fork relies on (compared with the fork's personal before this run).

Affected files:
$(printf '%s' "$renamed" | bullets)"
  fi

  # The version commit: every release-please field becomes <upstream value>-lo.<sha7>,
  # sha7 being the commit below it, so a fork-only change also moves the version.
  local sha7 suffix value version
  sha7="$(git rev-parse --short=7 HEAD)"
  suffix="-lo.$sha7"
  while read -r file path; do
    value="$(git show "upstream/main:$file" | jq -er "$path")"
    jq --arg v "$value$suffix" "$path = \$v" "$file" > "$file.tmp"
    mv "$file.tmp" "$file"
    git add -- "$file"
  done <<< "$fields"
  git show "upstream/main:$MANIFEST" | jq --arg s "$suffix" 'map_values(. + $s)' > "$MANIFEST"
  git add -- "$MANIFEST"
  version="$(git show upstream/main:package.json | jq -er .version)$suffix"
  git commit -q --no-verify -m "$VERSION_SUBJECT$version" -m "Upstream-Base: $UPSTREAM"

  local checks cmd failed=""
  checks="${FORK_SYNC_CHECKS:-$(default_checks)}"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    echo "== $cmd"
    bash -c "$cmd" < /dev/null || failed="$failed$cmd
"
  done <<< "$checks"
  if [ -n "$failed" ]; then
    blocked "check failed" "The rebase was clean, but these checks failed on the result (output in the workflow run log):
$(printf '%s' "$failed" | bullets)"
  fi

  git bundle create -q "$OUT/sync.bundle" personal
  echo push > "$OUT/result"
  echo "push: $version (personal $START -> $(git rev-parse HEAD), upstream $UPSTREAM)"
}

main "$@"
