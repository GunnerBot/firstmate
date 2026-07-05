#!/usr/bin/env bash
# Behavior tests for fm-graph-health.sh - blast-radius graph health gates.
#
# Covers: N/A for repos with no tracked *.java, the exact-pin tool gate,
# missing index (with and without --index auto-heal), stale index detection
# (with and without --index reindex), and the healthy path. A fake
# codebase-memory-mcp records its project registry in a state dir and touches
# fake index DBs in FM_CMM_CACHE_OVERRIDE, mirroring the real CLI shape
# (level=info stderr noise included).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-graph-health-tests)
GH="$ROOT/bin/fm-graph-health.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
STATE="$TMP_ROOT/cmm-state"
CACHE="$TMP_ROOT/cmm-cache"
mkdir -p "$STATE" "$CACHE"

# Fake cmm: --version honors FM_FAKE_CMM_VERSION; list_projects serves the
# registry JSON; index_repository registers the repo as slug "proj1" and
# touches its DB in the fake cache.
cat > "$FAKEBIN/codebase-memory-mcp" <<SH
#!/usr/bin/env bash
echo 'level=info msg="fake cmm"' >&2
case "\${1:-} \${2:-}" in
  '--version ')
    printf 'codebase-memory-mcp %s\n' "\${FM_FAKE_CMM_VERSION:-0.8.1}" ;;
  'cli list_projects')
    if [ -f "$STATE/projects.json" ]; then cat "$STATE/projects.json"; else printf '{"projects":[]}\n'; fi ;;
  'cli index_repository')
    repo=\$(printf '%s' "\$3" | sed 's/.*"repo_path":"\([^"]*\)".*/\1/')
    printf '{"projects":[{"name":"proj1","root_path":"%s"}]}\n' "\$repo" > "$STATE/projects.json"
    touch "$CACHE/proj1.db" ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/codebase-memory-mcp"

fm_git_identity fmtest fmtest@example.invalid

run_gh() { PATH="$FAKEBIN:$BASE_PATH" FM_CMM_CACHE_OVERRIDE="$CACHE" "$GH" "$@" 2>&1; }

# --- N/A: no tracked *.java -------------------------------------------------
R_SH="$TMP_ROOT/shell-repo"
fm_git_init_commit "$R_SH"
out=$(run_gh "$R_SH"); rc=$?
expect_code 0 "$rc" "N/A: exits 0"
assert_contains "$out" "GRAPH HEALTH: N/A" "N/A reported for a repo with no *.java"

# --- Java repo fixture --------------------------------------------------------
R="$TMP_ROOT/java-repo"
fm_git_init_commit "$R"
printf 'class Foo {}\n' > "$R/Foo.java"
git -C "$R" add Foo.java
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm java

# --- tool gate: wrong version is MISSING (exact pin) -------------------------
out=$(FM_FAKE_CMM_VERSION=0.9.0 run_gh "$R"); rc=$?
expect_code 1 "$rc" "wrong cmm version: exits 1"
assert_contains "$out" "GRAPH HEALTH: MISSING - cmm 0.9.0, pinned 0.8.1" "wrong version reports the pin"

# --- index gate: not indexed, no --index -> MISSING exit 2 -------------------
out=$(run_gh "$R"); rc=$?
expect_code 2 "$rc" "unindexed: exits 2"
assert_contains "$out" "repo not indexed" "unindexed repo reports the index command"

# --- index gate: --index auto-heals ------------------------------------------
out=$(run_gh "$R" --index); rc=$?
expect_code 0 "$rc" "--index heals the missing index"
assert_contains "$out" "GRAPH HEALTH: HEALTHY (slug=proj1" "healed index reports healthy"
assert_present "$CACHE/proj1.db" "index DB created"

# --- healthy steady state -----------------------------------------------------
out=$(run_gh "$R"); rc=$?
expect_code 0 "$rc" "fresh index: exits 0"
assert_contains "$out" "GRAPH HEALTH: HEALTHY" "fresh index reports healthy"

# --- stale: newer commit than DB ----------------------------------------------
touch -t 202001010000 "$CACHE/proj1.db"
printf 'class Bar {}\n' > "$R/Bar.java"
git -C "$R" add Bar.java
git -C "$R" -c user.name=t -c user.email=t@example.invalid commit -qm more
out=$(run_gh "$R"); rc=$?
expect_code 2 "$rc" "stale index: exits 2"
assert_contains "$out" "GRAPH HEALTH: STALE - reindex:" "stale index reports the reindex command"

# --- stale + --index reindexes ------------------------------------------------
out=$(run_gh "$R" --index); rc=$?
expect_code 0 "$rc" "--index reindexes a stale graph"
assert_contains "$out" "reindexed" "stale reindex reported"

# --- stale via uncommitted working-tree *.java edit ---------------------------
touch -t 202001010000 "$CACHE/proj1.db"
printf 'class Foo { int x; }\n' > "$R/Foo.java"
out=$(run_gh "$R"); rc=$?
expect_code 2 "$rc" "modified working-tree java: exits 2"
assert_contains "$out" "GRAPH HEALTH: STALE" "uncommitted edit trips staleness"

pass "fm-graph-health: N/A, exact pin, index heal, staleness, healthy"
