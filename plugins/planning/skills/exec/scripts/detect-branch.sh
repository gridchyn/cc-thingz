#!/bin/bash
# detect the default branch name of a repository
# outputs the branch name to stdout
# avoids network calls when possible
# VCS-aware: dispatches to git or hg based on detect-vcs.sh
#
# operates on the current working directory by default. pass --repo <dir> to
# detect the default branch of a specific directory instead (used by multi-repo
# exec); bare invocation is unchanged.

set -e

# SCRIPT_DIR must be resolved before any cd so a relative $0 still works
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

vcs=$(bash "$SCRIPT_DIR/detect-vcs.sh")

do_git() {
    local branch
    # 1. check cached remote HEAD (local, fast)
    branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

    # 2. check for common default branch names locally
    if [ -z "$branch" ]; then
        for candidate in main master trunk develop; do
            if git show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; then
                branch="$candidate"
                break
            fi
        done
    fi

    # 3. last resort: ask remote (may block if network is unreachable)
    if [ -z "$branch" ]; then
        branch=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | sed 's/.*: //')
    fi

    # 4. fallback
    if [ -z "$branch" ]; then
        branch="main"
    fi

    echo "$branch"
}

do_hg() {
    # probe common default-branch remote-tracking refs first — modern Mercurial
    # workflows expose the upstream default as `remote/<name>` and jj uses the
    # same convention. present(remote/<name>) returns empty instead of aborting
    # when the revset is absent, so the loop is safe on repos that do not
    # expose remote-tracking refs this way
    local candidate
    for candidate in master main trunk; do
        if hg log -r "present(remote/$candidate)" --template '{node}\n' 2>/dev/null | grep -q .; then
            echo "remote/$candidate"
            return 0
        fi
    done

    # vanilla-hg fallback: the traditional named branch
    echo "default"
}

case "$vcs" in
git) do_git ;;
hg) do_hg ;;
*)
    echo "error: unsupported VCS: $vcs" >&2
    exit 1
    ;;
esac
