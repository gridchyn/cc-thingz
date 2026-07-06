#!/bin/bash
# detect the VCS of a repository
# outputs "git" or "hg" on stdout; exits 1 if neither
# precedence: git first, hg second; if both colocated, git wins
#
# operates on the current working directory by default. pass --repo <dir> to
# probe a specific directory instead (used by multi-repo exec); bare invocation
# is unchanged.

set -e

# --- multi-repo: optional --repo <dir> target (bare call is unchanged) ---
repo=""
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
    *)
        echo "error: unexpected argument: $1" >&2
        exit 1
        ;;
    esac
done

if [ -n "$repo" ]; then
    [ -d "$repo" ] || {
        echo "error: repo directory not found: $repo" >&2
        exit 1
    }
    cd "$repo"
fi
# --- end multi-repo ---

# git detection. With --repo (multi-repo targeting) the directory must be the git
# TOP-LEVEL, not a nested subdir: `git rev-parse --git-dir` walks up, so a plain
# subdir of an enclosing repo would otherwise resolve to that repo. The bare call
# (single-repo) keeps the walk-up behavior so it works from any subdir, unchanged.
git_ok() {
    if [ -n "$repo" ]; then
        local top here
        top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
        [ -n "$top" ] || return 1
        top="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
        here="$(pwd -P)"
        [ "$top" = "$here" ]
    else
        git rev-parse --git-dir >/dev/null 2>&1
    fi
}

if git_ok; then
    echo "git"
elif command -v hg >/dev/null 2>&1 && hg root >/dev/null 2>&1; then
    echo "hg"
else
    echo "error: not a git or mercurial repository" >&2
    exit 1
fi
