#!/bin/bash
# print the number of commits on HEAD not reachable from <since-ref>, in <repo>.
# usage: commits-since.sh <repo> <since-ref>
#
# used for touched-repo detection in multi-repo exec: record a repo's HEAD right
# AFTER branch setup as <since-ref>, then a non-zero count means this run added
# commits to that repo. Diffing against the base branch instead would miscount a
# repo that was already on a feature branch with pre-existing commits ahead of base.
# prints 0 (never fails) when the ref is unknown.

set -e

repo="${1:-}"
since="${2:-}"
if [ -z "$repo" ] || [ -z "$since" ]; then
    echo "error: usage: commits-since.sh <repo> <since-ref>" >&2
    exit 1
fi

git -C "$repo" rev-list --count "$since..HEAD" 2>/dev/null || echo 0
