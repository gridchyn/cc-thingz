#!/bin/bash
# end-to-end scripted test of the multi-repo exec spine across TWO sibling repos
# with a cross-repo dependency (Task 1 in repoA, Task 2 in repoB depends on it).
#
# It drives the real scripts in the order SKILL.md's multi-repo mode drives them:
#   parse-repos -> detect-branch --repo (base) -> preflight-repos -> create-branch
#   --repo/--branch (per repo) -> [simulated task commits per repo] -> touched-repo
#   detection -> move-plan (root) -> per-repo commit counts.
# The LLM-orchestrated steps (task subagents, reviews) are simulated with plain
# git commits so the deterministic scaffolding can be asserted exactly.
#
# Layout mirrors the PGW workspace: a git "root" repo holds the coordinating plan
# (docs/plans/) and .gitignores the sibling repos; repoA and repoB are independent
# git repos checked out beside it with DIFFERENT default branches (master / main).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
S="$REPO_ROOT/plugins/planning/skills/exec/scripts"
PARSE_REPOS="$S/parse-repos.sh"
PREFLIGHT="$S/preflight-repos.sh"
CREATE_BRANCH="$S/create-branch.sh"
DETECT_BRANCH="$S/detect-branch.sh"
STAGE_AND_COMMIT="$S/stage-and-commit.sh"
MOVE_PLAN="$S/move-plan.sh"

passed=0
failed=0

