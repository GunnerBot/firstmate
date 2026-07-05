#!/usr/bin/env bash
# fm-graph-health.sh - blast-radius graph (cmm) health for one project repo.
#
# Usage: fm-graph-health.sh <repo-path> [--index]
#
# Prints exactly one status line and exits:
#   GRAPH HEALTH: N/A (...)       no tracked *.java; graph impact does not
#                                 apply, impact scans are grep-only (exit 0)
#   GRAPH HEALTH: HEALTHY (...)   exit 0
#   GRAPH HEALTH: MISSING - ...   exit 1 for the tool, exit 2 for the index
#   GRAPH HEALTH: STALE - ...     exit 2
#
# --index: when the failure is a missing or stale INDEX, run the (re)index
# inline (incremental, a few seconds) and re-report. A missing or unpinned
# TOOL is never auto-fixed, because installs are consent-gated through
# fm-bootstrap.sh.
#
# The cmm graph engine covers Java today, so a repo with no tracked *.java is
# N/A by design, not an error. Freshness requires the index DB to be newer
# than BOTH the last commit (covers pulls of committed changes) and the
# newest modified working-tree *.java (covers uncommitted edits). The DB
# lives at ~/.cache/codebase-memory-mcp/<slug>.db; FM_CMM_CACHE_OVERRIDE
# points tests at a fake cache. A silent false negative ("no impact" from a
# missing or stale graph) is the worst blast-radius failure mode - never
# treat a non-HEALTHY status as ignorable when a graph is expected.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-cmm-lib.sh
. "$SCRIPT_DIR/fm-cmm-lib.sh"

REPO=""
DO_INDEX=0
for a in "$@"; do
  case "$a" in
    --index) DO_INDEX=1 ;;
    -*) echo "usage: fm-graph-health.sh <repo-path> [--index]" >&2; exit 2 ;;
    *)
      if [ -z "$REPO" ]; then
        REPO=$a
      else
        echo "usage: fm-graph-health.sh <repo-path> [--index]" >&2; exit 2
      fi
      ;;
  esac
done
[ -n "$REPO" ] || { echo "usage: fm-graph-health.sh <repo-path> [--index]" >&2; exit 2; }
[ -d "$REPO" ] || { echo "error: no such directory: $REPO" >&2; exit 2; }
ROOT=$(cd "$REPO" && git rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: not a git repository: $REPO" >&2; exit 2
}

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# Gate 0 - applicability: the graph engine indexes Java.
if ! git -C "$ROOT" ls-files -- '*.java' | head -1 | grep -q .; then
  echo "GRAPH HEALTH: N/A (no tracked *.java in $ROOT; impact scans are grep-only)"
  exit 0
fi

# Gate 1 - tool installed and pinned.
if ! fm_cmm_compatible; then
  ver=$(fm_cmm_version) || ver=absent
  echo "GRAPH HEALTH: MISSING - cmm $ver, pinned $FM_CMM_PIN; approve and run: bin/fm-bootstrap.sh install codebase-memory-mcp"
  exit 1
fi

# Every cmm call prints level=info noise to stderr before answering.
cmm_json() { codebase-memory-mcp cli "$@" 2>&1 | grep -v '^level=info'; }

slug_for_root() {
  cmm_json list_projects '{}' |
    jq -r --arg r "$ROOT" \
      '(if type == "object" then (.projects // []) else . end) | .[] | select(.root_path == $r) | .name' \
      2>/dev/null | head -1
}

reindex() {
  codebase-memory-mcp cli index_repository "{\"repo_path\":\"$ROOT\"}" >/dev/null 2>&1
}

INDEX_CMD="codebase-memory-mcp cli index_repository '{\"repo_path\":\"$ROOT\"}'"

# Gate 2 - repo is indexed (match by root_path, never by guessing the slug).
SLUG=$(slug_for_root)
if [ -z "$SLUG" ] && [ "$DO_INDEX" = 1 ]; then
  reindex && SLUG=$(slug_for_root)
fi
if [ -z "$SLUG" ]; then
  echo "GRAPH HEALTH: MISSING - repo not indexed; run: $INDEX_CMD"
  exit 2
fi

# Gate 3 - index is fresh: DB newer than the last commit AND the newest
# modified working-tree *.java.
CACHE="${FM_CMM_CACHE_OVERRIDE:-$HOME/.cache/codebase-memory-mcp}"
DB="$CACHE/$SLUG.db"
DB_MTIME=$(mtime "$DB") || DB_MTIME=0
if [ "$DB_MTIME" = 0 ]; then
  if [ "$DO_INDEX" = 1 ] && reindex; then
    DB_MTIME=$(mtime "$DB") || DB_MTIME=0
  fi
  if [ "$DB_MTIME" = 0 ]; then
    echo "GRAPH HEALTH: MISSING - index DB gone ($DB); run: $INDEX_CMD"
    exit 2
  fi
fi
LAST_COMMIT=$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null) || LAST_COMMIT=0
NEWEST=$LAST_COMMIT
while IFS= read -r f; do
  m=$(mtime "$ROOT/$f") || continue
  [ "$m" -gt "$NEWEST" ] && NEWEST=$m
done < <(git -C "$ROOT" ls-files -m -- '*.java')
if [ "$NEWEST" -gt "$DB_MTIME" ]; then
  if [ "$DO_INDEX" = 1 ] && reindex; then
    echo "GRAPH HEALTH: HEALTHY (slug=$SLUG, reindexed)"
    exit 0
  fi
  echo "GRAPH HEALTH: STALE - reindex: $INDEX_CMD"
  exit 2
fi
echo "GRAPH HEALTH: HEALTHY (slug=$SLUG)"
exit 0
