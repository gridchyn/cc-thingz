#!/bin/bash
# read-only pre-flight validation of every target repo before multi-repo branching
# usage: preflight-repos.sh <spec> [<spec> ...]
#   spec = <dir>            (validate existence + git + clean tree)
#        = <dir>=<branch>   (also compare the current branch to the target)
#
# this NEVER mutates a repo — it only inspects, so the orchestrator can validate
# the whole set up front and refuse to branch any repo if some repo would fail.
# that is what prevents a half-branched set.
#
# per-repo verdict on stdout, one line each:
#   OK: <dir>[ (on target|will create <branch>|will switch to <branch>)]
#   WARN: <dir> — <reason>     (non-fatal, e.g. on a different feature branch)
#   FAIL: <dir> — <reason>     (missing dir, not git, hg, or dirty tree)
#
# exit code: 0 if no FAIL, 1 if any repo FAILs (WARN alone keeps exit 0).
# multi-repo mode is git-only; a Mercurial target is reported as FAIL with a
# clear message (single-repo hg is unaffected — it never calls this script).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# optional --root <dir> [--plan <path>] performs an advisory check of the
# workspace-root repo (which holds the coordinating plan and never gets a code
# branch); the rest are <dir[=branch]> repo specs.
root=""
plan=""
specs=()
while [ $# -gt 0 ]; do
    case "$1" in
    --root)
        root="${2:-}"
        [ -z "$root" ] && {
            echo "error: --root requires a directory argument" >&2
            exit 1
        }
        shift 2
        ;;
    --plan)
        plan="${2:-}"
        [ -z "$plan" ] && {
            echo "error: --plan requires a path argument" >&2
            exit 1
        }
        shift 2
        ;;
    --*)
        echo "error: unknown flag: $1" >&2
        exit 1
        ;;
    *)
        specs+=("$1")
        shift
        ;;
    esac
done

if [ "${#specs[@]}" -lt 1 ] && [ -z "$root" ]; then
    echo "error: usage: preflight-repos.sh [--root <dir> [--plan <path>]] <dir[=branch]> [<dir[=branch]> ...]" >&2
    exit 1
fi

fail=0

# advisory workspace-root check: the root repo holds the plan and is never
# branched. Warn (never fail) if it has uncommitted changes besides the plan
# itself, since the plan-archive commit only includes the plan.
if [ -n "$root" ]; then
    if [ ! -d "$root" ]; then
        echo "FAIL: $root — workspace root directory not found"
        fail=1
    elif ! bash "$SCRIPT_DIR/detect-vcs.sh" --repo "$root" >/dev/null 2>&1; then
        echo "WARN: $root — workspace root is not a git repository root (the plan cannot be archived/committed there)"
    else
        plan_rel=""
        if [ -n "$plan" ] && [ -e "$plan" ]; then
            plan_abs="$(cd "$(dirname "$plan")" 2>/dev/null && pwd -P)/$(basename "$plan")"
            root_abs="$(cd "$root" 2>/dev/null && pwd -P)"
            case "$plan_abs" in
            "$root_abs"/*) plan_rel="${plan_abs#"$root_abs"/}" ;;
            esac
        fi
        # --untracked-files=all lists untracked files individually instead of
        # collapsing a fully-untracked parent dir (e.g. `docs/`), so the plan can
        # be excluded by its exact path
        changed="$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null | sed 's/^...//')"
        remaining=0
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            [ -n "$plan_rel" ] && [ "$p" = "$plan_rel" ] && continue
            remaining=$((remaining + 1))
        done <<EOF
$changed
EOF
        if [ "$remaining" -gt 0 ]; then
            echo "WARN: $root — workspace root has $remaining uncommitted change(s) besides the plan; the archive commit will include only the plan"
        else
            echo "OK: root $root"
        fi
    fi
fi

for spec in "${specs[@]}"; do
    dir="${spec%%=*}"
    branch=""
    case "$spec" in
    *=*) branch="${spec#*=}" ;;
    esac

    if [ -z "$dir" ]; then
        echo "FAIL: (empty) — no directory in spec '$spec'"
        fail=1
        continue
    fi

    if [ ! -d "$dir" ]; then
        echo "FAIL: $dir — directory not found"
        fail=1
        continue
    fi

    # VCS check (git-only for multi-repo). detect-vcs.sh exits non-zero on a
    # non-repo dir; capture that without tripping set -e.
    vcs=""
    if ! vcs="$(bash "$SCRIPT_DIR/detect-vcs.sh" --repo "$dir" 2>/dev/null)"; then
        echo "FAIL: $dir — not a git repository root (missing, or a subdir of an enclosing repo)"
        fail=1
        continue
    fi
    if [ "$vcs" != "git" ]; then
        echo "FAIL: $dir — multi-repo mode is git-only (detected: $vcs)"
        fail=1
        continue
    fi

    current="$(git -C "$dir" branch --show-current 2>/dev/null || true)"

    # no target branch given: existence + git is enough
    if [ -z "$branch" ]; then
        echo "OK: $dir"
        continue
    fi

    # already on the target branch — clean or dirty, this is a safe no-op/resume
    if [ "$current" = "$branch" ]; then
        echo "OK: $dir (on target $branch)"
        continue
    fi

    # a switch/create is required — refuse over a dirty working tree
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
        echo "FAIL: $dir — dirty working tree (commit or stash before running)"
        fail=1
        continue
    fi

    default_branch="$(bash "$SCRIPT_DIR/detect-branch.sh" --repo "$dir" 2>/dev/null || true)"

    if [ -n "$current" ] && [ -n "$default_branch" ] && [ "$current" != "$default_branch" ]; then
        echo "WARN: $dir — on feature branch '$current', will switch to '$branch'"
        continue
    fi

    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
        echo "OK: $dir (will switch to existing $branch)"
    else
        echo "OK: $dir (will create $branch)"
    fi
done

if [ "$fail" -ne 0 ]; then
    exit 1
fi
