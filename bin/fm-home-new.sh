#!/usr/bin/env bash
# Create or list PEER firstmate homes.
#
# A peer home is an independent, co-equal firstmate instance: its own captain
# runs it interactively from its own tmux workspace, and it owns a fully
# isolated home (state/, data/, config/, projects/, session lock, watcher, and
# per-home tmux session). Peer homes are how one repo is run as several
# firstmates at once with no shared mutable state and thus no races: the session
# lock (bin/fm-lock.sh) deliberately sends a second writer in the SAME home
# read-only, so parallel firstmates need SEPARATE homes, which is exactly this.
#
# A peer home is a linked git worktree of this repo, so it shares the object
# store (cheap, one repo, N checkouts) but nothing mutable. It rests at a
# detached HEAD on the default branch, like a leased secondmate home, and
# self-updates through /updatefirstmate the same way.
#
# A peer home is NOT a secondmate. It is co-equal, not subordinate: it is marked
# with .fm-peer-home (never .fm-secondmate-home) and is deliberately absent from
# data/secondmates.md, so the main firstmate never routes work to it and the
# secondmate sweep never claims it. The distinction is the whole point - a peer
# is a separate captain's separate firstmate, not a crew this firstmate drives.
#
# Usage:
#   fm-home-new.sh <name> [project...]   create peer home <name>, optionally
#                                        cloning the named projects into it
#   fm-home-new.sh --list                list existing peer homes with in-flight
#                                        counts and watcher-beacon age
#   fm-home-new.sh --help
#
# <name> is a kebab slug ([a-z0-9] then [a-z0-9-]*). The home is created at
# $FM_HOMES_BASE/<name> (FM_HOMES_BASE defaults to $HOME/fm). Creation refuses an
# existing path, a name collision with an existing worktree, or exceeding
# FM_HOME_MAX peer homes (default 12) - a guard against home sprawl, where a
# dozen half-alive homes each carry a stale watcher and possibly unlanded work.
#
# Named projects are cloned from their real origin URL (read from this home's
# own clone) so the peer can push and open PRs, and the matching data/projects.md
# registry line is copied so the peer inherits each project's delivery mode.
# data/captain.md, if present, is copied so captain preferences travel to the new
# home (the harness's own per-cwd memory does NOT travel - a fresh home starts
# with fresh harness memory, which is the intended isolation).
#
# This writes only OUTSIDE any existing project: it creates a new home and clones
# fresh project copies into it. It never edits, commits to, or runs state-changing
# commands in an existing projects/ clone, so prime directive #1 holds.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
HOMES_BASE="${FM_HOMES_BASE:-$HOME/fm}"
HOME_MAX="${FM_HOME_MAX:-12}"
PEER_MARKER=".fm-peer-home"

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'
}

die() { echo "error: $*" >&2; exit 1; }

# Enumerate absolute paths of existing peer homes: any linked worktree of this
# repo whose root holds a plain-file .fm-peer-home marker.
list_peer_home_paths() {
  git -C "$FM_ROOT" worktree list --porcelain 2>/dev/null \
    | sed -n 's/^worktree //p' \
    | while IFS= read -r wt; do
        [ -n "$wt" ] || continue
        if [ -f "$wt/$PEER_MARKER" ] && [ ! -L "$wt/$PEER_MARKER" ]; then
          printf '%s\n' "$wt"
        fi
      done
  # Always succeed: a trailing non-peer worktree must not make the whole
  # pipeline return non-zero and trip the caller's set -e.
  return 0
}

cmd_list() {
  local now beat age count paths any=no
  now=$(date +%s)
  paths=$(list_peer_home_paths)
  [ -n "$paths" ] || { echo "no peer homes"; return 0; }
  printf '%-28s %9s %s\n' "HOME" "IN-FLIGHT" "WATCHER"
  while IFS= read -r home; do
    [ -n "$home" ] || continue
    any=yes
    count=$(find "$home/state" -maxdepth 1 -name '*.meta' 2>/dev/null | wc -l | tr -d ' ')
    beat="$home/state/.last-watcher-beat"
    if [ -f "$beat" ]; then
      age=$(( now - $(stat -f %m "$beat" 2>/dev/null || stat -c %Y "$beat" 2>/dev/null || echo "$now") ))
      printf '%-28s %9s beacon %ss ago\n' "$(basename "$home")" "$count" "$age"
    else
      printf '%-28s %9s no beacon\n' "$(basename "$home")" "$count"
    fi
  done <<EOF
$paths
EOF
  [ "$any" = yes ] || echo "no peer homes"
}

