#!/usr/bin/env bash
# Fixture tests for the daily fork sync: scripts/fork/sync.sh (sync and checks
# runs) plus the push and issue steps of .github/workflows/fork-sync.yml, which
# run here exactly as written in the workflow (extracted by step id); the job
# conditions between them are asserted statically in scenario 10. Every run uses
# local "upstream" and "fork" repos in a temp dir and a `gh` stub on PATH;
# nothing touches the network.
#   bash tests/fork/sync.test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$REPO/scripts/fork/sync.sh"
WORKFLOW="$REPO/.github/workflows/fork-sync.yml"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

# No inherited git, harness or proxy settings reach the fixtures (a GIT_DIR from
# a hook would aim them at the outer repo), then isolated git identity and
# config: no user hooks, signing, or default-branch surprises.
for v in $(env | sed -nE 's/^((GIT|CODEX|CLAUDE)_[A-Za-z0-9_]*)=.*/\1/p'); do unset "$v"; done
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$ROOT/gitconfig"
git config --global user.name "Fixture"
git config --global user.email "fixture@example.invalid"
git config --global init.defaultBranch main
git config --global advice.detachedHead false
git config --global commit.gpgsign false
git config --global tag.gpgsign false

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
job_key() {   # <job-name> <key>: the value of a job-level key such as if or needs
  job_block "$1" | sed -n "s/^    $2: //p"
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
  [ "$RESULT" = push ] && [ "$PUSH_RESULT" = success ] || { echo "FAIL $1: bootstrap run did not push (result $RESULT, push $PUSH_RESULT)"; cat "$fx/sync-boot.log" "$fx/checks-boot.log"; exit 1; }
}

fork_tip() { git -C "$1/fork.git" rev-parse personal; }
upstream_tip() { git -C "$1/upstream" rev-parse main; }
tip_subject() { git -C "$1/fork.git" log -1 --format=%s "personal${2:-}"; }
tip_base() { git -C "$1/fork.git" log -1 --format='%(trailers:key=Upstream-Base,valueonly)' personal | sed '/^$/d'; }
fork_json() { git -C "$1/fork.git" show "personal:$2" | jq -r "$3"; }
version_commits() { git -C "$1/fork.git" log --format=%s "$(upstream_tip "$1")..personal" | grep -c '^fork: build version ' || true; }

