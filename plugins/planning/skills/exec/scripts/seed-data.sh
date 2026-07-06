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

# whether a prior manifest exists. Its ABSENCE means an old only-if-absent install
# (or a first run of this seeder): we can't tell stale shipped copies from edits, so
# we reconcile once to the current bundle. Its PRESENCE means we can preserve edits.
have_manifest=0
[ -f "$manifest" ] && have_manifest=1

mkdir -p "$data_dir/prompts" "$data_dir/agents" 2>/dev/null || exit 0

# pick a content-hash tool once. SEED_CSUM_TOOL overrides detection (`none` forces
# the weak fallback — mainly for tests / hosts with a broken hasher). An empty
# CSUM_TOOL means "no real hash": we then NEVER authorize an upgrade-refresh, so a
# same-size user edit can't be silently clobbered by the size-only fallback.
CSUM_TOOL="${SEED_CSUM_TOOL:-}"
if [ -z "$CSUM_TOOL" ]; then
    if command -v shasum >/dev/null 2>&1; then
        CSUM_TOOL=shasum
    elif command -v sha1sum >/dev/null 2>&1; then
        CSUM_TOOL=sha1sum
    elif command -v md5sum >/dev/null 2>&1; then
        CSUM_TOOL=md5sum
    elif command -v md5 >/dev/null 2>&1; then
        CSUM_TOOL=md5
    fi
fi
[ "$CSUM_TOOL" = "none" ] && CSUM_TOOL=""

# content checksum via the selected tool; weak size-based value when none exists
checksum() {
    case "$CSUM_TOOL" in
    shasum | sha1sum | md5sum) "$CSUM_TOOL" "$1" 2>/dev/null | awk '{print $1}' ;;
    md5) md5 -q "$1" 2>/dev/null ;;
    *) echo "size-$(wc -c <"$1" 2>/dev/null | tr -d ' ')" ;;
    esac
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
    elif [ "$have_manifest" -eq 0 ]; then
        # pre-manifest upgrade: an old only-if-absent install left stale copies with
        # no manifest to distinguish edits from shipped defaults. Reconcile ONCE to
        # the current bundle; the manifest written below lets future upgrades
        # preserve genuine edits from here on.
        cp "$src" "$dest" 2>/dev/null || true
    elif [ "$version" != "$prev_version" ] && [ -n "$CSUM_TOOL" ]; then
        # upgrade WITH a manifest AND a real hash: refresh only files unchanged
        # since the last seed. Without a real hash we skip refresh entirely so the
        # weak size-only fallback can never clobber a same-size user edit.
        local cur stored
        cur=$(checksum "$dest")
        stored=$(manifest_lookup "$key")
        if [ -n "$stored" ] && [ "$cur" = "$stored" ]; then
            cp "$src" "$dest" 2>/dev/null || true
        fi
        # else: user-modified -> leave as-is
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
