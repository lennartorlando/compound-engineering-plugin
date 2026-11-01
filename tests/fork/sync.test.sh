#!/usr/bin/env bash
# Fixture tests for the daily fork sync: scripts/fork/sync.sh plus the push and
# issue steps of .github/workflows/fork-sync.yml, which run here exactly as
# written in the workflow (extracted by step id). Every run uses local "upstream"
# and "fork" repos in a temp dir and a `gh` stub on PATH; nothing touches the network.
#   bash tests/fork/sync.test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$REPO/scripts/fork/sync.sh"
WORKFLOW="$REPO/.github/workflows/fork-sync.yml"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# Isolated git identity and config: no user hooks, signing, or default-branch surprises.
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
git config --global user.name "Fixture"
git config --global user.email "fixture@example.invalid"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

FAILS=0
ok() { echo "ok   $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else fail "$name"; fi; }
eq() { [ "$1" = "$2" ] || { echo "     expected [$2], got [$1]"; return 1; }; }
has() { grep -qF -- "$2" "$1" || { echo "     [$2] not in $1"; return 1; }; }

# --- workflow steps, extracted by step id so the tests run the real step code ---
step_script() {   # <step-id>
  awk -v id="$1" '
    $0 ~ "^ *id: " id "$" { found = 1; next }
    found && !inrun && $0 ~ /^ *run: \|$/ { inrun = 1; match($0, /^ */); ind = RLENGTH; next }
    inrun {
      if ($0 ~ /^ *$/) { print ""; next }
      match($0, /^ */); if (RLENGTH <= ind) exit
      print substr($0, ind + 3)
    }' "$WORKFLOW"
}
job_block() {   # <job-name>: the job's lines without comments
  awk -v j="$1" '
    /^jobs:/ { injobs = 1; next }
    injobs && /^  [A-Za-z0-9_-]+:/ { cur = $1; sub(":", "", cur) }
    injobs && cur == j && $0 !~ /^ *#/' "$WORKFLOW"
}
step_script push > "$ROOT/push-step.sh"
step_script report > "$ROOT/report-step.sh"
[ -s "$ROOT/push-step.sh" ] && [ -s "$ROOT/report-step.sh" ] || { echo "FAIL could not extract the push and report steps from $WORKFLOW"; exit 1; }

# gh stub: one fixture's issue state lives in $GH_STUB_DIR (open = number of the open issue).
cat > "$ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -eu
d="$GH_STUB_DIR"
echo "gh $*" >> "$d/calls"
cmd="$1 $2"; shift 2
target=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) body="$2"; shift 2 ;;
    --comment|--title|--label|--state|--json|--jq|--color|--description) shift 2 ;;
    --*) shift ;;
    *) target="$1"; shift ;;
  esac
done
case "$cmd" in
  "issue list") [ -f "$d/open" ] && cat "$d/open"; exit 0 ;;
  "issue create")
    n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$d/count"; echo "$n" > "$d/open"; cp "$body" "$d/issue-$n.md"
    echo "https://github.invalid/issues/$n" ;;
  "issue comment")
    k=$(( $(ls "$d" | grep -c '^comment-' || true) + 1 ))
    cp "$body" "$d/comment-$k.md" ;;
  "issue close") [ "$(cat "$d/open" 2>/dev/null)" = "$target" ] && rm -f "$d/open" ;;
  "label create") ;;
  *) echo "gh stub: unexpected $cmd" >&2; exit 1 ;;
esac
EOF
chmod +x "$ROOT/bin/gh"

