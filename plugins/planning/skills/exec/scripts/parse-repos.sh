#!/bin/bash
# parse the multi-repo manifest from a plan file's "## Repos" section
# usage: parse-repos.sh <plan-file-path>
#
# emits one TSV row per declared repo: <dir><TAB><base><TAB><branch>
#   dir    - repo directory, relative to the workspace root (as written in the plan)
#   base   - explicit base-branch override, or empty (caller detects per repo)
#   branch - resolved feature branch: per-repo override -> plan default `Branch:`
#            -> derived from the plan filename (same rule as create-branch.sh)
#
# exit codes:
#   0  multi-repo: "## Repos" present, one or more rows emitted on stdout
#   3  single-repo: no "## Repos" section and no task-level **Repo:** field
#   4  malformed: "## Repos" empty, or tasks use **Repo:** without a "## Repos"
#      section (message on stderr, no rows)
#
# grammar of the ## Repos section (see commands/make.md):
#   ## Repos
#
#   Branch: `feature/DPB-6042`
#
#   - `pgw-config-service`
#   - `pgw-core-service` — base: `develop`
#   - `pgw-workflow-service` — branch: `feature/DPB-6042-wf`
#
# the separator before overrides is lenient (any dash/em-dash); base:/branch:
# values may be backtick-quoted or bare, in any order, comma-separated.

set -e

plan="${1:-}"
if [ -z "$plan" ]; then
    echo "error: usage: parse-repos.sh <plan-file-path>" >&2
    exit 1
fi
if [ ! -f "$plan" ]; then
    echo "error: plan file not found: $plan" >&2
    exit 1
fi

# derive branch name from plan file path — keep in sync with create-branch.sh
derive_branch_name() {
    local name
    name=$(basename "$1" .md)
    # shellcheck disable=SC2001 # regex too complex for ${var//pattern}
    name=$(echo "$name" | sed 's/^[0-9]\{4\}-\{0,1\}[0-9]\{2\}-\{0,1\}[0-9]\{2\}-//')
    echo "$name"
}

# extract a "key: value" field from a bullet line; value may be backtick-quoted
# or bare, and is terminated by a comma (next field) or end of line
extract_field() {
    local line="$1" key="$2" val
    case "$line" in
    *"$key:"*)
        val="${line#*"$key:"}" # text after "key:"
        val="${val%%,*}"       # stop at the next comma-separated field
        # strip backticks and surrounding whitespace
        val="$(printf '%s' "$val" | tr -d '`' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        printf '%s' "$val"
        ;;
    esac
}

seen_repos=0
in_repos=0
default_branch=""
dirs=()
bases=()
branches=()

while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_repos" -eq 0 ]; then
        case "$line" in
        "## Repos" | "## Repos "*)
            in_repos=1
            seen_repos=1
            ;;
        esac
        continue
    fi

    # once inside the section, the next ATX header of any level ends it
    if [[ "$line" =~ ^#+[[:space:]] ]]; then
        in_repos=0
        continue
    fi

    # plan-level default feature branch (a non-bullet "Branch:" line)
    if [[ "$line" =~ ^[Bb]ranch: ]]; then
        default_branch="${line#*:}"
        default_branch="$(printf '%s' "$default_branch" | tr -d '`' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        continue
    fi

    # a repo bullet
    if [[ "$line" =~ ^-[[:space:]] ]]; then
        local_dir="$(printf '%s' "$line" | sed -n 's/^-[[:space:]]*`\([^`]*\)`.*/\1/p')"
        if [ -z "$local_dir" ]; then
            # no backticks around the dir — take the first whitespace-delimited token
            local_dir="$(printf '%s' "$line" | sed -n 's/^-[[:space:]]*\([^[:space:]]*\).*/\1/p')"
        fi
        [ -z "$local_dir" ] && continue
        local_base="$(extract_field "$line" "base")"
        local_branch="$(extract_field "$line" "branch")"
        dirs+=("$local_dir")
        bases+=("$local_base")
        branches+=("$local_branch")
        continue
    fi
done <"$plan"

# no ## Repos section at all
if [ "$seen_repos" -eq 0 ]; then
    if grep -q '\*\*Repo:\*\*' "$plan" 2>/dev/null; then
        echo "error: tasks declare **Repo:** but the plan has no '## Repos' section" >&2
        exit 4
    fi
    exit 3
fi

# ## Repos present but empty
if [ "${#dirs[@]}" -eq 0 ]; then
    echo "error: '## Repos' section present but lists no repos" >&2
    exit 4
fi

i=0
while [ "$i" -lt "${#dirs[@]}" ]; do
    branch="${branches[$i]}"
    [ -z "$branch" ] && branch="$default_branch"
    [ -z "$branch" ] && branch="$(derive_branch_name "$plan")"
    printf '%s\t%s\t%s\n' "${dirs[$i]}" "${bases[$i]}" "$branch"
    i=$((i + 1))
done
