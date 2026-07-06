#!/bin/bash
# automated tests for seed-data.sh — the version-aware SessionStart seeder that
# copies exec prompts/agents into the plugin data dir. Verifies: fresh install
# copies everything; an upgrade refreshes unmodified seeded files; user edits are
# preserved across upgrades; same-version reruns don't refresh; new bundled files
# are always seeded; missing data-dir/plugin-root are safe no-ops.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SEED="$REPO_ROOT/plugins/planning/skills/exec/scripts/seed-data.sh"

passed=0
failed=0

assert_temp_dir() {
    local dir="$1"
    local tmpbase="${TMPDIR:-/tmp}"
    tmpbase="${tmpbase%/}"
    case "$dir" in
    "$tmpbase"/*) ;;
    /tmp/*) ;;
    /private/tmp/*) ;;
    /private/var/*) ;;
    /var/folders/*) ;;
    *)
        echo "FATAL: $dir is not under a recognised temp base, refusing to proceed" >&2
        exit 1
        ;;
    esac
}

TMP_DIRS=()
mk_tmp() {
    local d
    d="$(mktemp -d)"
    assert_temp_dir "$d"
    TMP_DIRS+=("$d")
    echo "$d"
}

cleanup() {
    local d
    for d in "${TMP_DIRS[@]:-}"; do
        if [ -n "$d" ] && [ -d "$d" ]; then
            rm -rf "$d"
        fi
    done
    return 0
}
trap cleanup EXIT

assert_output() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $test_name"
        passed=$((passed + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected: $(printf '%q' "$expected")"
        echo "    actual:   $(printf '%q' "$actual")"
        failed=$((failed + 1))
    fi
}

assert_exit() {
    local test_name="$1"
    local expected_rc="$2"
    local actual_rc="$3"
    if [ "$expected_rc" = "$actual_rc" ]; then
        echo "  PASS: $test_name"
        passed=$((passed + 1))
    else
        echo "  FAIL: $test_name (expected exit $expected_rc, got $actual_rc)"
        failed=$((failed + 1))
    fi
}

# write a fake plugin root with a given version and bundled file content
write_plugin() {
    local root="$1" version="$2" content="$3"
    mkdir -p "$root/.claude-plugin" \
        "$root/skills/exec/references/prompts" \
        "$root/skills/exec/references/agents"
    printf '{\n  "name": "planning",\n  "version": "%s"\n}\n' "$version" >"$root/.claude-plugin/plugin.json"
    printf '%s\n' "$content" >"$root/skills/exec/references/prompts/task.md"
    printf '%s\n' "$content" >"$root/skills/exec/references/agents/quality.txt"
}

echo "testing seed-data.sh"
echo "===================="

# test 1: fresh install copies everything + stamps version
echo ""
echo "test 1: fresh install seeds prompts + agents"
ROOT="$(mk_tmp)"
DATA="$(mk_tmp)"
write_plugin "$ROOT" "1.0.0" "BUNDLED-A"
bash "$SEED" "$DATA" "$ROOT"
assert_output "prompt seeded" "BUNDLED-A" "$(cat "$DATA/prompts/task.md" 2>/dev/null)"
assert_output "agent seeded" "BUNDLED-A" "$(cat "$DATA/agents/quality.txt" 2>/dev/null)"
assert_output "version stamped" "1.0.0" "$(cat "$DATA/.seed-version" 2>/dev/null)"

# test 2: upgrade refreshes an unmodified seeded file
echo ""
echo "test 2: upgrade refreshes unmodified files"
write_plugin "$ROOT" "2.0.0" "BUNDLED-B"
bash "$SEED" "$DATA" "$ROOT"
assert_output "unmodified prompt refreshed to new bundle" "BUNDLED-B" "$(cat "$DATA/prompts/task.md")"
assert_output "version stamp updated" "2.0.0" "$(cat "$DATA/.seed-version")"

# test 3: upgrade preserves a user-edited seeded file, refreshes the rest
echo ""
echo "test 3: upgrade preserves user edits"
ROOT2="$(mk_tmp)"
DATA2="$(mk_tmp)"
write_plugin "$ROOT2" "1.0.0" "BUNDLED-A"
bash "$SEED" "$DATA2" "$ROOT2"
printf '%s\n' "USER-EDIT" >"$DATA2/prompts/task.md"
write_plugin "$ROOT2" "2.0.0" "BUNDLED-B"
bash "$SEED" "$DATA2" "$ROOT2"
assert_output "user-edited prompt preserved" "USER-EDIT" "$(cat "$DATA2/prompts/task.md")"
assert_output "untouched agent refreshed" "BUNDLED-B" "$(cat "$DATA2/agents/quality.txt")"

# test 4: same-version rerun does NOT refresh (and preserves edits)
echo ""
echo "test 4: same-version rerun does not refresh"
ROOT3="$(mk_tmp)"
DATA3="$(mk_tmp)"
write_plugin "$ROOT3" "1.0.0" "BUNDLED-A"
bash "$SEED" "$DATA3" "$ROOT3"
printf '%s\n' "USER-EDIT" >"$DATA3/prompts/task.md"
# bundle content changes but version does NOT — must not refresh
printf '%s\n' "BUNDLED-B" >"$ROOT3/skills/exec/references/prompts/task.md"
bash "$SEED" "$DATA3" "$ROOT3"
assert_output "same-version keeps user edit" "USER-EDIT" "$(cat "$DATA3/prompts/task.md")"

# test 5: a brand-new bundled file is always seeded (even without a version bump)
echo ""
echo "test 5: new bundled file is seeded regardless of version"
printf '%s\n' "NEWFILE" >"$ROOT3/skills/exec/references/prompts/newprompt.md"
bash "$SEED" "$DATA3" "$ROOT3"
assert_output "new bundled file seeded" "NEWFILE" "$(cat "$DATA3/prompts/newprompt.md" 2>/dev/null)"

# test 6: empty data-dir is a safe no-op (exit 0)
echo ""
echo "test 6: empty data-dir -> no-op exit 0"
rc=0
bash "$SEED" "" "$ROOT" >/dev/null 2>&1 || rc=$?
assert_exit "empty data-dir exits 0" "0" "$rc"

# test 7: missing plugin-root is a safe no-op (exit 0)
echo ""
echo "test 7: missing plugin-root -> no-op exit 0"
DATA4="$(mk_tmp)"
rc=0
bash "$SEED" "$DATA4" "/no/such/plugin/root" >/dev/null 2>&1 || rc=$?
assert_exit "missing plugin-root exits 0" "0" "$rc"
[ -e "$DATA4/prompts/task.md" ] && seeded="yes" || seeded="no"
assert_output "nothing seeded from missing root" "no" "$seeded"

# test 8: pre-manifest upgrade force-seeds the current bundle once (fixes the
# stale-copies-from-an-old-only-if-absent-install case), then writes a manifest
echo ""
echo "test 8: pre-manifest upgrade reconciles stale copies to the new bundle"
ROOT5="$(mk_tmp)"
DATA5="$(mk_tmp)"
write_plugin "$ROOT5" "1.0.0" "OLD-BUNDLE"
# simulate an OLD only-if-absent install: seeded copies exist, but NO manifest/stamp
mkdir -p "$DATA5/prompts" "$DATA5/agents"
printf 'OLD-BUNDLE\n' >"$DATA5/prompts/task.md"
printf 'OLD-BUNDLE\n' >"$DATA5/agents/quality.txt"
# new plugin version ships new prompt content
write_plugin "$ROOT5" "2.0.0" "NEW-BUNDLE"
bash "$SEED" "$DATA5" "$ROOT5"
assert_output "pre-manifest: stale prompt reconciled to new bundle" "NEW-BUNDLE" "$(cat "$DATA5/prompts/task.md")"
assert_output "pre-manifest: stale agent reconciled to new bundle" "NEW-BUNDLE" "$(cat "$DATA5/agents/quality.txt")"
[ -f "$DATA5/.seed-manifest" ] && m=yes || m=no
assert_output "pre-manifest: manifest now written for future upgrades" "yes" "$m"

# test 9: on a host with no hash tool (weak size-only checksum), a same-size user
# edit is never silently clobbered on upgrade (SEED_CSUM_TOOL=none forces weak mode)
echo ""
echo "test 9: weak-checksum host never clobbers a same-size user edit"
ROOT6="$(mk_tmp)"
DATA6="$(mk_tmp)"
write_plugin "$ROOT6" "1.0.0" "AAAA"
SEED_CSUM_TOOL=none bash "$SEED" "$DATA6" "$ROOT6"
printf 'BBBB\n' >"$DATA6/prompts/task.md" # user edit, SAME byte count as AAAA
write_plugin "$ROOT6" "2.0.0" "CCCC"       # new bundle, also same byte count
SEED_CSUM_TOOL=none bash "$SEED" "$DATA6" "$ROOT6"
assert_output "same-size edit preserved under weak checksum" "BBBB" "$(cat "$DATA6/prompts/task.md")"

# summary
echo ""
echo "========================"
echo "results: $passed passed, $failed failed"

if [ "$failed" -gt 0 ]; then
    exit 1
fi
