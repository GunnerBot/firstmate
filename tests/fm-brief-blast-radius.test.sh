#!/usr/bin/env bash
# Behavior tests for the ship-brief blast-radius contract in fm-brief.sh.
#
# Ship briefs must point the crewmate at the blast-radius playbook and the
# graph-health entry command; scout briefs must not (their deliverable is a
# report, not a code change). Also pins that the referenced playbook and
# script actually exist, so the brief never points at a dead path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief-blast-radius-tests)
mkdir -p "$TMP_ROOT/home"

run_brief() {
  FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-brief.sh" "$@" 2>/dev/null
}

run_brief ship-x1 somerepo >/dev/null
SHIP="$TMP_ROOT/home/data/ship-x1/brief.md"
assert_present "$SHIP" "ship brief scaffolded"
assert_grep "# Blast radius" "$SHIP" "ship brief carries the blast-radius section"
assert_grep ".agents/skills/blast-radius/SKILL.md" "$SHIP" "ship brief points at the playbook"
assert_grep "bin/fm-graph-health.sh . --index" "$SHIP" "ship brief names the graph-health entry command"

run_brief scout-x1 somerepo --scout >/dev/null
SCOUT="$TMP_ROOT/home/data/scout-x1/brief.md"
assert_present "$SCOUT" "scout brief scaffolded"
assert_no_grep "Blast radius" "$SCOUT" "scout brief has no blast-radius contract"

# The paths the ship brief references must exist in the repo.
assert_present "$ROOT/.agents/skills/blast-radius/SKILL.md" "blast-radius playbook exists"
assert_present "$ROOT/bin/fm-graph-health.sh" "graph-health script exists"

pass "fm-brief: ship briefs carry the blast-radius contract, scout briefs do not"