assert_temp_dir() {
    local dir="$1"
    local tmpbase="${TMPDIR:-/tmp}"
    tmpbase="${tmpbase%/}"
    case "$dir" in
    "$tmpbase"/*) ;;
    /tmp/*) ;;
    /private/tmp/*) ;;
    /private/var/*) ;;
    /var/folders/*) ;;
    *)
        echo "FATAL: $dir is not under a recognised temp base, refusing to proceed" >&2
        exit 1
        ;;
    esac
}

TMP_DIRS=()
mk_tmp() {
    local d
    d="$(mktemp -d)"
    assert_temp_dir "$d"
    TMP_DIRS+=("$d")
    echo "$d"
}
cleanup() {
    local d
    for d in "${TMP_DIRS[@]:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
    return 0
}
trap cleanup EXIT

assert_output() {
    local test_name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $test_name"
        passed=$((passed + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected: $(printf '%q' "$expected")"
        echo "    actual:   $(printf '%q' "$actual")"
        failed=$((failed + 1))
    fi
}
assert_contains() {
    local test_name="$1" haystack="$2" needle="$3"
    case "$haystack" in
    *"$needle"*)
        echo "  PASS: $test_name"
        passed=$((passed + 1))
        ;;
    *)
        echo "  FAIL: $test_name"
        echo "    expected substring: $(printf '%q' "$needle")"
        echo "    in:                 $(printf '%q' "$haystack")"
        failed=$((failed + 1))
        ;;
    esac
}

# hermetic git
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"

make_git_repo() {
    local dir="$1" default_branch="$2"
    git -C "$dir" init -q -b "$default_branch"
    git -C "$dir" commit --allow-empty -q -m "initial"
    git -C "$dir" remote add origin "https://example.invalid/x.git"
    git -C "$dir" symbolic-ref "refs/remotes/origin/HEAD" "refs/remotes/origin/$default_branch"
}

echo "multi-repo exec end-to-end (two repos, cross-repo dependency)"
echo "============================================================"

# --- scaffold the workspace ---------------------------------------------------
WS="$(mk_tmp)" # workspace root = the coordinating (plan) repo
make_git_repo "$WS" master
mkdir -p "$WS/repoA" "$WS/repoB" "$WS/docs/plans"
make_git_repo "$WS/repoA" master
make_git_repo "$WS/repoB" main # deliberately different default branch
# root repo ignores the sibling repos, like the real PGW workspace
printf '/repoA/\n/repoB/\n' >"$WS/.gitignore"

PLAN="$WS/docs/plans/20260704-cross-coins.md"
cat >"$PLAN" <<'MD'
# Cross Repo Coins Migration

## Overview
Add a column in repoA, then read it in repoB.

## Repos

Branch: `feature/DPB-6042`

- `repoA`
- `repoB`

## Implementation Steps

### Task 1: add column in repoA

**Repo:** repoA

**Files:**
- Create: `schema.sql`

- [ ] add the amount column
- [ ] run tests

### Task 2: read the column in repoB (depends on Task 1)

**Repo:** repoB

**Files:**
- Create: `reader.txt`

- [ ] read the column repoA added
- [ ] run tests
MD
git -C "$WS" add docs/plans .gitignore
git -C "$WS" commit -q -m "add coordinating plan"

ROOT_BRANCH_BEFORE="$(git -C "$WS" branch --show-current)"
ROOT_COMMITS_BEFORE="$(git -C "$WS" rev-list --count HEAD)"

# --- step: parse the manifest -------------------------------------------------
echo ""
echo "step 1: parse-repos resolves the manifest"
manifest_out="$(bash "$PARSE_REPOS" "$PLAN")"
expected_manifest="$(printf 'repoA\t\tfeature/DPB-6042\nrepoB\t\tfeature/DPB-6042')"
assert_output "manifest rows resolve (empty base, default branch)" "$expected_manifest" "$manifest_out"

# --- step: resolve per-repo base branch --------------------------------------
echo ""
echo "step 2: detect base branch per repo"
baseA="$(cd "$WS" && bash "$DETECT_BRANCH" --repo repoA)"
baseB="$(cd "$WS" && bash "$DETECT_BRANCH" --repo repoB)"
assert_output "repoA base is master" "master" "$baseA"
assert_output "repoB base is main" "main" "$baseB"

# --- step: preflight all repos atomically ------------------------------------
echo ""
echo "step 3: preflight passes for a clean set"
rc=0
pf_out="$(cd "$WS" && bash "$PREFLIGHT" "repoA=feature/DPB-6042" "repoB=feature/DPB-6042")" || rc=$?
assert_output "preflight exit 0" "0" "$rc"
assert_contains "repoA OK" "$pf_out" "OK: repoA"
assert_contains "repoB OK" "$pf_out" "OK: repoB"

# --- step: create the feature branch in each repo ----------------------------
echo ""
echo "step 4: create-branch per repo"
outA="$(cd "$WS" && bash "$CREATE_BRANCH" --repo repoA --branch "feature/DPB-6042" "$PLAN" 2>/dev/null | tail -n 1)"
outB="$(cd "$WS" && bash "$CREATE_BRANCH" --repo repoB --branch "feature/DPB-6042" "$PLAN" 2>/dev/null | tail -n 1)"
assert_output "repoA branch created" "feature/DPB-6042" "$outA"
assert_output "repoB branch created" "feature/DPB-6042" "$outB"
assert_output "repoA is on the feature branch" "feature/DPB-6042" "$(git -C "$WS/repoA" branch --show-current)"
assert_output "repoB is on the feature branch" "feature/DPB-6042" "$(git -C "$WS/repoB" branch --show-current)"
assert_output "root repo NEVER branched (still on master)" "master" "$(git -C "$WS" branch --show-current)"

# --- step: simulate Task 1 in repoA (commit code there, flip plan checkbox) ---
echo ""
echo "step 5: task 1 in repoA — commit code in repoA, flip plan checkbox in root"
printf 'ALTER TABLE t ADD COLUMN amount BIGINT;\n' >"$WS/repoA/schema.sql"
(cd "$WS/repoA" && bash "$STAGE_AND_COMMIT" "feat: add amount column" schema.sql >/dev/null 2>&1)
# checkbox flips happen in the ROOT plan file (absolute path), not committed per-task.
# portable in-place flip (no GNU/BSD sed -i ambiguity): sed to a temp, then move back.
sed 's/- \[ \] add the amount column/- [x] add the amount column/' "$PLAN" >"$PLAN.tmp" && mv "$PLAN.tmp" "$PLAN"
assert_output "repoA committed schema.sql only" "schema.sql" "$(git -C "$WS/repoA" show --name-only --pretty=format: HEAD | sed '/^$/d')"

# --- step: simulate Task 2 in repoB (depends on repoA) -----------------------
echo ""
echo "step 6: task 2 in repoB (depends on task 1)"
printf 'reads amount column added by repoA\n' >"$WS/repoB/reader.txt"
(cd "$WS/repoB" && bash "$STAGE_AND_COMMIT" "feat: read amount column" reader.txt >/dev/null 2>&1)
assert_output "repoB committed reader.txt only" "reader.txt" "$(git -C "$WS/repoB" show --name-only --pretty=format: HEAD | sed '/^$/d')"
# the plan file must NOT have leaked into either sibling repo's commit
assert_output "plan not committed into repoA" "" "$(git -C "$WS/repoA" log --oneline -- '*coins*' 2>/dev/null)"
assert_output "plan not committed into repoB" "" "$(git -C "$WS/repoB" log --oneline -- '*coins*' 2>/dev/null)"

# --- step: touched-repo detection --------------------------------------------
echo ""
echo "step 7: touched-repo detection (commits on the feature branch vs base)"
touchedA="$(git -C "$WS/repoA" log --oneline "master..HEAD" | wc -l | tr -d ' ')"
touchedB="$(git -C "$WS/repoB" log --oneline "main..HEAD" | wc -l | tr -d ' ')"
assert_output "repoA has 1 commit on the feature branch" "1" "$touchedA"
assert_output "repoB has 1 commit on the feature branch" "1" "$touchedB"

# --- step: archive the coordinating plan in the ROOT repo only ----------------
echo ""
echo "step 8: move-plan archives the plan in the root repo, siblings untouched"
rc=0
mv_out="$(cd "$WS" && bash "$MOVE_PLAN" "docs/plans/20260704-cross-coins.md" 2>&1)" || rc=$?
assert_output "move-plan exit 0" "0" "$rc"
assert_contains "move-plan reports the move" "$mv_out" "moved plan to"
[ -f "$WS/docs/plans/completed/20260704-cross-coins.md" ] && archived="yes" || archived="no"
assert_output "plan archived under completed/ in root" "yes" "$archived"
[ -f "$WS/docs/plans/20260704-cross-coins.md" ] && orig="present" || orig="gone"
assert_output "original plan path removed" "gone" "$orig"
assert_contains "archived plan has the flipped checkbox" "$(cat "$WS/docs/plans/completed/20260704-cross-coins.md")" "- [x] add the amount column"
# the move is committed in the ROOT repo, not the siblings
assert_output "root got exactly one new commit for the move" "$((ROOT_COMMITS_BEFORE + 1))" "$(git -C "$WS" rev-list --count HEAD)"
assert_output "root still on its original branch (no code branch)" "$ROOT_BRANCH_BEFORE" "$(git -C "$WS" branch --show-current)"
assert_output "repoA unchanged by the archive (still 1 commit)" "1" "$(git -C "$WS/repoA" log --oneline master..HEAD | wc -l | tr -d ' ')"

# --- step: per-repo PR summary counts ----------------------------------------
echo ""
echo "step 9: per-repo summary (one PR per touched repo)"
assert_output "summary: repoA -> feature/DPB-6042, 1 commit" "feature/DPB-6042 1" \
    "$(git -C "$WS/repoA" branch --show-current) $(git -C "$WS/repoA" log --oneline master..HEAD | wc -l | tr -d ' ')"
assert_output "summary: repoB -> feature/DPB-6042, 1 commit" "feature/DPB-6042 1" \
    "$(git -C "$WS/repoB" branch --show-current) $(git -C "$WS/repoB" log --oneline main..HEAD | wc -l | tr -d ' ')"

# summary
echo ""
echo "========================"
echo "results: $passed passed, $failed failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