# Each job's result as GitHub reports it (success | failure | skipped) and its outcome.
# The sync job: a fresh full clone of the fork (as actions/checkout does), then sync.sh.
run_sync() {   # <fixture> <label>
  local fx="$1" label="$2" work="$1/run-$2"
  JOB="$fx/job-$label"
  mkdir -p "$JOB"
  git clone -q -b personal "$fx/fork.git" "$work"
  SYNC_JOB=success
  (cd "$work" && UPSTREAM_URL="$fx/upstream" bash "$SYNC" "$JOB/outcome") > "$fx/sync-$label.log" 2>&1 || SYNC_JOB=failure
  RESULT="$(cat "$JOB/outcome/result" 2>/dev/null || echo none)"
}
# The checks job: its own clone of the bundle the sync job produced, then the checks.
run_checks() {   # <fixture> <label>
  local fx="$1" label="$2" tree="$1/checks-$2"
  git clone -q -b personal "$JOB/outcome/sync.bundle" "$tree"
  CHECKS_JOB=success
  (cd "$tree" && FORK_SYNC_CHECKS="${CHECKS:-bash tests/fork/demo.test.sh}" bash "$SYNC" checks "$JOB/checks") \
    > "$fx/checks-$label.log" 2>&1 || CHECKS_JOB=failure
  CHECKS_OUT="$(cat "$JOB/checks/result" 2>/dev/null || echo none)"
}
run_push() {   # <fixture>: the push job's step, against the fixture's fork remote
  (cd "$JOB" && RUNNER_TEMP="$JOB" FORK_SYNC_TOKEN=dummy PUSH_URL="$1/fork.git" \
    TIP="$(cat "$JOB/outcome/tip")" EXPECTED="$(cat "$JOB/outcome/expected")" \
    bash -eo pipefail "$ROOT/push-step.sh") > "$JOB/push.log" 2>&1
}
# The issue step, with the gh stub; it gets an artifact only from a job that succeeded.
run_report() {   # <fixture>
  local temp="$JOB/report"
  rm -rf "$temp"; mkdir -p "$temp"
  if [ "$SYNC_JOB" = success ]; then cp -R "$JOB/outcome" "$temp/outcome"; fi
  if [ "$CHECKS_JOB" = success ]; then cp -R "$JOB/checks" "$temp/checks"; fi
  (cd "$temp" && RUNNER_TEMP="$temp" SYNC_RESULT="$SYNC_JOB" CHECKS_RESULT="$CHECKS_JOB" PUSH_RESULT="$PUSH_RESULT" \
    GH_TOKEN=dummy GH_REPO=owner/fork GITHUB_SERVER_URL=https://github.invalid GITHUB_REPOSITORY=owner/fork GITHUB_RUN_ID=1 \
    GH_STUB_DIR="$1/gh" PATH="$ROOT/bin:$PATH" bash -eo pipefail "$ROOT/report-step.sh") > "$JOB/report.log" 2>&1 \
    || { echo "FAIL report step exited non-zero"; cat "$JOB/report.log"; exit 1; }
}
# One whole workflow run; the job conditions it follows are the workflow's (scenario 10).
cycle() {   # <fixture> <label>
  run_sync "$1" "$2"
  CHECKS_JOB=skipped CHECKS_OUT=none PUSH_RESULT=skipped
  if [ "$SYNC_JOB" = success ] && [ "$RESULT" = push ]; then
    run_checks "$1" "$2"
    if [ "$CHECKS_JOB" = success ] && [ "$CHECKS_OUT" = pass ]; then
      if run_push "$1"; then PUSH_RESULT=success; else PUSH_RESULT=failure; fi
    fi
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
check "3 conflict: issue is labeled fork-sync" eq "$(grep -c '^gh issue create .*--label fork-sync' "$fx/gh/calls" || true)" 1

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

# 10. Workflow: the push token stays in the push job, which runs no bun and no repo script;
# repository code runs only in the checks job, and the jobs gate each other as cycle() does.
token_total="$(grep -c FORK_SYNC_TOKEN "$WORKFLOW" || true)"
token_push="$(job_block push | grep -c FORK_SYNC_TOKEN || true)"
check "10 workflow: FORK_SYNC_TOKEN is used" eq "$([ "$token_push" -gt 0 ] && echo yes)" yes
check "10 workflow: FORK_SYNC_TOKEN only in the push job" eq "$token_total" "$token_push"
check "10 workflow: push job calls no bun" eq "$(job_block push | grep -cw bun || true)" 0
check "10 workflow: push job checks out no repo code" eq "$(job_block push | grep -c 'actions/checkout' || true)" 0
check "10 workflow: push job runs no repo script" eq "$(job_block push | grep -cE 'scripts/|\.sh\b' || true)" 0
# Without a checkout the runner holds no repository files, so no repo script can run there.
check "10 workflow: sync job gets a read-only token and keeps no credentials" eq "$(job_block sync | grep -cE 'contents: read|persist-credentials: false')/$(job_block sync | grep -c 'write' || true)" 2/0
check "10 workflow: issue job checks out no repo code and calls no bun" eq "$(job_block report | grep -cE 'actions/checkout|\bbun\b' || true)" 0
check "10 workflow: sync job calls no bun and runs no checks" eq "$(job_block sync | grep -cE '\bbun\b|sync\.sh checks' || true)" 0
check "10 workflow: checks job gets a read-only token and no secret" eq "$(job_block checks | grep -c 'contents: read')/$(job_block checks | grep -cE 'write|secrets\.' || true)" 1/0
check "10 workflow: checks job hands on its own artifact" eq "$(job_block checks | grep -c 'name: fork-sync-checks$')/$(job_block checks | grep -c 'name: fork-sync-outcome$')" 1/1
check "10 workflow: checks job runs only after a sync that wants to push" eq "$(job_key checks needs)|$(job_key checks if)" "sync|needs.sync.outputs.result == 'push'"
check "10 workflow: push needs a sync that wants to push and passing checks" eq "$(job_key push needs)|$(job_key push if)" "[sync, checks]|needs.sync.outputs.result == 'push' && needs.checks.result == 'success' && needs.checks.outputs.result == 'pass'"
check "10 workflow: push pushes the sha the sync job recorded" eq "$(job_block push | grep -cE 'TIP: \$\{\{ needs\.sync\.outputs\.tip \}\}|EXPECTED: \$\{\{ needs\.sync\.outputs\.expected \}\}|push --force-with-lease="personal:\$EXPECTED" "\$PUSH_URL" "\$TIP:refs/heads/personal"')" 3
check "10 workflow: report runs after every job unless the run was cancelled" eq "$(job_key report needs)|$(job_key report if)" '[sync, checks, push]|${{ !cancelled() }}'

# 11. The fork moves while the run works: the lease rejects the push.
make_fixture s11; fx="$ROOT/s11"
echo one > "$fx/upstream/new1.txt"; upstream_commit "$fx" "upstream one"
run_sync "$fx" run
check "11 lease: sync wants to push" eq "$RESULT" push
run_checks "$fx" run
check "11 lease: checks pass" eq "$CHECKS_OUT" pass
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

# 12. Rebase is clean but a fork test fails in the checks job.
make_fixture s12; fx="$ROOT/s12"
echo oops > "$fx/upstream/broken.txt"; upstream_commit "$fx" "upstream adds broken.txt"
before="$(fork_tip "$fx")"
cycle "$fx" run
check "12 red test: sync wants to push" eq "$RESULT" push
check "12 red test: checks fail" eq "$CHECKS_JOB/$CHECKS_OUT" success/fail
check "12 red test: push job skipped" eq "$PUSH_RESULT" skipped
check "12 red test: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "12 red test: issue says a check failed" has "$fx/gh/issue-1.md" "check failed"
check "12 red test: issue names the test" has "$fx/gh/issue-1.md" "tests/fork/demo.test.sh"

# 13. Upstream adds a new release-please version file: no false rename, it gets the fork version.
make_fixture s13; fx="$ROOT/s13"
mkdir -p "$fx/upstream/.new-plugin"
echo '{"name": "demo", "version": "1.0.0"}' | jq . > "$fx/upstream/.new-plugin/plugin.json"
json_set "$fx/upstream/.github/release-please-config.json" '.packages["."]["extra-files"] += [{"type": "json", "path": ".new-plugin/plugin.json", "jsonpath": "$.version"}]'
upstream_commit "$fx" "add a new plugin manifest"
cycle "$fx" run
check "13 new manifest: result is push" eq "$RESULT" push
check "13 new manifest: push succeeded" eq "$PUSH_RESULT" success
check "13 new manifest: new file carries the fork version" eq "$(fork_json "$fx" .new-plugin/plugin.json .version)" "1.0.0-lo.$(git -C "$fx/fork.git" rev-parse --short=7 personal~1)"
check "13 new manifest: no issue opened" eq "$(issues_created "$fx")" 0

# 14. A check commits and moves personal in its clone: what is pushed is still the sync job's version commit.
make_fixture s14; fx="$ROOT/s14"
echo one > "$fx/upstream/new1.txt"; upstream_commit "$fx" "upstream one"
CHECKS='bash tests/fork/demo.test.sh && echo forged > forged.txt && git add forged.txt && git commit -q -m forged && [ "$(git rev-parse personal)" = "$(git rev-parse HEAD)" ]' cycle "$fx" run
check "14 check moves personal: checks pass" eq "$CHECKS_OUT" pass
check "14 check moves personal: push succeeded" eq "$PUSH_RESULT" success
check "14 check moves personal: pushed tip is the sync job's version commit" eq "$(fork_tip "$fx")" "$(cat "$JOB/outcome/tip")"
check "14 check moves personal: tip is a version commit" eq "$(tip_subject "$fx" | sed 's/lo\..*/lo./')" "fork: build version 1.0.0-lo."

# 15. A check replaces the sync job's bundle with a forged one: the push job refuses it.
make_fixture s15; fx="$ROOT/s15"
echo one > "$fx/upstream/new1.txt"; upstream_commit "$fx" "upstream one"
before="$(fork_tip "$fx")"
CHECKS="echo forged > forged.txt && git add forged.txt && git commit -q -m forged && git bundle create -q '$fx/job-run/outcome/sync.bundle' personal" cycle "$fx" run
check "15 forged bundle: checks pass" eq "$CHECKS_OUT" pass
check "15 forged bundle: push refused" eq "$PUSH_RESULT" failure
check "15 forged bundle: push log names the mismatch" has "$JOB/push.log" "not the sha the sync job recorded"
check "15 forged bundle: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "15 forged bundle: issue opened" has "$fx/gh/issue-1.md" "push rejected"

# 16. The sync job crashes (an extra-files entry sync.sh cannot handle): an issue, nothing pushed.
make_fixture s16; fx="$ROOT/s16"
json_set "$fx/upstream/.github/release-please-config.json" '.packages["."]["extra-files"] += ["README.md"]'
upstream_commit "$fx" "add an unsupported extra-files entry"
before="$(fork_tip "$fx")"
cycle "$fx" run
check "16 sync job failed: job failed" eq "$SYNC_JOB" failure
check "16 sync job failed: checks and push skipped" eq "$CHECKS_JOB/$PUSH_RESULT" skipped/skipped
check "16 sync job failed: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "16 sync job failed: issue opened" has "$fx/gh/issue-1.md" "sync job failure"

# 17. The checks job crashes without an outcome: an issue, nothing pushed.
make_fixture s17; fx="$ROOT/s17"
echo one > "$fx/upstream/new1.txt"; upstream_commit "$fx" "upstream one"
before="$(fork_tip "$fx")"
CHECKS='kill -9 $PPID' cycle "$fx" run
check "17 checks job failed: job failed" eq "$CHECKS_JOB" failure
check "17 checks job failed: push skipped" eq "$PUSH_RESULT" skipped
check "17 checks job failed: fork unchanged" eq "$(fork_tip "$fx")" "$before"
check "17 checks job failed: issue opened" has "$fx/gh/issue-1.md" "checks job failure"

if [ "$FAILS" -gt 0 ]; then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "all checks passed"
