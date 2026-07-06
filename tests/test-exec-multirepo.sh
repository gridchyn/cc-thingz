#!/bin/bash
# automated tests for the multi-repo exec additions:
#   parse-repos.sh          - parse the ## Repos manifest / detect mode
#   preflight-repos.sh      - read-only atomic validation of target repos
#   create-branch.sh --repo/--branch  - explicit-target branching in a sibling repo
#   detect-vcs.sh / detect-branch.sh --repo  - target a specific directory
#   run-codex.sh --repo     - review a sibling repo
# scaffolds temp git (and hg) repos and asserts expected outputs / exit codes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
EXEC_SCRIPTS_DIR="$REPO_ROOT/plugins/planning/skills/exec/scripts"
PARSE_REPOS="$EXEC_SCRIPTS_DIR/parse-repos.sh"
PREFLIGHT="$EXEC_SCRIPTS_DIR/preflight-repos.sh"
CREATE_BRANCH="$EXEC_SCRIPTS_DIR/create-branch.sh"
DETECT_VCS="$EXEC_SCRIPTS_DIR/detect-vcs.sh"
DETECT_BRANCH="$EXEC_SCRIPTS_DIR/detect-branch.sh"
RUN_CODEX="$EXEC_SCRIPTS_DIR/run-codex.sh"

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
        if [ -n "$d" ] && [ -d "$d" ]; then
            rm -rf "$d"
        fi
    done
    return 0
}
trap cleanup EXIT

assert_output() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
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
    local test_name="$1"
    local haystack="$2"
    local needle="$3"
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

assert_not_contains() {
    local test_name="$1"
    local haystack="$2"
    local needle="$3"
    case "$haystack" in
    *"$needle"*)
        echo "  FAIL: $test_name"
        echo "    unexpected substring: $(printf '%q' "$needle")"
        failed=$((failed + 1))
        ;;
    *)
        echo "  PASS: $test_name"
        passed=$((passed + 1))
        ;;
    esac
}

assert_exit() {
    local test_name="$1"
    local expected_rc="$2"
    local actual_rc="$3"
    if [ "$expected_rc" = "$actual_rc" ]; then
        echo "  PASS: $test_name"
        passed=$((passed + 1))
    else
        echo "  FAIL: $test_name (expected exit $expected_rc, got $actual_rc)"
        failed=$((failed + 1))
    fi
}

HG_AVAILABLE=1
if ! command -v hg >/dev/null 2>&1; then
    HG_AVAILABLE=0
    echo "note: hg not available, skipping hg-specific cases"
fi

# hermetic git/hg
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="Test"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test"
export GIT_COMMITTER_EMAIL="test@example.com"
export HGRCPATH=/dev/null
export HGUSER="Test <test@example.com>"

make_git_repo() {
    local dir="$1"
    local default_branch="$2"
    git -C "$dir" init -q -b "$default_branch"
    git -C "$dir" commit --allow-empty -q -m "initial"
    git -C "$dir" remote add origin "https://example.invalid/x.git"
    git -C "$dir" symbolic-ref "refs/remotes/origin/HEAD" "refs/remotes/origin/$default_branch"
}

make_hg_repo() {
    local dir="$1"
    hg init "$dir" >/dev/null
}

TAB="$(printf '\t')"

echo "testing parse-repos.sh"
echo "======================"

# test 1: single-repo plan (no ## Repos, no **Repo:**) -> exit 3, no output
echo ""
echo "test 1: single-repo plan -> exit 3"
PLAN_SINGLE="$(mk_tmp)/20260703-single.md"
cat >"$PLAN_SINGLE" <<'MD'
# Single Repo Plan

## Overview
Just one repo.

## Implementation Steps

### Task 1: do a thing

**Files:**
- Modify: `src/x`

- [ ] do it
MD
rc=0
out="$(bash "$PARSE_REPOS" "$PLAN_SINGLE")" || rc=$?
assert_exit "single-repo plan exits 3" "3" "$rc"
assert_output "single-repo plan emits nothing" "" "$out"

# test 2: full multi-repo manifest -> TSV rows, exit 0
echo ""
echo "test 2: multi-repo manifest -> resolved TSV rows"
PLAN_MULTI="$(mk_tmp)/20260703-cross.md"
cat >"$PLAN_MULTI" <<'MD'
# Cross Repo Plan

## Overview
Spans repos.

## Repos

Branch: `feature/DPB-6042`

- `pgw-config-service`
- `pgw-core-service` — base: `develop`
- `pgw-workflow-service` — branch: `feature/DPB-6042-wf`

## Implementation Steps

### Task 1: migration

**Repo:** pgw-config-service

