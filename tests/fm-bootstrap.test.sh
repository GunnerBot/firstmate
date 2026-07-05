#!/usr/bin/env bash
# Behavior tests for fm-bootstrap.sh tool detection.
#
# Bootstrap prints one line per problem or capability fact and is silent when all
# is well. firstmate consumes the exact 'MISSING: treehouse (install: ...)' and
# 'TASKS_AXI: available' lines, so those contracts are pinned verbatim. The cases
# are table-driven over the inputs that vary: whether `treehouse get --help`
# advertises --lease, which (if any) tasks-axi version is on PATH, and which
# no-mistakes version is on PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-bootstrap-tests)

# A fake toolchain where every required tool is present and gh is authenticated.
# treehouse's `get --help` advertises --lease only when FM_FAKE_TREEHOUSE_LEASE_HELP=1.
# bash reports FM_FAKE_BASH_VERSION (default 5.2.0) to --version and otherwise
# execs the real /bin/bash, so it is safe as a PATH-resolved interpreter.
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi jq
  cat > "$fakebin/bash" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then
  printf 'GNU bash, version %s(1)-release (fake)\n' "${FM_FAKE_BASH_VERSION:-5.2.0}"
  exit 0
fi
exec /bin/bash "$@"
SH
  chmod +x "$fakebin/bash"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  if [ "${FM_FAKE_TREEHOUSE_LEASE_HELP:-}" = 1 ]; then
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
  else
    printf '%s\n' 'Usage: treehouse get'
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "${FM_FAKE_NO_MISTAKES_VERSION:-no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  # cmm prints level=info noise to stderr before answering, like the real binary.
  cat > "$fakebin/codebase-memory-mcp" <<'SH'
#!/usr/bin/env bash
echo 'level=info msg="fake cmm"' >&2
if [ "${1:-}" = --version ]; then
  printf 'codebase-memory-mcp %s\n' "${FM_FAKE_CMM_VERSION:-0.8.1}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/codebase-memory-mcp"
  printf '%s\n' "$fakebin"
}

add_tasks_axi() {
  local fakebin=$1 version=$2
  cat > "$fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' '$version'
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
}

# Each row (fields are '^'-separated; the install URL contains a literal '|'):
#   <label>^<lease 1/0>^<tasks-axi version or ->^<mode>^<expect>^<notcontains>
#   mode=empty -> output must be empty (expect/notcontains ignored)
#   mode=exact -> output must equal <expect>
#   mode=grep  -> output must contain <expect> (fixed string); <notcontains> must not appear
test_bootstrap_reporting() {
  local label lease tasks mode expect notcontains case_dir fakebin out n
  n=0
  while IFS='^' read -r label lease tasks mode expect notcontains; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/case-$n"
    mkdir -p "$case_dir/home"
    fakebin=$(make_fake_toolchain "$case_dir")
    [ "$tasks" = "-" ] || add_tasks_axi "$fakebin" "$tasks"
    # FM_ROOT_OVERRIDE points the worktree-tangle check at the non-git home dir so
    # it stays inert: this suite pins tool detection, not the tangle guard, and the
    # ambient checkout (CI runs on a feature branch) must not leak a TANGLE line in.
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP="$lease" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ -z "$out" ] || fail "$label: expected silence, got: $out" ;;
      exact)
        [ "$out" = "$expect" ] || fail "$label: expected '$expect', got: $out" ;;
      grep)
        printf '%s\n' "$out" | grep -Fx "$expect" >/dev/null || fail "$label: missing '$expect' (got: $out)"
        if [ -n "$notcontains" ]; then
          printf '%s\n' "$out" | grep -F "$notcontains" >/dev/null && fail "$label: unexpected '$notcontains' in: $out"
        fi
        ;;
    esac
  done <<'ROWS'
full suite present reports only tasks-axi availability^1^0.1.1^exact^TASKS_AXI: available^
treehouse without --lease reports an upgrade, gh auth is fine^0^0.1.1^grep^MISSING: treehouse (install: curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh)^NEEDS_GH_AUTH
missing tasks-axi reports an install^1^-^exact^MISSING: tasks-axi (install: npm install -g tasks-axi)^
incompatible tasks-axi reports an upgrade^1^0.1.0^grep^MISSING: tasks-axi (install: npm install -g tasks-axi)^TASKS_AXI: available
ROWS
  pass "bootstrap reports treehouse lease + tasks-axi compatibility contracts"
}

