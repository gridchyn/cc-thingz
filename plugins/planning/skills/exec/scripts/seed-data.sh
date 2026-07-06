#!/bin/bash
# seed the exec prompt/agent files into the plugin data dir, version-aware.
# usage: seed-data.sh <data-dir> <plugin-root>
#   (both fall back to $CLAUDE_PLUGIN_DATA / $CLAUDE_PLUGIN_ROOT)
#
# why this exists: the older SessionStart hook copied files only when absent, so
# once a prompt/agent was seeded it was NEVER refreshed — a shipped update stayed
# invisible on existing installs (the stale data-dir copy shadows the new bundled
# one via resolve-file.sh's user-override layer). This seeder is version-aware:
#   - fresh install:        copy every bundled prompt/agent.
#   - upgrade (version up): refresh ONLY the seeded files the user has not edited
#                           (tracked with a checksum manifest); user edits are
#                           left untouched.
# project overrides in .claude/exec-plan/ always win at resolve time and are
# never touched here. This never fails the session — it always exits 0.

data_dir="${1:-$CLAUDE_PLUGIN_DATA}"
plugin_root="${2:-$CLAUDE_PLUGIN_ROOT}"

# nothing to seed into (e.g. not installed from the marketplace) — no-op
[ -z "$data_dir" ] && exit 0
[ -z "$plugin_root" ] && exit 0
[ -d "$plugin_root" ] || exit 0

version_file="$plugin_root/.claude-plugin/plugin.json"
version=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$version_file" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')
[ -z "$version" ] && version="unknown"

stamp="$data_dir/.seed-version"
manifest="$data_dir/.seed-manifest"

prev_version=""
[ -f "$stamp" ] && prev_version=$(cat "$stamp" 2>/dev/null || true)

mkdir -p "$data_dir/prompts" "$data_dir/agents" 2>/dev/null || exit 0

# portable content checksum; weak size-based fallback if no hashing tool exists
checksum() {
    if command -v shasum >/dev/null 2>&1; then
        shasum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v sha1sum >/dev/null 2>&1; then
        sha1sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" 2>/dev/null | awk '{print $1}'
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "$1" 2>/dev/null
    else
        echo "size-$(wc -c <"$1" 2>/dev/null | tr -d ' ')"
    fi
}

# last-seeded checksum for a key from the manifest, or empty
manifest_lookup() {
    [ -f "$manifest" ] || return 0
    awk -v k="$1" '$2 == k {print $1}' "$manifest" 2>/dev/null | tail -1
}

tmp_manifest="$(mktemp 2>/dev/null)" || exit 0

seed_one() {
    local src="$1" destdir="$2" key="$3"
    local dest newcsum
    dest="$destdir/$(basename "$src")"
    newcsum=$(checksum "$src")

    if [ ! -f "$dest" ]; then
        # fresh: seed it
        cp "$src" "$dest" 2>/dev/null || true
    elif [ "$version" != "$prev_version" ]; then
        # upgrade: refresh only when the seeded copy is unchanged since last seed
        local cur stored
        cur=$(checksum "$dest")
        stored=$(manifest_lookup "$key")
        if [ -n "$stored" ] && [ "$cur" = "$stored" ]; then
            cp "$src" "$dest" 2>/dev/null || true
        fi
        # else: user-modified (or no prior manifest) -> leave as-is
    fi

    # record the current bundled checksum so a later upgrade can tell whether the
    # user has since edited the seeded copy
    printf '%s  %s\n' "$newcsum" "$key" >>"$tmp_manifest"
}

for f in "$plugin_root/skills/exec/references/prompts/"*.md; do
    [ -f "$f" ] && seed_one "$f" "$data_dir/prompts" "prompts/$(basename "$f")"
done
for f in "$plugin_root/skills/exec/references/agents/"*.txt; do
    [ -f "$f" ] && seed_one "$f" "$data_dir/agents" "agents/$(basename "$f")"
done

mv "$tmp_manifest" "$manifest" 2>/dev/null || rm -f "$tmp_manifest" 2>/dev/null
printf '%s\n' "$version" >"$stamp" 2>/dev/null || true

exit 0
