#!/bin/bash
# run codex review and return output
# usage: run-codex.sh [--repo <dir>] "<prompt>"
# outputs codex response to stdout
# VCS-aware: in hg repos, adds --skip-git-repo-check so codex doesn't refuse
#
# multi-repo exec passes --repo <dir> so codex reviews a sibling repo (cwd = that
# repo, so the prompt's diff command and file reads are repo-local). Bare
# invocation (no --repo) reviews the current directory, unchanged.

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
    --*)
        echo "error: unknown flag: $1" >&2
        exit 1
        ;;
    *)
        break
        ;;
    esac
done
# --- end multi-repo ---

prompt="${1:-}"
if [ -z "$prompt" ]; then
    echo "error: usage: run-codex.sh [--repo <dir>] '<prompt>'" >&2
    exit 1
fi

if [ -n "$repo" ]; then
    [ -d "$repo" ] || {
        echo "error: repo directory not found: $repo" >&2
        exit 1
    }
    cd "$repo"
fi
# detect-vcs.sh exits non-zero on non-VCS dirs; set -e propagates so the
# script aborts before reaching codex with an unknown VCS value
vcs=$(bash "$SCRIPT_DIR/detect-vcs.sh")

# build args as an array so the hg-specific flag can be positioned right after
# 'exec' (before --sandbox) as an exec-level option
args=("exec")
[ "$vcs" = "hg" ] && args+=("--skip-git-repo-check")
args+=("--sandbox" "read-only")

# -c overrides switch provider routing in a way some corporate codex
# proxies / wrappers reject (e.g. "Error: Model provider 'responses' not
# found"). Set CODEX_NO_OVERRIDES=1 to skip the overrides and fall
# through to the proxy's defaults. Only the literal value `1` activates
# suppression -- any other value (including `0`, `false`, empty) keeps
# the overrides on, matching the documented "set to 1 to enable" semantic.
if [ "${CODEX_NO_OVERRIDES:-}" != 1 ]; then
    args+=(
        "-c" "model=${CODEX_MODEL:-gpt-5.5}"
        "-c" "model_reasoning_effort=xhigh"
        "-c" "stream_idle_timeout_ms=3600000"
    )
fi

# stdin redirected from /dev/null: codex exec reads stdin to append a
# <stdin> block even when a prompt arg is given, so an inherited open pipe
# (e.g. background launch) would block read_to_end forever. /dev/null gives
# immediate EOF; empty stdin is ignored when a prompt arg is present.
codex "${args[@]}" "$prompt" < /dev/null