json_set() {   # <file> <jq-assignment>
  jq "$2" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
upstream_commit() {   # <fixture> <message>: commit everything in the fixture's upstream
  git -C "$1/upstream" add -A
  git -C "$1/upstream" commit -q -m "$2"
}
dev_sync() {   # <fixture>: bring the developer clone up to the fork's personal
  git -C "$1/dev" fetch -q origin
  git -C "$1/dev" reset -q --hard origin/personal
}

# A fixture: upstream with the release-please layout in miniature, a fork remote
# (bare, default branch personal) carrying one patch and a fork test, and a first
# sync run that adds the version commit.
make_fixture() {   # <name>
  local fx="$ROOT/$1" up
  up="$fx/upstream"
  mkdir -p "$fx/gh" "$up/.github" "$up/.claude-plugin" "$up/.omp-plugin"
  git init -q "$up"
  cat > "$up/.github/release-please-config.json" <<'EOF'
{
  "packages": {
    ".": {
      "release-type": "simple",
      "extra-files": [
        { "type": "json", "path": "package.json", "jsonpath": "$.version" },
        { "type": "json", "path": "plugin.json", "jsonpath": "$.version" },
        { "type": "json", "path": ".omp-plugin/marketplace.json", "jsonpath": "$.plugins[0].version" }
      ]
    },
    ".claude-plugin": {
      "release-type": "simple",
      "extra-files": [
        { "type": "json", "path": "marketplace.json", "jsonpath": "$.metadata.version" }
      ]
    }
  }
}
EOF
  echo '{".": "1.0.0", ".claude-plugin": "1.0.3"}' | jq . > "$up/.github/.release-please-manifest.json"
  echo '{"name": "demo", "version": "1.0.0"}' | jq . > "$up/package.json"
  echo '{"name": "demo", "version": "1.0.0"}' | jq . > "$up/plugin.json"
  echo '{"name": "demo-plugin", "plugins": [{"name": "demo", "version": "1.0.0", "source": "./"}]}' | jq . > "$up/.omp-plugin/marketplace.json"
  echo '{"name": "demo-plugin", "metadata": {"version": "1.0.3"}, "plugins": [{"name": "demo", "source": "./"}]}' | jq . > "$up/.claude-plugin/marketplace.json"
  printf 'a\nb\nc\nd\ne\n' > "$up/notes.txt"
  upstream_commit "$fx" "initial"

  git clone -q --bare "$up" "$fx/fork.git"
  git -C "$fx/fork.git" branch -m main personal
  git -C "$fx/fork.git" symbolic-ref HEAD refs/heads/personal

  git clone -q -b personal "$fx/fork.git" "$fx/dev"
  mkdir -p "$fx/dev/tests/fork"
  printf 'a\nb\nc fork\nd\ne\n' > "$fx/dev/notes.txt"
  printf '#!/usr/bin/env bash\n[ ! -e broken.txt ]\n' > "$fx/dev/tests/fork/demo.test.sh"
  git -C "$fx/dev" add -A
  git -C "$fx/dev" commit -q -m "fork: patch notes"
  git -C "$fx/dev" push -q origin personal

  cycle "$fx" boot
  [ "$RESULT" = push ] && [ "$PUSH_RESULT" = success ] || { echo "FAIL $1: bootstrap run did not push (result $RESULT, push $PUSH_RESULT)"; cat "$fx/sync-boot.log"; exit 1; }
}

fork_tip() { git -C "$1/fork.git" rev-parse personal; }
upstream_tip() { git -C "$1/upstream" rev-parse main; }
tip_subject() { git -C "$1/fork.git" log -1 --format=%s "personal${2:-}"; }
tip_base() { git -C "$1/fork.git" log -1 --format='%(trailers:key=Upstream-Base,valueonly)' personal | sed '/^$/d'; }
fork_json() { git -C "$1/fork.git" show "personal:$2" | jq -r "$3"; }
version_commits() { git -C "$1/fork.git" log --format=%s "$(upstream_tip "$1")..personal" | grep -c '^fork: build version ' || true; }

# The sync job: a fresh full clone of the fork (as actions/checkout does), then sync.sh.
run_sync() {   # <fixture> <label>
  local fx="$1" label="$2" work="$1/run-$2"
  JOB="$fx/job-$label"
  mkdir -p "$JOB"
  git clone -q -b personal "$fx/fork.git" "$work"
  if ! (cd "$work" && UPSTREAM_URL="$fx/upstream" FORK_SYNC_CHECKS="${CHECKS:-bash tests/fork/demo.test.sh}" \
        bash "$SYNC" "$JOB/outcome") > "$fx/sync-$label.log" 2>&1; then
    echo "FAIL sync.sh exited non-zero in $fx ($label)"; cat "$fx/sync-$label.log"; exit 1
  fi
  RESULT="$(cat "$JOB/outcome/result")"
}
run_push() {   # <fixture>: the push job's step, against the fixture's fork remote
  (cd "$JOB" && RUNNER_TEMP="$JOB" FORK_SYNC_TOKEN=dummy PUSH_URL="$1/fork.git" \
    bash -eo pipefail "$ROOT/push-step.sh") > "$JOB/push.log" 2>&1
}
run_report() {   # <fixture>: the issue step, with the gh stub
  (cd "$JOB" && RUNNER_TEMP="$JOB" PUSH_RESULT="$PUSH_RESULT" GH_TOKEN=dummy GH_REPO=owner/fork \
    GITHUB_SERVER_URL=https://github.invalid GITHUB_REPOSITORY=owner/fork GITHUB_RUN_ID=1 \
    GH_STUB_DIR="$1/gh" PATH="$ROOT/bin:$PATH" bash -eo pipefail "$ROOT/report-step.sh") > "$JOB/report.log" 2>&1 \
    || { echo "FAIL report step exited non-zero"; cat "$JOB/report.log"; exit 1; }
}
cycle() {   # <fixture> <label>: one whole workflow run
  run_sync "$1" "$2"
  PUSH_RESULT=skipped
  if [ "$RESULT" = push ]; then
    if run_push "$1"; then PUSH_RESULT=success; else PUSH_RESULT=failure; fi
  fi
  run_report "$1"
}
issues_created() { cat "$1/gh/count" 2>/dev/null || echo 0; }
open_issue() { cat "$1/gh/open" 2>/dev/null || echo none; }

# 1. Upstream gains two non-overlapping commits.
make_fixture s1; fx="$ROOT/s1"
echo one > "$fx/upstream/new1.txt"; upstream_commit "$fx" "upstream one"
echo two > "$fx/upstream/new2.txt"; upstream_commit "$fx" "upstream two"
cycle "$fx" run
check "1 upstream moved: result is push" eq "$RESULT" push
check "1 upstream moved: push succeeded" eq "$PUSH_RESULT" success
check "1 upstream moved: version commit on top" eq "$(tip_subject "$fx" | sed 's/lo\..*/lo./')" "fork: build version 1.0.0-lo."
check "1 upstream moved: trailer names the new base" eq "$(tip_base "$fx")" "$(upstream_tip "$fx")"
check "1 upstream moved: fork patch below the version commit" eq "$(tip_subject "$fx" '~1')" "fork: patch notes"
check "1 upstream moved: upstream main is in the fork's history" git -C "$fx/fork.git" merge-base --is-ancestor "$(upstream_tip "$fx")" personal
check "1 upstream moved: exactly one version commit" eq "$(version_commits "$fx")" 1
check "1 upstream moved: suffix is the fork patch's short sha" eq "$(fork_json "$fx" package.json .version)" "1.0.0-lo.$(git -C "$fx/fork.git" rev-parse --short=7 personal~1)"
check "1 upstream moved: no issue opened" eq "$(issues_created "$fx")" 0

# 2. Upstream unchanged, version commit on top: nothing pushed, the open issue is closed.
make_fixture s2; fx="$ROOT/s2"
echo 7 > "$fx/gh/open"
before="$(fork_tip "$fx")"
cycle "$fx" run
check "2 nothing to do: result is no-op" eq "$RESULT" noop
check "2 nothing to do: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "2 nothing to do: open issue closed" has "$fx/gh/calls" "issue close 7"
check "2 nothing to do: no issue open afterwards" eq "$(open_issue "$fx")" none

# 3. Upstream changes the line a fork commit changes.
make_fixture s3; fx="$ROOT/s3"
printf 'a\nb\nc upstream\nd\ne\n' > "$fx/upstream/notes.txt"; upstream_commit "$fx" "upstream edits c"
before="$(fork_tip "$fx")"
cycle "$fx" conflict
check "3 conflict: result is blocked" eq "$RESULT" blocked
check "3 conflict: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "3 conflict: one issue created" eq "$(issues_created "$fx")" 1
check "3 conflict: issue names the file" has "$fx/gh/issue-1.md" notes.txt
check "3 conflict: issue names the upstream sha" has "$fx/gh/issue-1.md" "$(upstream_tip "$fx")"
check "3 conflict: issue links the README procedure" has "$fx/gh/issue-1.md" "scripts/fork/README.md"
check "3 conflict: issue is labeled fork-sync" has "$fx/gh/calls" "--label fork-sync"

# 4. A second blocked run comments on the open issue instead of opening another.
cycle "$fx" conflict2
check "4 second conflict: still one issue" eq "$(issues_created "$fx")" 1
check "4 second conflict: comment on the open issue" has "$fx/gh/calls" "issue comment 1"
check "4 second conflict: comment names the file" has "$fx/gh/comment-1.md" notes.txt

# 9. Manual resolution per scripts/fork/README.md, then the next run versions it and closes the issue.
fix="$fx/manual"
git clone -q -b personal "$fx/fork.git" "$fix"
git -C "$fix" remote add upstream "$fx/upstream"
git -C "$fix" fetch -q upstream
v="$(git -C "$fix" log -1 --format=%H --grep='^fork: build version ' upstream/main..personal)"
base="$(git -C "$fix" log -1 --format='%(trailers:key=Upstream-Base,valueonly)' "$v" | sed '/^$/d')"
lease="$(git -C "$fix" rev-parse origin/personal)"
git -C "$fix" rebase -q --onto "$v^" "$v"
if git -C "$fix" rebase -q --onto upstream/main "$base" > /dev/null 2>&1; then fail "9 manual: expected the README rebase to stop on the conflict"; fi
printf 'a\nb\nc upstream and fork\nd\ne\n' > "$fix/notes.txt"
git -C "$fix" add notes.txt
GIT_EDITOR=true git -C "$fix" rebase --continue > /dev/null
git -C "$fix" push -q --force-with-lease="personal:$lease" origin personal
cycle "$fx" after-manual
check "9 after manual resolution: result is push" eq "$RESULT" push
check "9 after manual resolution: push succeeded" eq "$PUSH_RESULT" success
check "9 after manual resolution: new version commit on top" eq "$(tip_subject "$fx" | sed 's/lo\..*/lo./')" "fork: build version 1.0.0-lo."
check "9 after manual resolution: trailer names upstream main" eq "$(tip_base "$fx")" "$(upstream_tip "$fx")"
check "9 after manual resolution: issue closed" eq "$(open_issue "$fx")" none
check "9 after manual resolution: close call on issue 1" has "$fx/gh/calls" "issue close 1"

# 5. Upstream rewrote the history the fork is based on.
make_fixture s5; fx="$ROOT/s5"
git -C "$fx/upstream" commit -q --amend -m "initial, rewritten"
before="$(fork_tip "$fx")"
cycle "$fx" run
check "5 history rewritten: result is blocked" eq "$RESULT" blocked
check "5 history rewritten: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "5 history rewritten: issue says so" has "$fx/gh/issue-1.md" "upstream history rewritten"

# 6. Upstream renames the marketplace.
make_fixture s6; fx="$ROOT/s6"
json_set "$fx/upstream/.claude-plugin/marketplace.json" '.name = "renamed-market"'
upstream_commit "$fx" "rename marketplace"
before="$(fork_tip "$fx")"
cycle "$fx" run
check "6 rename: result is blocked" eq "$RESULT" blocked
check "6 rename: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "6 rename: issue names the manifest" has "$fx/gh/issue-1.md" ".claude-plugin/marketplace.json"

# 7. Upstream releases a new version in the same run.
make_fixture s7; fx="$ROOT/s7"
up="$fx/upstream"
json_set "$up/package.json" '.version = "1.1.0"'
json_set "$up/plugin.json" '.version = "1.1.0"'
json_set "$up/.omp-plugin/marketplace.json" '.plugins[0].version = "1.1.0"'
json_set "$up/.claude-plugin/marketplace.json" '.metadata.version = "1.0.4"'
json_set "$up/.github/.release-please-manifest.json" '.["."] = "1.1.0" | .[".claude-plugin"] = "1.0.4"'
upstream_commit "$fx" "chore: release main"
cycle "$fx" run
sha7="$(git -C "$fx/fork.git" rev-parse --short=7 personal~1)"
check "7 upstream release: result is push" eq "$RESULT" push
check "7 upstream release: subject carries the new version" eq "$(tip_subject "$fx")" "fork: build version 1.1.0-lo.$sha7"
check "7 upstream release: package.json" eq "$(fork_json "$fx" package.json .version)" "1.1.0-lo.$sha7"
check "7 upstream release: plugin.json" eq "$(fork_json "$fx" plugin.json .version)" "1.1.0-lo.$sha7"
check "7 upstream release: omp marketplace entry" eq "$(fork_json "$fx" .omp-plugin/marketplace.json '.plugins[0].version')" "1.1.0-lo.$sha7"
check "7 upstream release: claude marketplace" eq "$(fork_json "$fx" .claude-plugin/marketplace.json .metadata.version)" "1.0.4-lo.$sha7"
check "7 upstream release: release-please manifest root" eq "$(fork_json "$fx" .github/.release-please-manifest.json '.["."]')" "1.1.0-lo.$sha7"
check "7 upstream release: release-please manifest marketplace" eq "$(fork_json "$fx" .github/.release-please-manifest.json '.[".claude-plugin"]')" "1.0.4-lo.$sha7"

# 8. Upstream unchanged, a new fork commit lands on top of the old version commit.
make_fixture s8; fx="$ROOT/s8"
old_version="$(fork_json "$fx" package.json .version)"
dev_sync "$fx"
echo extra > "$fx/dev/extra.txt"
git -C "$fx/dev" add -A
git -C "$fx/dev" commit -q -m "fork: add extra"
git -C "$fx/dev" push -q origin personal
cycle "$fx" run
check "8 new fork commit: result is push" eq "$RESULT" push
check "8 new fork commit: version commit on top" eq "$(tip_subject "$fx" | sed 's/lo\..*/lo./')" "fork: build version 1.0.0-lo."
check "8 new fork commit: new commit directly below it" eq "$(tip_subject "$fx" '~1')" "fork: add extra"
check "8 new fork commit: old version commit dropped" eq "$(version_commits "$fx")" 1
check "8 new fork commit: version changed" eq "$([ "$(fork_json "$fx" package.json .version)" != "$old_version" ] && echo changed)" changed

# 10. Workflow: the push token stays in the push job, which runs no bun and no repo script.
token_total="$(grep -c FORK_SYNC_TOKEN "$WORKFLOW" || true)"
token_push="$(job_block push | grep -c FORK_SYNC_TOKEN || true)"
check "10 workflow: FORK_SYNC_TOKEN is used" eq "$([ "$token_push" -gt 0 ] && echo yes)" yes
check "10 workflow: FORK_SYNC_TOKEN only in the push job" eq "$token_total" "$token_push"
check "10 workflow: push job calls no bun" eq "$(job_block push | grep -cw bun || true)" 0
check "10 workflow: push job checks out no repo code" eq "$(job_block push | grep -c 'actions/checkout' || true)" 0
check "10 workflow: push job runs no repo script" eq "$(job_block push | grep -cE 'scripts/|\.sh\b' || true)" 0
# Without a checkout the runner holds no repository files, so no repo script can run there.
check "10 workflow: issue job checks out no repo code and calls no bun" eq "$(job_block report | grep -cE 'actions/checkout|\bbun\b' || true)" 0

# 11. The fork moves while the run works: the lease rejects the push.
make_fixture s11; fx="$ROOT/s11"
echo one > "$fx/upstream/new1.txt"; upstream_commit "$fx" "upstream one"
run_sync "$fx" run
check "11 lease: sync wants to push" eq "$RESULT" push
dev_sync "$fx"
echo meanwhile > "$fx/dev/meanwhile.txt"
git -C "$fx/dev" add -A
git -C "$fx/dev" commit -q -m "fork: pushed during the run"
git -C "$fx/dev" push -q origin personal
moved="$(fork_tip "$fx")"
if run_push "$fx"; then PUSH_RESULT=success; else PUSH_RESULT=failure; fi
check "11 lease: push rejected" eq "$PUSH_RESULT" failure
check "11 lease: nothing overwritten" eq "$(fork_tip "$fx")" "$moved"
run_report "$fx"
check "11 lease: issue opened for the rejected push" has "$fx/gh/issue-1.md" "push rejected"

# 12. Rebase is clean but a fork test fails.
make_fixture s12; fx="$ROOT/s12"
echo oops > "$fx/upstream/broken.txt"; upstream_commit "$fx" "upstream adds broken.txt"
before="$(fork_tip "$fx")"
cycle "$fx" run
check "12 red test: result is blocked" eq "$RESULT" blocked
check "12 red test: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "12 red test: issue names the test" has "$fx/gh/issue-1.md" "tests/fork/demo.test.sh"
check "12 red test: no bundle handed to the push job" eq "$([ -e "$JOB/outcome/sync.bundle" ] && echo present || echo absent)" absent

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all checks passed"
