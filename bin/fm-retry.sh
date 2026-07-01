#!/usr/bin/env bash
# fm-retry.sh - bounded retry counter for firstmate's revise / re-steer loops.
#
# When firstmate re-steers a crewmate to fix named blockers (a failed gate, review
# findings, a flaky step), the fix should be IN PLACE - feed back the specific
# blockers and have the crewmate fix only those, never regenerate from scratch -
# and the loop must be BOUNDED so a thrashing gate escalates to the captain instead
# of spinning forever. This helper is the bound: a per-(task, gate) counter.
#
#   fm-retry.sh <id> <gate>            Bump the gate's counter. Exit 0 while within
#                                      the cap ("retry N/MAX"); exit 3 once it is
#                                      exceeded ("escalate ...") - the signal to stop
#                                      re-steering and raise a needs-decision.
#   fm-retry.sh <id> <gate> --max N    Override the cap (default FM_GATE_RETRY_MAX=3;
#                                      use 2 for a lighter revise cap, etc.).
#   fm-retry.sh <id> <gate> --reset    Clear the gate's counter (call on a pass).
#   fm-retry.sh <id> <gate> --peek     Print the current count without bumping.
#
# State lives in $FM_HOME/state/<id>.retry as `gate=count` lines; counters for
# different gates and different tasks are independent. When there is no gate to
# fail (a delivery mode with no pipeline/CI), nothing calls this - it is inert.
# Pure bash; no dependencies.
set -eu

usage() { echo "usage: fm-retry.sh <id> <gate> [--max N] [--reset|--peek]" >&2; exit 2; }

ID=""; GATE=""; MAX=${FM_GATE_RETRY_MAX:-3}; MODE=bump
while [ $# -gt 0 ]; do
  case "$1" in
    --max) shift; MAX=${1:-}; [ -n "$MAX" ] || usage ;;
    --reset) MODE=reset ;;
    --peek) MODE=peek ;;
    -*) usage ;;
    *) if [ -z "$ID" ]; then ID=$1; elif [ -z "$GATE" ]; then GATE=$1; else usage; fi ;;
  esac
  shift
done
[ -n "$ID" ] && [ -n "$GATE" ] || usage
case "$MAX" in *[!0-9]*|"") echo "error: --max must be a positive integer" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RETRY="$STATE/$ID.retry"

get_count() { [ -f "$RETRY" ] && grep "^$GATE=" "$RETRY" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
set_count() {
  local v=$1 tmp; mkdir -p "$STATE"; tmp=$(mktemp)
  if [ -f "$RETRY" ] && grep -q "^$GATE=" "$RETRY"; then sed "s#^$GATE=.*#$GATE=$v#" "$RETRY" > "$tmp"
  else [ -f "$RETRY" ] && cp "$RETRY" "$tmp" || : > "$tmp"; printf '%s=%s\n' "$GATE" "$v" >> "$tmp"; fi
  mv "$tmp" "$RETRY"
}

cur=$(get_count); [ -n "$cur" ] || cur=0

case "$MODE" in
  peek)
    echo "$cur"; exit 0 ;;
  reset)
    if [ -f "$RETRY" ]; then tmp=$(mktemp); grep -v "^$GATE=" "$RETRY" > "$tmp" || true; mv "$tmp" "$RETRY"; fi
    echo "reset $ID gate '$GATE'"; exit 0 ;;
  bump)
    n=$((cur + 1)); set_count "$n"
    if [ "$n" -gt "$MAX" ]; then
      echo "escalate: gate '$GATE' exceeded $MAX revise rounds for $ID - stop re-steering and raise a needs-decision"
      exit 3
    fi
    echo "retry $n/$MAX for $ID gate '$GATE'"; exit 0 ;;
esac
