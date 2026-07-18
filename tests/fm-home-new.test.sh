#!/usr/bin/env bash
# Tests for bin/fm-home-new.sh: create and list PEER firstmate homes.
#
# Contract under test:
#   - A peer home is a linked git worktree of this repo at $FM_HOMES_BASE/<name>,
#     detached on the default branch, with its own data/state/config/projects
#     dirs and a plain-file .fm-peer-home marker (NEVER .fm-secondmate-home).
#   - A peer home is NOT registered in data/secondmates.md, so it is co-equal,
#     not a routed subordinate.
#   - captain.md travels; a projects.md is seeded with only the projects the
#     peer actually receives, each inheriting its registry line (delivery mode).
#   - Named projects are cloned from their real origin URL so the peer can push.
#   - Guards: bad name rejected, existing path refused, project that is not a
#     local clone refused, and the FM_HOME_MAX sprawl cap enforced.
#   - --list enumerates peer homes and never lists a secondmate home.
#   - Failures roll the partial home back (no orphan worktree).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NEW="$ROOT/bin/fm-home-new.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-home-new-tests)

# Build a world: a bare origin for the firstmate repo, a primary checkout on
# main (the FM_ROOT / FM_HOME under test), and a bare origin + clone for one
# project so cloning a named project exercises a real push-capable origin.
# Echoes the world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w"

  # firstmate repo
  git init -q --bare "$w/fm-origin.git"
  git -C "$w/fm-origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/fm-origin.git" "$w/fm-seed"
  printf 'firstmate\n' > "$w/fm-seed/AGENTS.md"
  mkdir -p "$w/fm-seed/bin"
  printf 'echo hi\n' > "$w/fm-seed/bin/tool.sh"
  git -C "$w/fm-seed" add -A
  git -C "$w/fm-seed" commit -qm c1
  git -C "$w/fm-seed" push -q origin main
  git clone -q "$w/fm-origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true

  # a project with a real origin, cloned into the home's projects/
  mkdir -p "$w/main/data" "$w/main/projects"
  git init -q --bare "$w/proj-origin.git"
  git -C "$w/proj-origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/proj-origin.git" "$w/proj-seed"
  printf 'proj\n' > "$w/proj-seed/README.md"
  git -C "$w/proj-seed" add -A
  git -C "$w/proj-seed" commit -qm p1
  git -C "$w/proj-seed" push -q origin main
  git clone -q "$w/proj-origin.git" "$w/main/projects/demo"

  printf '# Projects\n\n- demo [direct-PR] - a demo project (added 2026-01-01)\n' \
    > "$w/main/data/projects.md"
  printf 'captain prefers terse commits\n' > "$w/main/data/captain.md"

  printf '%s\n' "$w"
}

# Run fm-home-new.sh against world w with FM_HOMES_BASE pinned inside the world.
run_new() {
  local w=$1; shift
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/main" FM_HOMES_BASE="$w/homes" \
    "$NEW" "$@" 2>&1
}

