#!/usr/bin/env bash
# Behavior tests for fm-dag.sh - the width-optimized DAG planner over backlog.md.
#
# Covers: the ready-now frontier, the wave schedule (parallel width vs serial
# depth), scope-overlap warnings within a wave, in-flight blockers (excluded from
# dispatch-now but treated as completing in the schedule), unknown/pruned blockers
# counting as satisfied, and graceful handling of a missing backlog.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DAG="$ROOT/bin/fm-dag.sh"
TMP=$(fm_test_tmproot fm-dag-tests)
mkdir -p "$TMP"

# --- diamond: root done, two independent middles ready, leaf blocked by both ---
bl="$TMP/diamond.md"
cat > "$bl" <<'MD'
## In flight

## Queued
- [ ] mid-a - build A (repo: x)
- [ ] mid-b - build B (repo: x)
- [ ] leaf - integrate (repo: x) blocked-by: mid-a, mid-b - needs both

## Done
- [x] root - scaffold - https://github.com/o/x/pull/1 (merged 2026-07-01)
MD
ready=$("$DAG" ready "$bl")
assert_contains "$ready" "mid-a" "diamond: mid-a is ready"
assert_contains "$ready" "mid-b" "diamond: mid-b is ready"
assert_not_contains "$ready" "leaf" "diamond: leaf is blocked, not ready"
plan=$("$DAG" plan "$bl")
assert_contains "$plan" "ready now: 2" "diamond: reports 2 ready now"
assert_contains "$plan" "max parallel width 2" "diamond: width 2"
assert_contains "$plan" "2 wave(s)" "diamond: 2 waves"

# --- scope overlap within the ready wave (a/b overlap, c disjoint) ---
bl="$TMP/overlap.md"
cat > "$bl" <<'MD'
## Queued
- [ ] a - touch foo (repo: x) scope: src/foo
- [ ] b - touch bar (repo: x) scope: src/foo/bar.py
- [ ] c - touch docs (repo: x) scope: docs/

## Done
MD
plan=$("$DAG" plan "$bl")
assert_contains "$plan" "overlapping scope" "overlap: a/b flagged"
assert_contains "$plan" "a and b" "overlap: names the overlapping pair"
assert_not_contains "$plan" "c and" "overlap: disjoint node c not flagged"

# --- serial chain a -> b -> c ---
bl="$TMP/serial.md"
cat > "$bl" <<'MD'
## Queued
- [ ] a - first (repo: x)
- [ ] b - second (repo: x) blocked-by: a - after a
- [ ] c - third (repo: x) blocked-by: b - after b

## Done
MD
ready=$("$DAG" ready "$bl")
assert_contains "$ready" "a" "serial: a is ready"
assert_not_contains "$ready" "b" "serial: b is blocked"
plan=$("$DAG" plan "$bl")
assert_contains "$plan" "3 wave(s), max parallel width 1" "serial: 3 waves, width 1"
assert_contains "$plan" "fully serial" "serial: flagged as fully serial"

# --- in-flight blocker: excluded from ready-now, present in schedule ---
bl="$TMP/inflight.md"
cat > "$bl" <<'MD'
## In flight
- [ ] running - long build (repo: x, since 2026-07-01)

## Queued
- [ ] waiter - after running (repo: x) blocked-by: running - waits

## Done
MD
ready=$("$DAG" ready "$bl")
assert_not_contains "$ready" "waiter" "inflight: waiter not dispatchable now"
plan=$("$DAG" plan "$bl")
assert_contains "$plan" "in-flight: 1" "inflight: counted"
assert_contains "$plan" "wave 1 (1 parallel): waiter" "inflight: waiter is wave 1 in schedule"

# --- unknown/pruned blocker counts as satisfied ---
bl="$TMP/pruned.md"
cat > "$bl" <<'MD'
## Queued
- [ ] x - depends on pruned (repo: r) blocked-by: gone-42 - done long ago, pruned

## Done
MD
ready=$("$DAG" ready "$bl")
assert_contains "$ready" "x" "pruned/unknown blocker treated as satisfied"

# --- missing backlog: graceful exit 0 ---
"$DAG" plan "$TMP/nope.md" >/dev/null 2>&1; rc=$?
expect_code 0 "$rc" "missing backlog exits 0"

pass "fm-dag: frontier, wave width/depth, scope overlap, in-flight, pruned blocker, graceful"
