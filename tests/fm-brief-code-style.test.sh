#!/usr/bin/env bash
# Behavior tests for the ship-brief code-style contract in fm-brief.sh.
#
# Ship briefs must carry a "# Code style" section that points the crewmate at the
# Google Style Guide index (and, via the toolchain section, the guide for the
# detected language) and states the review-gate expectation. Scout briefs must not
# (their deliverable is a report, not a code change).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-code-style-tests)
mkdir -p "$TMP_ROOT/home"

run_brief() {
  FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$@" 2>/dev/null
}

run_brief ship-cs1 somerepo >/dev/null
SHIP="$TMP_ROOT/home/data/ship-cs1/brief.md"
assert_present "$SHIP" "ship brief scaffolded"
assert_grep "# Code style" "$SHIP" "ship brief carries the code-style section"
assert_grep "google.github.io/styleguide" "$SHIP" "ship brief points at the Google style guide index"
assert_grep "review criterion" "$SHIP" "ship brief states the review-gate expectation"

run_brief scout-cs1 somerepo --scout >/dev/null
SCOUT="$TMP_ROOT/home/data/scout-cs1/brief.md"
assert_present "$SCOUT" "scout brief scaffolded"
assert_no_grep "# Code style" "$SCOUT" "scout brief has no code-style contract"

pass "fm-brief: ship briefs carry the code-style contract, scout briefs do not"
