#!/usr/bin/env bash
# fm-stack-sync.sh - keep a stacked crewmate branch synced to its parent (pure git).
#
# When a feature is decomposed into stacked PRs, a child task's branch (fm/<child>)
# is cut from its parent's branch at a recorded tip. Two things later invalidate
# that base: the parent PR merges (often a squash, so the parent's commits live
# nowhere on a remote), or the parent branch advances from review fixes. This
# helper rebases the child accordingly, using the RECORDED parent tip rather than
# the parent branch name, so it survives a squash-merge.
#
# It reads these from state/<child>.meta (written when the stacked child is spawned):
#   worktree=       the child's isolated worktree
#   parent=<id>     the parent task id (absent -> nothing to sync, exit 0)
#   parent_tip=<sha> the parent branch tip the child was cut from
#   parent_branch=  optional; defaults to fm/<parent>
#   pr=             optional child PR url, used to retarget the PR base (best-effort)
#
# Modes:
#   fm-stack-sync.sh <child-id>                  Parent still open: if the parent
#     branch advanced past the recorded tip, rebase the child onto the new tip and
#     update parent_tip=. No-op if the tip is unchanged.
#   fm-stack-sync.sh <child-id> --parent-merged  Parent PR merged: rebase the child
#     off the parent's commits onto the default branch (drops the now-merged parent
#     commits via --onto <default> <recorded_tip>), retarget the child PR base to
#     the default branch (best-effort), and clear the parent linkage.
#
# On a rebase conflict it aborts the rebase and prints the resolve steps, exiting
# non-zero - firstmate escalates rather than leaving a half-rebased worktree.
# Pure git (+ optional gh-axi for the base retarget); no jq, no tasks-axi.
set -eu

MERGED=0
ID=""
for a in "$@"; do
  case "$a" in
    --parent-merged) MERGED=1 ;;
    -*) echo "usage: fm-stack-sync.sh <child-id> [--parent-merged]" >&2; exit 2 ;;
    *) [ -z "$ID" ] && ID=$a || { echo "usage: fm-stack-sync.sh <child-id> [--parent-merged]" >&2; exit 2; } ;;
  esac
done
[ -n "$ID" ] || { echo "usage: fm-stack-sync.sh <child-id> [--parent-merged]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
META="$STATE/$ID.meta"

[ -f "$META" ] || { echo "error: no meta at $META" >&2; exit 1; }

meta_value() { grep "^$1=" "$META" | tail -1 | cut -d= -f2- || true; }
set_meta() {
  local k=$1 v=$2 tmp; tmp=$(mktemp)
  if grep -q "^$k=" "$META"; then sed "s#^$k=.*#$k=$v#" "$META" > "$tmp"; else cp "$META" "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"; fi
  mv "$tmp" "$META"
}
del_meta() { local tmp; tmp=$(mktemp); grep -v "^$1=" "$META" > "$tmp" || true; mv "$tmp" "$META"; }

WT=$(meta_value worktree)
PARENT=$(meta_value parent)
PARENT_TIP=$(meta_value parent_tip)
PARENT_BRANCH=$(meta_value parent_branch)
PR=$(meta_value pr)
CHILD_BRANCH="fm/$ID"
[ -n "$PARENT_BRANCH" ] || PARENT_BRANCH="fm/$PARENT"

if [ -z "$PARENT" ]; then echo "no parent recorded for $ID; nothing to sync"; exit 0; fi
[ -n "$WT" ] && [ -d "$WT" ] || { echo "error: worktree for $ID missing ($WT)" >&2; exit 1; }
[ -n "$PARENT_TIP" ] || { echo "error: no parent_tip recorded for $ID" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$WT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then echo "${ref#origin/}"; return 0; fi
  for branch in main master; do
    if git -C "$WT" show-ref --verify --quiet "refs/heads/$branch"; then echo "$branch"; return 0; fi
  done
  return 1
}
DEFAULT=${FM_STACK_BASE:-$(default_branch || echo main)}

conflict_stop() {
  git -C "$WT" rebase --abort 2>/dev/null || true
  echo "error: rebase of $CHILD_BRANCH hit conflicts and was aborted." >&2
  echo "  resolve in the worktree, then re-run this sync:" >&2
  echo "    cd $WT && git rebase --onto $1 $2 $CHILD_BRANCH   # fix conflicts, git rebase --continue" >&2
  exit 1
}

if [ "$MERGED" = 1 ]; then
  # Parent merged: replay child-only commits onto the default branch, dropping the
  # now-landed parent commits. Uses the recorded tip, so a squash-merge is fine.
  if git -C "$WT" rebase --onto "$DEFAULT" "$PARENT_TIP" "$CHILD_BRANCH"; then
    if [ -n "$PR" ] && command -v gh-axi >/dev/null 2>&1; then
      ( cd "$WT" && gh-axi pr edit "$PR" --base "$DEFAULT" ) >/dev/null 2>&1 || echo "warn: could not retarget PR base to $DEFAULT (do it manually)" >&2
    fi
    del_meta parent; del_meta parent_tip; del_meta parent_branch
    echo "restacked $CHILD_BRANCH onto $DEFAULT (parent $PARENT merged); parent linkage cleared"
  else
    conflict_stop "$DEFAULT" "$PARENT_TIP"
  fi
  exit 0
fi

# Parent still open: restack onto its current tip only if it advanced.
git -C "$WT" show-ref --verify --quiet "refs/heads/$PARENT_BRANCH" || { echo "error: parent branch $PARENT_BRANCH not found" >&2; exit 1; }
NEWTIP=$(git -C "$WT" rev-parse "$PARENT_BRANCH")
if [ "$NEWTIP" = "$PARENT_TIP" ]; then
  echo "$CHILD_BRANCH up to date; parent $PARENT tip unchanged"
  exit 0
fi
if git -C "$WT" rebase --onto "$PARENT_BRANCH" "$PARENT_TIP" "$CHILD_BRANCH"; then
  set_meta parent_tip "$NEWTIP"
  echo "restacked $CHILD_BRANCH onto parent $PARENT new tip ${NEWTIP:0:12}; parent_tip updated"
else
  conflict_stop "$PARENT_BRANCH" "$PARENT_TIP"
fi