# cmm (codebase-memory-mcp) is pinned to one validated version, not a floor:
# absent or any other version reports the same MISSING install line.
test_cmm_exact_pin() {
  local case_dir fakebin out missing
  missing='MISSING: codebase-memory-mcp (install: mkdir -p "$HOME/.local/bin" && gh release download v0.8.1 -R DeusData/codebase-memory-mcp -p "codebase-memory-mcp-$(uname -s | tr A-Z a-z)-$(uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/).tar.gz" -O - | tar -xz -C "$HOME/.local/bin" codebase-memory-mcp)'
  case_dir="$TMP_ROOT/cmm-pin"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_tasks_axi "$fakebin" 0.1.1

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_CMM_VERSION=0.9.0 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -Fx "$missing" >/dev/null || fail "wrong cmm version should report the pin (got: $out)"

  rm -f "$fakebin/codebase-memory-mcp"
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  printf '%s\n' "$out" | grep -Fx "$missing" >/dev/null || fail "absent cmm should report the install (got: $out)"

  pass "bootstrap pins codebase-memory-mcp to the validated version"
}

# bash and jq are part of the enforced suite: an old PATH bash (< 4) and a
# missing jq each report a MISSING line; bash 4.x is the accepted floor.
test_bash_and_jq_enforcement() {
  local case_dir fakebin out
  case_dir="$TMP_ROOT/bash-jq"
  mkdir -p "$case_dir/home"
  fakebin=$(make_fake_toolchain "$case_dir")
  add_tasks_axi "$fakebin" 0.1.1

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_BASH_VERSION=3.2.57 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: bash (install: brew install bash  # or the platform's package manager)" \
    "old bash reports an upgrade"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_BASH_VERSION=4.0.0 "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "MISSING: bash" "bash 4.0 is the accepted floor"

  # The OS may ship its own jq (macOS Sequoia: /usr/bin/jq), so removing the
  # fake is not enough - the case needs system dirs with jq filtered out.
  local sysbin d f b
  sysbin="$case_dir/sysbin"
  mkdir -p "$sysbin"
  for d in /usr/bin /bin; do
    for f in "$d"/*; do
      b=$(basename "$f")
      [ "$b" = jq ] && continue
      [ -e "$sysbin/$b" ] || ln -s "$f" "$sysbin/$b"
    done
  done
  rm -f "$fakebin/jq"
  out=$(PATH="$fakebin:$sysbin:/usr/sbin:/sbin" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "MISSING: jq (install: brew install jq  # or the platform's package manager)" \
    "missing jq reports an install"

  pass "bootstrap enforces bash 4+ and jq in the default suite"
}

test_no_mistakes_min_version() {
  local label version mode case_dir fakebin out missing n
  missing='MISSING: no-mistakes (install: curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh)'
  n=0
  while IFS='^' read -r label version mode; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir="$TMP_ROOT/no-mistakes-$n"
    mkdir -p "$case_dir/home"
    fakebin=$(make_fake_toolchain "$case_dir")
    add_tasks_axi "$fakebin" 0.1.1
    out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/home" \
      FM_FAKE_TREEHOUSE_LEASE_HELP=1 FM_FAKE_NO_MISTAKES_VERSION="$version" "$ROOT/bin/fm-bootstrap.sh")
    case "$mode" in
      empty)
        [ "$out" = "TASKS_AXI: available" ] || fail "$label: expected only availability, got: $out" ;;
      missing)
        [ "$out" = "$missing"$'\n'"TASKS_AXI: available" ] || fail "$label: expected '$missing', got: $out" ;;
    esac
  done <<'ROWS'
minimum no-mistakes version is accepted^no-mistakes version v1.31.2 (fake)^empty
newer no-mistakes minor is accepted^no-mistakes version v1.32.0 (fake)^empty
newer no-mistakes major is accepted^no-mistakes version v2.0.0 (fake)^empty
older no-mistakes patch reports an upgrade^no-mistakes version v1.31.1 (fake)^missing
unparseable no-mistakes version reports an upgrade^no-mistakes development build^missing
ROWS
  pass "bootstrap enforces no-mistakes minimum version"
}

test_bootstrap_reporting
test_no_mistakes_min_version
test_cmm_exact_pin
test_bash_and_jq_enforcement
