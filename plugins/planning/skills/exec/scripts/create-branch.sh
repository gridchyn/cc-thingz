#!/bin/bash
# create a feature branch from plan file name if on the default branch
# usage: create-branch.sh [--repo <dir>] [--branch <name>] <plan-file-path>
# exits 0 if branch created or already on feature branch
# outputs branch name to stdout
#
# strips leading YYYYMMDD- date prefix from branch name since plan files
# use date prefixes (e.g., 20260329-feature-name.md) but branch names should not
# VCS-aware: dispatches to git or hg based on detect-vcs.sh
#
# multi-repo exec passes --repo <dir> to operate on a sibling repo and --branch
# <name> to force an explicit target branch (from the plan's ## Repos block).
# With --branch (explicit-target mode) the repo is put on exactly that branch:
# no-op if already there, refuse on a dirty tree when a switch is required, and
# warn (non-fatal) when leaving a different feature branch. Without any flags the
# behavior is unchanged from the single-repo original.

set -e

# SCRIPT_DIR must be resolved before any cd so a relative $0 still works
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- multi-repo: optional --repo <dir> / --branch <name> flags ---
repo=""
branch_override=""
while [ $# -gt 0 ]; do
    case "$1" in
    --repo)
        repo="${2:-}"
        [ -z "$repo" ] && {
            echo "error: --repo requires a directory argument" >&2
            exit 1
        }
        shift 2
        ;;
    --branch)
        branch_override="${2:-}"
        [ -z "$branch_override" ] && {
            echo "error: --branch requires a name argument" >&2
            exit 1
        }
        shift 2
        ;;
    --*)
        echo "error: unknown flag: $1" >&2
        exit 1
        ;;
    *)
        break
        ;;
    esac
done
# --- end multi-repo flags ---

if [ -z "${1:-}" ]; then
    echo "error: plan file path required" >&2
    exit 1
fi
plan_file="$1"

if [ -n "$repo" ]; then
    [ -d "$repo" ] || {
        echo "error: repo directory not found: $repo" >&2
        exit 1
    }
    cd "$repo"
fi

vcs=$(bash "$SCRIPT_DIR/detect-vcs.sh")

# derive branch name from plan file path (shared by git and hg paths)
# e.g., docs/plans/20260329-feature-name.md -> feature-name
derive_branch_name() {
    local name
    name=$(basename "$1" .md)
    # strip leading date prefix if present (YYYYMMDD- or YYYY-MM-DD-)
    # shellcheck disable=SC2001 # regex too complex for ${var//pattern}
    name=$(echo "$name" | sed 's/^[0-9]\{4\}-\{0,1\}[0-9]\{2\}-\{0,1\}[0-9]\{2\}-//')
    echo "$name"
}

# resolve the target branch: explicit --branch wins, else derive from the plan.
# "explicit" also selects the multi-repo explicit-target code path below.
explicit=""
if [ -n "$branch_override" ]; then
    target_branch="$branch_override"
    explicit=1
else
    target_branch=$(derive_branch_name "$plan_file")
fi

# detect the default branch using a local-first fallback chain (shared shape with
# detect-branch.sh do_git; avoids network calls that can hang)
git_default_branch() {
    local default_branch
    # 1. check cached remote HEAD (local, fast)
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [ -z "$default_branch" ]; then
        # 2. check for common default branch names locally
        for candidate in main master trunk develop; do
            if git show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; then
                default_branch="$candidate"
                break
            fi
        done
    fi
    if [ -z "$default_branch" ]; then
        # 3. last resort: ask remote (may block if network is unreachable)
        default_branch=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | sed 's/.*: //')
    fi
    echo "$default_branch"
}