# --- T1: create a peer home, no projects -----------------------------------
test_create_bare() {
  local w out home
  w=$(new_world t1)
  out=$(run_new "$w" alpha)
  home="$w/homes/alpha"

  assert_contains "$out" "created peer home: $home" "reports creation"
  assert_present "$home/.fm-peer-home" "peer marker written"
  assert_absent "$home/.fm-secondmate-home" "no secondmate marker"
  [ "$(cat "$home/.fm-peer-home")" = "alpha" ] || fail "marker names the home"
  assert_present "$home/data" "data dir seeded"
  assert_present "$home/state" "state dir seeded"
  assert_present "$home/config" "config dir seeded"
  assert_present "$home/projects" "projects dir seeded"
  # Linked worktree, detached HEAD on the default branch.
  git -C "$home" symbolic-ref -q HEAD >/dev/null \
    && fail "peer home is not detached"
  case "$(git -C "$home" rev-parse --git-dir)" in
    */worktrees/*) : ;;
    *) fail "peer home is not a linked worktree" ;;
  esac
  # captain.md travels; not registered as a secondmate.
  assert_grep "captain prefers terse commits" "$home/data/captain.md" "captain.md copied"
  assert_absent "$w/main/data/secondmates.md" "peer not registered as secondmate"
  pass "T1 bare peer home created, marked, detached, captain.md carried"
}

# --- T2: create with a project, mode inherited, clone is push-capable -------
test_create_with_project() {
  local w out home
  w=$(new_world t2)
  out=$(run_new "$w" beta demo)
  home="$w/homes/beta"

  assert_present "$home/projects/demo/.git" "project cloned into peer home"
  assert_grep "- demo [direct-PR]" "$home/data/projects.md" "registry line inherited with mode"
  # The clone's origin is the real project origin (push-capable), NOT the local
  # source clone path.
  [ "$(git -C "$home/projects/demo" remote get-url origin)" = "$w/proj-origin.git" ] \
    || fail "cloned project origin is not the real origin"
  pass "T2 named project cloned from real origin, delivery mode inherited"
}

# --- T3: bad name rejected --------------------------------------------------
test_bad_name_rejected() {
  local w out
  w=$(new_world t3)
  out=$(run_new "$w" "Bad Name" || true)
  assert_contains "$out" "name must be a kebab slug" "bad name rejected"
  assert_absent "$w/homes/Bad Name" "no home created for bad name"
  pass "T3 non-kebab name rejected"
}

# --- T4: existing path refused ----------------------------------------------
test_existing_path_refused() {
  local w out
  w=$(new_world t4)
  run_new "$w" gamma >/dev/null
  out=$(run_new "$w" gamma || true)
  assert_contains "$out" "already exists" "second create refused"
  pass "T4 existing home path refused"
}

# --- T5: unknown project refused, home rolled back --------------------------
test_unknown_project_rolled_back() {
  local w out
  w=$(new_world t5)
  out=$(run_new "$w" delta nope || true)
  assert_contains "$out" "is not a clone" "unknown project refused"
  assert_absent "$w/homes/delta" "partial home rolled back"
  # The worktree admin entry must not linger either.
  git -C "$w/main" worktree list --porcelain | grep -q "$w/homes/delta" \
    && fail "orphan worktree entry left behind"
  pass "T5 unknown project refused before any worktree is created"
}

# --- T6: sprawl cap enforced ------------------------------------------------
test_home_cap_enforced() {
  local w out
  w=$(new_world t6)
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/main" FM_HOMES_BASE="$w/homes" \
    FM_HOME_MAX=2 "$NEW" one >/dev/null 2>&1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/main" FM_HOMES_BASE="$w/homes" \
    FM_HOME_MAX=2 "$NEW" two >/dev/null 2>&1
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/main" FM_HOMES_BASE="$w/homes" \
    FM_HOME_MAX=2 "$NEW" three 2>&1 || true)
  assert_contains "$out" "peer homes already exist" "cap refuses a third home"
  assert_absent "$w/homes/three" "capped home not created"
  pass "T6 FM_HOME_MAX sprawl cap enforced"
}

# --- T7: --list shows peers, excludes secondmate homes ----------------------
test_list_excludes_secondmate() {
  local w out
  w=$(new_world t7)
  run_new "$w" alpha >/dev/null
  # A secondmate-style worktree (secondmate marker) must NOT appear in --list.
  git -C "$w/main" worktree add -q --detach "$w/homes/sm" main
  printf 'sm\n' > "$w/homes/sm/.fm-secondmate-home"

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/main" FM_HOMES_BASE="$w/homes" \
    "$NEW" --list 2>&1)
  assert_contains "$out" "alpha" "peer home listed"
  assert_not_contains "$out" "sm " "secondmate home not listed as a peer"
  pass "T7 --list shows peer homes and excludes secondmate homes"
}

# --- T8: clone failure AFTER worktree add rolls the whole home back ---------
# A project that passes pre-validation (local clone with an origin remote) but
# whose origin is unreachable fails at the clone step, which runs after the
# worktree has been created. This exercises cleanup_partial firing from the
# EXIT trap once the worktree exists.
test_clone_failure_rolls_back() {
  local w out home
  w=$(new_world t8)
  # A local clone whose origin points at a nonexistent bare repo: pre-validation
  # (remote get-url origin) passes, but the actual clone fails.
  git clone -q "$w/proj-origin.git" "$w/main/projects/broken"
  git -C "$w/main/projects/broken" remote set-url origin "$w/does-not-exist.git"

  out=$(run_new "$w" epsilon broken || true)
  home="$w/homes/epsilon"

  assert_contains "$out" "clone failed for broken" "clone failure reported"
  assert_absent "$home" "partial home rolled back after worktree add"
  git -C "$w/main" worktree list --porcelain | grep -q "$home" \
    && fail "orphan worktree entry left behind after clone failure"
  pass "T8 clone failure after worktree add rolls the whole home back"
}

test_create_bare
test_create_with_project
test_bad_name_rejected
test_existing_path_refused
test_unknown_project_rolled_back
test_home_cap_enforced
test_list_excludes_secondmate
test_clone_failure_rolls_back

echo "# all fm-home-new tests passed"