cmd_new() {
  local name=$1; shift
  case "$name" in
    [a-z0-9]) ;;
    [a-z0-9]*[a-z0-9]) ;;
    *) die "name must be a kebab slug: lowercase letters, digits, and dashes, e.g. alpha" ;;
  esac
  case "$name" in
    *[!a-z0-9-]*) die "name must be a kebab slug: lowercase letters, digits, and dashes, e.g. alpha" ;;
  esac

  local home="$HOMES_BASE/$name"
  [ -e "$home" ] && die "$home already exists"

  # Sprawl guard: refuse past the cap and show what already exists.
  local existing
  existing=$(list_peer_home_paths | wc -l | tr -d ' ')
  if [ "$existing" -ge "$HOME_MAX" ]; then
    echo "error: $existing peer homes already exist (cap FM_HOME_MAX=$HOME_MAX); retire one before adding more" >&2
    cmd_list >&2
    exit 1
  fi

  local default
  default=$(default_branch "$FM_ROOT") || die "cannot determine the firstmate default branch"

  # Validate every named project up front, before creating anything, so a bad
  # name fails cleanly with nothing to roll back.
  local p url line
  for p in "$@"; do
    [ -d "$PROJECTS/$p/.git" ] || die "project '$p' is not a clone under $PROJECTS"
    git -C "$PROJECTS/$p" remote get-url origin >/dev/null 2>&1 \
      || die "project '$p' has no origin remote to clone from"
  done

  mkdir -p "$(dirname "$home")"
  # Raw `git worktree add`, not a treehouse lease, is safe here: a peer home
  # lives under $FM_HOMES_BASE (default $HOME/fm), OUTSIDE treehouse's pool
  # directory (~/.treehouse/). treehouse only ever gets or prunes worktrees
  # registered inside its own pool namespace, so a peer home is never reclaimed
  # out from under its captain (verified: `treehouse status` from a peer home
  # reports an empty pool).
  git -C "$FM_ROOT" worktree add -q --detach "$home" "$default" \
    || die "git worktree add failed for $home"

  # From here on, roll the whole home back on any failure so a partial home is
  # never left behind.
  cleanup_partial() {
    git -C "$FM_ROOT" worktree remove --force "$home" 2>/dev/null \
      || rm -rf "$home"
    git -C "$FM_ROOT" worktree prune 2>/dev/null || true
  }
  trap 'cleanup_partial' EXIT

  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$name" > "$home/$PEER_MARKER"

  # Captain preferences travel; harness per-cwd memory does not.
  [ -f "$DATA/captain.md" ] && cp "$DATA/captain.md" "$home/data/captain.md"

  # Seed the peer's registry with only the projects it actually gets, copying
  # each project's registry line so its delivery mode is inherited.
  printf '# Projects\n\n' > "$home/data/projects.md"
  for p in "$@"; do
    url=$(git -C "$PROJECTS/$p" remote get-url origin)
    echo "cloning $p ..." >&2
    git clone -q "$url" "$home/projects/$p" || die "clone failed for $p"
    # Copy the project's registry line, matching the name as a LITERAL prefix
    # (case globs quote $p, so a name with regex/glob metachars cannot over-match
    # another line). A registry line is "- <name> ..." or "- <name>[<mode>] ...".
    line=""
    if [ -f "$DATA/projects.md" ]; then
      while IFS= read -r rline; do
        case "$rline" in
          "- $p "*|"- ${p}["*) line="$rline"; break ;;
        esac
      done < "$DATA/projects.md"
    fi
    [ -n "$line" ] && printf '%s\n' "$line" >> "$home/data/projects.md"
  done

  trap - EXIT
  echo "created peer home: $home"
  echo "  marker:   $PEER_MARKER ($name), absent from data/secondmates.md (a peer, not a secondmate)"
  echo "  projects: ${*:-none}"
  echo
  echo "run it from its own tmux workspace:"
  echo "  cd $home && claude"
}

case "${1:-}" in
  ""|-h|--help) usage; [ "${1:-}" = "" ] && exit 1 || exit 0 ;;
  --list) cmd_list ;;
  --*) die "unknown flag: $1" ;;
  *) cmd_new "$@" ;;
esac