do_git() {
    local target="$1"
    local current default_branch
    current=$(git branch --show-current)
    default_branch=$(git_default_branch)

    if [ -n "$explicit" ]; then
        # multi-repo explicit-target: put the repo on exactly $target
        if [ "$current" = "$target" ]; then
            echo "$target"
            return 0
        fi
        # refuse to switch/create over a dirty working tree (would risk the tree)
        if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            echo "error: refusing to switch branch with a dirty working tree in $(pwd)" >&2
            exit 1
        fi
        # warn (non-fatal) when leaving a different feature branch
        if [ -n "$current" ] && [ -n "$default_branch" ] && [ "$current" != "$default_branch" ]; then
            echo "warning: $(pwd) was on feature branch '$current', switching to '$target'" >&2
        fi
        if git show-ref --verify --quiet "refs/heads/$target" 2>/dev/null; then
            git checkout "$target" >/dev/null 2>&1
        else
            git checkout -b "$target" >/dev/null 2>&1
        fi
        echo "$target"
        return 0
    fi

    # single-repo (legacy) behavior — unchanged: keep an existing feature branch,
    # otherwise create/switch the derived branch off the default
    if [ -n "$current" ] && [ -n "$default_branch" ] && [ "$current" != "$default_branch" ]; then
        echo "$current"
        return 0
    elif [ -n "$current" ] && [ -z "$default_branch" ] && [ "$current" != "main" ] && [ "$current" != "master" ]; then
        # no default branch detected, fall back to main/master check
        echo "$current"
        return 0
    fi

    # check if branch already exists
    if git show-ref --verify --quiet "refs/heads/$target" 2>/dev/null; then
        git checkout "$target"
    else
        git checkout -b "$target"
    fi

    echo "$target"
}

do_hg() {
    local target="$1"
    # current active bookmark — modern-Mercurial equivalent of "current branch".
    # empty when no bookmark is active — matches do_git "on default branch" case.
    # uses bookmarks (not named branches) because Mercurial-compatible forks have
    # dropped the named-branch subcommands in favour of bookmarks; upstream
    # Mercurial still ships them but recommends bookmark-based workflows.
    # bookmark primitives keep this script portable across the full ecosystem.
    local current
    current=$(hg log -r . --template '{activebookmark}\n')

    # resolve the default branch so an active default bookmark (e.g. master / main
    # when the default is exposed as remote/master) is not mistaken for a feature
    # branch. detect-branch.sh returns `remote/<name>` in repos with remote-tracking
    # refs; strip the prefix since local bookmarks use the bare name.
    local default_branch
    default_branch=$(bash "$SCRIPT_DIR/detect-branch.sh" 2>/dev/null || true)
    default_branch=${default_branch#remote/}

    if [ -n "$explicit" ]; then
        # multi-repo explicit-target (git-only in practice; preflight blocks hg,
        # but keep the path coherent): put the repo on exactly $target
        if [ "$current" = "$target" ]; then
            echo "$target"
            return 0
        fi
        if [ -n "$(hg status 2>/dev/null)" ]; then
            echo "error: refusing to switch bookmark with a dirty working tree in $(pwd)" >&2
            exit 1
        fi
        if [ -n "$current" ] && [ -n "$default_branch" ] && [ "$current" != "$default_branch" ]; then
            echo "warning: $(pwd) was on bookmark '$current', switching to '$target'" >&2
        fi
        if hg book --template '{bookmark}\n' 2>/dev/null | grep -qxF "$target"; then
            hg update "$target" >/dev/null
        else
            hg book "$target" >/dev/null
        fi
        echo "$target"
        return 0
    fi

    # single-repo (legacy) behavior — unchanged
    if [ -n "$current" ] && [ -n "$default_branch" ] && [ "$current" != "$default_branch" ]; then
        echo "$current"
        return 0
    elif [ -n "$current" ] && [ -z "$default_branch" ] && [ "$current" != "main" ] && [ "$current" != "master" ]; then
        # no default detected — fall back to the main/master heuristic
        echo "$current"
        return 0
    fi

    # partial-run recovery: switch to existing bookmark, else create one on current commit.
    # hg book --template lists local bookmark names — fast, no network, works on both dialects.
    if hg book --template '{bookmark}\n' 2>/dev/null | grep -qxF "$target"; then
        hg update "$target" >/dev/null
    else
        hg book "$target" >/dev/null
    fi

    echo "$target"
}

case "$vcs" in
git) do_git "$target_branch" ;;
hg) do_hg "$target_branch" ;;
*)
    echo "error: unsupported VCS: $vcs" >&2
    exit 1
    ;;
esac