- [ ] add changeset
MD
rc=0
out="$(bash "$PARSE_REPOS" "$PLAN_MULTI")" || rc=$?
assert_exit "multi-repo plan exits 0" "0" "$rc"
expected="$(printf 'pgw-config-service\t\tfeature/DPB-6042\npgw-core-service\tdevelop\tfeature/DPB-6042\npgw-workflow-service\t\tfeature/DPB-6042-wf')"
assert_output "multi-repo TSV resolves default/overrides" "$expected" "$out"

# test 3: no default Branch line -> branch derived from filename
echo ""
echo "test 3: no default Branch -> derive branch from plan filename"
PLAN_DERIVE="$(mk_tmp)/20260703-my-cross-change.md"
cat >"$PLAN_DERIVE" <<'MD'
# Derive

## Repos

- `repo-a`
- `repo-b` — base: `main`

## Implementation Steps

### Task 1: x

**Repo:** repo-a

- [ ] x
MD
out="$(bash "$PARSE_REPOS" "$PLAN_DERIVE")"
expected="$(printf 'repo-a\t\tmy-cross-change\nrepo-b\tmain\tmy-cross-change')"
assert_output "branch derived from filename when no default" "$expected" "$out"

# test 4: **Repo:** used but no ## Repos section -> malformed, exit 4
echo ""
echo "test 4: **Repo:** without ## Repos -> exit 4"
PLAN_BAD="$(mk_tmp)/20260703-bad.md"
cat >"$PLAN_BAD" <<'MD'
# Bad

## Implementation Steps

### Task 1: x

**Repo:** repo-a

- [ ] x
MD
rc=0
err="$(bash "$PARSE_REPOS" "$PLAN_BAD" 2>&1 1>/dev/null)" || rc=$?
assert_exit "malformed plan exits 4" "4" "$rc"
assert_contains "malformed plan explains why" "$err" "no '## Repos' section"

# test 5: empty ## Repos section -> exit 4
echo ""
echo "test 5: empty ## Repos section -> exit 4"
PLAN_EMPTY="$(mk_tmp)/20260703-empty.md"
cat >"$PLAN_EMPTY" <<'MD'
# Empty

## Repos

## Implementation Steps

### Task 1: x

**Repo:** repo-a

- [ ] x
MD
rc=0
bash "$PARSE_REPOS" "$PLAN_EMPTY" >/dev/null 2>&1 || rc=$?
assert_exit "empty ## Repos exits 4" "4" "$rc"

echo ""
echo "testing detect-vcs.sh / detect-branch.sh --repo"
echo "==============================================="

# test 6: detect-vcs.sh --repo on a git dir
echo ""
echo "test 6: detect-vcs.sh --repo <git> -> git"
GVCS="$(mk_tmp)"
make_git_repo "$GVCS" master
out="$(bash "$DETECT_VCS" --repo "$GVCS")"
assert_output "detect-vcs --repo reports git" "git" "$out"

# test 7: detect-vcs.sh --repo on a missing dir -> exit 1
echo ""
echo "test 7: detect-vcs.sh --repo <missing> -> exit 1"
rc=0
bash "$DETECT_VCS" --repo "/no/such/dir/xyzzy" >/dev/null 2>&1 || rc=$?
assert_exit "detect-vcs --repo missing dir exits 1" "1" "$rc"

# test 7b: detect-vcs.sh --repo with no value -> exit 1
echo ""
echo "test 7b: detect-vcs.sh --repo with no value -> exit 1"
rc=0
bash "$DETECT_VCS" --repo >/dev/null 2>&1 || rc=$?
assert_exit "detect-vcs --repo with no arg exits 1" "1" "$rc"

# test 8: detect-branch.sh --repo <git on master> -> master (run from elsewhere)
echo ""
echo "test 8: detect-branch.sh --repo <git> from an unrelated cwd -> master"
OTHER_CWD="$(mk_tmp)"
out="$(cd "$OTHER_CWD" && bash "$DETECT_BRANCH" --repo "$GVCS")"
assert_output "detect-branch --repo reports the target's default" "master" "$out"

echo ""
echo "testing create-branch.sh --repo/--branch"
echo "========================================"

# test 9: on default -> creates the explicit target branch in the target repo
echo ""
echo "test 9: --repo/--branch on default -> creates target branch"
CB1="$(mk_tmp)"
make_git_repo "$CB1" master
out="$(bash "$CREATE_BRANCH" --repo "$CB1" --branch "feature/DPB-1" "docs/plans/20260703-x.md" 2>/dev/null | tail -n 1)"
assert_output "outputs the explicit target branch" "feature/DPB-1" "$out"
cur="$(git -C "$CB1" branch --show-current)"
assert_output "target repo switched to the target branch" "feature/DPB-1" "$cur"

