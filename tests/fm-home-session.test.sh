#!/usr/bin/env bash
# Behavior tests for fm_tmux_home_session in fm-tmux-lib.sh.
#
# Each firstmate home must map to its own deterministic tmux session name so
# multiple homes sharing one tmux server never share the fm-<id> window namespace
# (the multi-firstmate clash). The name must be stable per home, distinct across
# homes (even same-basename homes at different absolute paths), and contain no
# tmux-illegal characters (':' or '.').
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

# Deterministic: same home -> same name across calls.
a1=$(fm_tmux_home_session /Users/x/gunnerbot-firstmate)
a2=$(fm_tmux_home_session /Users/x/gunnerbot-firstmate)
[ "$a1" = "$a2" ] || fail "not deterministic: $a1 != $a2"
assert_contains "$a1" "fm-" "session name is fm-prefixed"
assert_contains "$a1" "gunnerbot-firstmate" "session name carries the home basename"

# Distinct homes -> distinct sessions.
b=$(fm_tmux_home_session /Users/x/other-home)
[ "$a1" != "$b" ] || fail "distinct homes collided: $a1"

# Same basename, different absolute path -> distinct sessions (hash disambiguates).
c1=$(fm_tmux_home_session /Users/alice/firstmate)
c2=$(fm_tmux_home_session /Users/bob/firstmate)
[ "$c1" != "$c2" ] || fail "same-basename homes collided: $c1"

# No tmux-illegal characters (':' or '.') even for a path full of them.
d=$(fm_tmux_home_session "/Users/x/weird.name:dir/home.v2")
case "$d" in
  *:*|*.*) fail "session name contains tmux-illegal char: $d" ;;
esac
assert_contains "$d" "fm-" "sanitized name still fm-prefixed"

pass "fm_tmux_home_session: deterministic, distinct per home, tmux-safe"
