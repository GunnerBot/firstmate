#!/usr/bin/env bash
# Behavior tests for fm-stack-sync.sh - stacked-branch resync (pure git).
#
# Covers: restacking onto an advanced parent tip (review-fix drift), restacking off
# a merged parent onto the default branch using the recorded tip (squash-safe),
# the no-op when the parent tip is unchanged, the "nothing to sync" path when no
# parent is recorded, and the error on a missing meta. gh-axi is absent in tests,
# so the PR-base retarget is skipped (best-effort by design).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
SYNC="$ROOT/bin/fm-stack-sync.sh"
TMP=$(fm_test_tmproot fm-stack-sync-tests)
mkdir -p "$TMP/state"

run_sync() { FM_HOME="$TMP" FM_STATE_OVERRIDE="$TMP/state" FM_ROOT_OVERRIDE="$ROOT" bash "$SYNC" "$@"; }

# =========================================================================
# Drift: parent branch advances (review fix) -> child restacks onto new tip.
# =========================================================================
R="$TMP/drift"; mkdir -p "$R"; git -C "$R" init -q -b main
git -C "$R" commit -q --allow-empty -m c0
git -C "$R" checkout -q -b fm/parent
git -C "$R" commit -q --allow-empty -m p1
P1=$(git -C "$R" rev-parse HEAD)
WT="$TMP/wt-drift"
git -C "$R" worktree add -q -b fm/child "$WT" fm/parent
git -C "$WT" commit -q --allow-empty -m x1
git -C "$R" commit -q --allow-empty -m p2      # parent advances
P2=$(git -C "$R" rev-parse fm/parent)
fm_write_meta "$TMP/state/child.meta" "worktree=$WT" "parent=parent" "parent_tip=$P1" "parent_branch=fm/parent" "project=$R"

out=$(run_sync child 2>&1)
assert_contains "$out" "restacked" "drift: reports restack"
newtip=$(grep '^parent_tip=' "$TMP/state/child.meta" | cut -d= -f2-)
[ "$newtip" = "$P2" ] || fail "drift: parent_tip should update to p2 ($newtip != $P2)"
git -C "$WT" merge-base --is-ancestor "$P2" fm/child || fail "drift: child not rebased onto new parent tip"
git -C "$WT" log --oneline fm/child | grep -q x1 || fail "drift: child commit x1 lost"

# idempotent: second run is a no-op
out=$(run_sync child 2>&1)
assert_contains "$out" "up to date" "drift: second run is a no-op"

# =========================================================================
# Merged: parent PR merged -> child restacks onto default, dropping parent commits.
# =========================================================================
R2="$TMP/merged"; mkdir -p "$R2"; git -C "$R2" init -q -b main
git -C "$R2" commit -q --allow-empty -m c0
C0=$(git -C "$R2" rev-parse HEAD)
git -C "$R2" checkout -q -b fm/parent
git -C "$R2" commit -q --allow-empty -m p1
P1b=$(git -C "$R2" rev-parse HEAD)
WT2="$TMP/wt-merged"
git -C "$R2" worktree add -q -b fm/mchild "$WT2" fm/parent   # child id "mchild" -> branch fm/mchild
git -C "$WT2" commit -q --allow-empty -m x1
git -C "$R2" checkout -q main       # leave fm/parent free
fm_write_meta "$TMP/state/mchild.meta" "worktree=$WT2" "parent=parent" "parent_tip=$P1b" "parent_branch=fm/parent" "project=$R2"

out=$(run_sync mchild --parent-merged 2>&1)
assert_contains "$out" "parent linkage cleared" "merged: reports cleared linkage"
if git -C "$WT2" merge-base --is-ancestor "$P1b" fm/mchild 2>/dev/null; then fail "merged: parent commit p1 should be dropped"; fi
git -C "$WT2" merge-base --is-ancestor "$C0" fm/mchild || fail "merged: child not on default branch base"
git -C "$WT2" log --oneline fm/mchild | grep -q x1 || fail "merged: child commit x1 lost"
assert_no_grep "parent" "$TMP/state/mchild.meta" "merged: parent* linkage removed from meta"

# =========================================================================
# No parent recorded -> nothing to sync (exit 0).
# =========================================================================
fm_write_meta "$TMP/state/solo.meta" "worktree=$WT" "project=$R"
out=$(run_sync solo 2>&1); rc=$?
expect_code 0 "$rc" "no-parent: exits 0"
assert_contains "$out" "nothing to sync" "no-parent: reports nothing to sync"

# =========================================================================
# Missing meta -> error (exit 1).
# =========================================================================
out=$(run_sync ghost 2>&1); rc=$?
expect_code 1 "$rc" "missing meta: exits 1"

pass "fm-stack-sync: drift restack, squash-safe merged restack, no-op, no-parent, missing-meta"