# test 10: already on target -> no-op, outputs target
echo ""
echo "test 10: already on target -> no-op"
out="$(bash "$CREATE_BRANCH" --repo "$CB1" --branch "feature/DPB-1" "docs/plans/20260703-x.md" 2>/dev/null | tail -n 1)"
assert_output "no-op when already on target" "feature/DPB-1" "$out"
cur="$(git -C "$CB1" branch --show-current)"
assert_output "still on target after no-op" "feature/DPB-1" "$cur"

# test 11: existing target branch, currently on default -> switches to it
echo ""
echo "test 11: existing target branch -> switch to it"
CB2="$(mk_tmp)"
make_git_repo "$CB2" master
git -C "$CB2" branch "feature/DPB-2"
out="$(bash "$CREATE_BRANCH" --repo "$CB2" --branch "feature/DPB-2" "docs/plans/20260703-x.md" 2>/dev/null | tail -n 1)"
assert_output "outputs existing target branch" "feature/DPB-2" "$out"
cur="$(git -C "$CB2" branch --show-current)"
assert_output "switched to existing target branch" "feature/DPB-2" "$cur"

# test 12: dirty tree + switch required -> refuse (exit 1), stay put
echo ""
echo "test 12: dirty tree requiring a switch -> refuse"
CB3="$(mk_tmp)"
make_git_repo "$CB3" master
echo "wip" >"$CB3/dirt.txt"
rc=0
bash "$CREATE_BRANCH" --repo "$CB3" --branch "feature/DPB-3" "docs/plans/20260703-x.md" >/dev/null 2>&1 || rc=$?
assert_exit "refuses to switch over a dirty tree" "1" "$rc"
cur="$(git -C "$CB3" branch --show-current)"
assert_output "stays on default after refusal" "master" "$cur"

# test 13: on a different feature branch, clean -> warns + switches
echo ""
echo "test 13: on a different feature branch -> warn + switch"
CB4="$(mk_tmp)"
make_git_repo "$CB4" master
git -C "$CB4" checkout -q -b "feature/OTHER"
err="$(bash "$CREATE_BRANCH" --repo "$CB4" --branch "feature/DPB-4" "docs/plans/20260703-x.md" 2>&1 1>/dev/null)"
assert_contains "warns about leaving a different feature branch" "$err" "warning"
cur="$(git -C "$CB4" branch --show-current)"
assert_output "switched to the target branch" "feature/DPB-4" "$cur"

# test 14: --repo missing dir -> exit 1
echo ""
echo "test 14: --repo <missing> -> exit 1"
rc=0
bash "$CREATE_BRANCH" --repo "/no/such/dir/xyzzy" --branch "feature/x" "docs/plans/20260703-x.md" >/dev/null 2>&1 || rc=$?
assert_exit "create-branch --repo missing dir exits 1" "1" "$rc"

# test 15: no flags -> unchanged single-repo behavior (derive + create in cwd)
echo ""
echo "test 15: no flags -> unchanged single-repo behavior"
CB5="$(mk_tmp)"
make_git_repo "$CB5" main
out="$(cd "$CB5" && bash "$CREATE_BRANCH" "docs/plans/20260329-feature-name.md" 2>/dev/null | tail -n 1)"
assert_output "no-flag derives branch from filename" "feature-name" "$out"
cur="$(git -C "$CB5" branch --show-current)"
assert_output "no-flag switched to derived branch in cwd" "feature-name" "$cur"

echo ""
echo "testing preflight-repos.sh"
echo "=========================="

# test 16: all repos clean on default -> all OK, exit 0
echo ""
echo "test 16: clean repos on default -> OK, exit 0"
PF_A="$(mk_tmp)"
PF_B="$(mk_tmp)"
make_git_repo "$PF_A" master
make_git_repo "$PF_B" main
rc=0
out="$(bash "$PREFLIGHT" "$PF_A=feature/X" "$PF_B=feature/X")" || rc=$?
assert_exit "clean set passes" "0" "$rc"
assert_contains "repo A reported OK" "$out" "OK: $PF_A"
assert_contains "repo B reported OK" "$out" "OK: $PF_B"

# test 17: already on target -> OK (on target)
echo ""
echo "test 17: already on target -> OK (on target)"
PF_ON="$(mk_tmp)"
make_git_repo "$PF_ON" master
git -C "$PF_ON" checkout -q -b "feature/X"
out="$(bash "$PREFLIGHT" "$PF_ON=feature/X")"
assert_contains "on-target reported OK (on target)" "$out" "on target feature/X"

# test 18: dirty tree needing a switch -> FAIL, exit 1
echo ""
echo "test 18: dirty tree needing a switch -> FAIL"
PF_DIRTY="$(mk_tmp)"
make_git_repo "$PF_DIRTY" master
echo "wip" >"$PF_DIRTY/dirt.txt"
rc=0
out="$(bash "$PREFLIGHT" "$PF_DIRTY=feature/X")" || rc=$?
assert_exit "dirty set fails" "1" "$rc"
assert_contains "dirty repo reported FAIL" "$out" "FAIL: $PF_DIRTY"
assert_contains "dirty reason explained" "$out" "dirty working tree"

