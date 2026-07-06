#!/bin/bash
# resolve the branch to rebase onto for <base> in <repo>, after a best-effort,
# hang-safe fetch. usage: finalize-base.sh <repo> <base>
#
# prints `origin/<base>` when that remote-tracking ref resolves, otherwise the
# local `<base>` — so finalize works on a repo whose default (e.g. develop) has no
# origin/HEAD and no pushed remote branch. Never fails; never blocks the finalize:
# the fetch runs only under a timeout tool (skipped entirely if none exists) and
# is always best-effort.

repo="${1:-}"
base="${2:-}"
if [ -z "$repo" ] || [ -z "$base" ]; then
    echo "error: usage: finalize-base.sh <repo> <base>" >&2
    exit 1
fi

# best-effort refresh of the base only, bounded so an unreachable remote cannot
# hang the finalize. If no timeout tool is available, skip the fetch rather than
# risk blocking — the target is still resolved from whatever refs exist locally.
if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 git -C "$repo" fetch origin "$base" >/dev/null 2>&1 || true
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 20 git -C "$repo" fetch origin "$base" >/dev/null 2>&1 || true
    fi
fi

if git -C "$repo" rev-parse --verify --quiet "origin/$base" >/dev/null 2>&1; then
    echo "origin/$base"
else
    echo "$base"
fi
