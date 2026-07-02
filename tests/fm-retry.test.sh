#!/usr/bin/env bash
# Behavior tests for fm-retry.sh - the bounded revise/re-steer counter.
#
# Covers: bumping within the cap (exit 0) then escalation once exceeded (exit 3),
# the --max override, per-gate and per-task independence, --peek (no bump), and
# --reset.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RETRY="$ROOT/bin/fm-retry.sh"
TMP=$(fm_test_tmproot fm-retry-tests)
mkdir -p "$TMP/state"

run() { FM_HOME="$TMP" FM_STATE_OVERRIDE="$TMP/state" FM_ROOT_OVERRIDE="$ROOT" bash "$RETRY" "$@"; }

# --- default cap 3: three retries ok, fourth escalates ---
out=$(run t1 review); rc=$?; expect_code 0 "$rc" "review bump 1 ok"; assert_contains "$out" "retry 1/3" "review 1/3"
out=$(run t1 review); assert_contains "$out" "retry 2/3" "review 2/3"
out=$(run t1 review); assert_contains "$out" "retry 3/3" "review 3/3"
out=$(run t1 review); rc=$?; expect_code 3 "$rc" "review 4th escalates (exit 3)"
assert_contains "$out" "escalate" "review escalation message"
assert_contains "$out" "needs-decision" "escalation tells firstmate to raise needs-decision"

# --- --max override (cap 2) ---
out=$(run t1 build --max 2); assert_contains "$out" "retry 1/2" "build 1/2"
out=$(run t1 build --max 2); assert_contains "$out" "retry 2/2" "build 2/2"
out=$(run t1 build --max 2); rc=$?; expect_code 3 "$rc" "build 3rd escalates at cap 2"

# --- per-gate independence: review is exhausted but a fresh gate starts at 1 ---
out=$(run t1 lint); assert_contains "$out" "retry 1/3" "lint independent from review"

# --- per-task independence: same gate label, different id, fresh counter ---
out=$(run t2 review); assert_contains "$out" "retry 1/3" "t2 review independent from t1"

# --- peek does not bump ---
before=$(run t2 review --peek)
_=$(run t2 review)                 # bump to 2
peek=$(run t2 review --peek)
[ "$before" = "1" ] || fail "peek before bump should read 1 (got $before)"
[ "$peek" = "2" ] || fail "peek after one bump should read 2 (got $peek)"

# --- reset clears the counter ---
out=$(run t2 review --reset); assert_contains "$out" "reset" "reset reports"
[ "$(run t2 review --peek)" = "0" ] || fail "peek after reset should read 0"
out=$(run t2 review); assert_contains "$out" "retry 1/3" "counter starts fresh after reset"

# --- bad --max is rejected ---
out=$(run t3 x --max nope 2>&1); rc=$?; expect_code 2 "$rc" "non-numeric --max rejected"

pass "fm-retry: bounded bumps, escalation, --max, per-gate/per-task isolation, peek, reset"