# test 19: dirty tree but already on target -> OK (resume), exit 0
echo ""
echo "test 19: dirty but on target -> OK (resume)"
PF_DIRTY_ON="$(mk_tmp)"
make_git_repo "$PF_DIRTY_ON" master
git -C "$PF_DIRTY_ON" checkout -q -b "feature/X"
echo "wip" >"$PF_DIRTY_ON/dirt.txt"
rc=0
out="$(bash "$PREFLIGHT" "$PF_DIRTY_ON=feature/X")" || rc=$?
assert_exit "dirty-on-target passes (resume)" "0" "$rc"
assert_contains "dirty-on-target reported OK" "$out" "on target feature/X"

# test 20: missing dir -> FAIL, exit 1
echo ""
echo "test 20: missing dir -> FAIL"
rc=0
out="$(bash "$PREFLIGHT" "/no/such/dir/xyzzy=feature/X")" || rc=$?
assert_exit "missing dir fails" "1" "$rc"
assert_contains "missing dir reported FAIL" "$out" "directory not found"

# test 21: non-repo dir -> FAIL
echo ""
echo "test 21: non-repo dir -> FAIL"
PF_NOREPO="$(mk_tmp)"
rc=0
out="$(bash "$PREFLIGHT" "$PF_NOREPO=feature/X")" || rc=$?
assert_exit "non-repo dir fails" "1" "$rc"
assert_contains "non-repo reported FAIL" "$out" "not a git repository"

# test 22: on a different feature branch -> WARN, exit 0
echo ""
echo "test 22: on a different feature branch -> WARN (non-fatal)"
PF_WARN="$(mk_tmp)"
make_git_repo "$PF_WARN" master
git -C "$PF_WARN" checkout -q -b "feature/OTHER"
rc=0
out="$(bash "$PREFLIGHT" "$PF_WARN=feature/X")" || rc=$?
assert_exit "warn-only set still passes" "0" "$rc"
assert_contains "different-feature reported WARN" "$out" "WARN: $PF_WARN"

# test 23: one FAIL among OKs -> whole set fails (never half-branch)
echo ""
echo "test 23: mixed set with one FAIL -> exit 1"
rc=0
out="$(bash "$PREFLIGHT" "$PF_A=feature/X" "/no/such/dir/xyzzy=feature/X" "$PF_B=feature/X")" || rc=$?
assert_exit "mixed set fails atomically" "1" "$rc"
assert_contains "good repo still OK" "$out" "OK: $PF_A"
assert_contains "bad repo FAIL" "$out" "FAIL: /no/such/dir/xyzzy"

# test 24: hg repo target -> FAIL (multi-repo is git-only)
if [ "$HG_AVAILABLE" -eq 1 ]; then
    echo ""
    echo "test 24: hg repo target -> FAIL (git-only)"
    PF_HG="$(mk_tmp)"
    make_hg_repo "$PF_HG"
    rc=0
    out="$(bash "$PREFLIGHT" "$PF_HG=feature/X")" || rc=$?
    assert_exit "hg target fails" "1" "$rc"
    assert_contains "hg target reports git-only" "$out" "git-only"
fi

echo ""
echo "testing run-codex.sh --repo"
echo "==========================="

STUB_DIR="$(mk_tmp)"
cat >"$STUB_DIR/codex" <<'STUB'
#!/bin/bash
for arg in "$@"; do
    printf '%s\n' "$arg"
done
STUB
chmod +x "$STUB_DIR/codex"

# test 25: run-codex.sh --repo <git> from an unrelated cwd -> works
echo ""
echo "test 25: run-codex.sh --repo <git> passes prompt, no --skip-git-repo-check"
RC_GIT="$(mk_tmp)"
make_git_repo "$RC_GIT" master
RC_CWD="$(mk_tmp)"
out="$(cd "$RC_CWD" && PATH="$STUB_DIR:$PATH" bash "$RUN_CODEX" --repo "$RC_GIT" "review please")"
assert_contains "codex got the prompt" "$out" "review please"
assert_contains "codex exec present" "$out" "exec"
assert_not_contains "git repo: no --skip-git-repo-check" "$out" "--skip-git-repo-check"

# test 26: run-codex.sh --repo <missing> -> exit 1
echo ""
echo "test 26: run-codex.sh --repo <missing> -> exit 1"
rc=0
(PATH="$STUB_DIR:$PATH" bash "$RUN_CODEX" --repo "/no/such/dir/xyzzy" "prompt") >/dev/null 2>&1 || rc=$?
assert_exit "run-codex --repo missing dir exits 1" "1" "$rc"

# summary
echo ""
echo "========================"
echo "results: $passed passed, $failed failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
