#!/usr/bin/env bash
# fm-dag.sh - width-optimized DAG planner over data/backlog.md.
#
# firstmate already runs crewmates in parallel; this makes the PLANNING exploit it.
# It reads the backlog's Queued / In flight / Done sections and the `blocked-by:`
# dependencies, and reports the parallel structure of the remaining work so
# firstmate dispatches the whole ready frontier at once instead of one task at a
# time - the fix for serial slowness.
#
# Commands:
#   fm-dag.sh ready [backlog]  Print ids dispatchable NOW - every blocker already
#                              Done (not queued, not in flight) - one per line.
#                              This is the parallel frontier to spawn together.
#   fm-dag.sh plan  [backlog]  Human report: ready/blocked/in-flight counts, the
#                              wave schedule (max parallel WIDTH vs serial DEPTH),
#                              and scope-overlap warnings for nodes that would run
#                              in the same wave but touch overlapping files.
#
# Optional per-node file scope: a `scope: <path|glob> ...` annotation on the
# backlog line (space- or comma-separated), placed AFTER any `blocked-by:` clause.
# When present, overlap within a wave is flagged: those nodes are mutually
# independent, so if their file scopes intersect they must be serialized (add a
# blocked-by) or they collide when run in parallel. Scope is optional; without it
# the planner still computes the frontier and width, it just cannot check overlap.
#
# The plan simulation treats In flight nodes as "will complete", so a queued node
# blocked only by in-flight work appears in the wave schedule (structure) but NOT
# in `ready` (dispatch-now). Unknown blocker ids (neither queued nor in flight -
# e.g. a Done entry pruned from the kept-10) count as satisfied.
#
# backlog defaults to $FM_HOME/data/backlog.md. Pure awk/bash: no jq, no tasks-axi.
set -eu

CMD=${1:-plan}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BACKLOG=${2:-$DATA/backlog.md}

case "$CMD" in
  ready|plan) ;;
  *) echo "usage: fm-dag.sh <ready|plan> [backlog.md]" >&2; exit 2 ;;
esac

if [ ! -f "$BACKLOG" ]; then
  echo "warn: no backlog at $BACKLOG" >&2
  exit 0
fi

awk -v mode="$CMD" -v bl="$BACKLOG" '
function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
function idof(line,   s){
  s=line
  sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*/,"",s)  # "- [ ] " / "- [x] "
  sub(/^[[:space:]]*-[[:space:]]*/,"",s)                       # bare "- " (bold form)
  gsub(/\*\*/,"",s)                                            # bold markers
  sub(/[[:space:]].*/,"",s)                                    # keep first token
  return s
}
function blockersof(line,   b){
  if (line !~ /blocked-by:/) return ""
  b=line; sub(/.*blocked-by:[[:space:]]*/,"",b)
  sub(/[[:space:]]+-[[:space:]].*/,"",b)   # drop " - reason"
  sub(/[[:space:]]*scope:.*/,"",b)         # drop a trailing scope: clause
  gsub(/,/," ",b); return trim(b)
}
function scopeof(line,   s){
  if (line !~ /scope:/) return ""
  s=line; sub(/.*scope:[[:space:]]*/,"",s)
  sub(/[[:space:]]+-[[:space:]].*/,"",s)
  gsub(/,/," ",s); return trim(s)
}
# scope overlap helpers -------------------------------------------------------
function stem(t){ sub(/\/\*\*$/,"",t); sub(/\/\*$/,"",t); sub(/\*$/,"",t); sub(/\/$/,"",t); return t }
function pathpref(p,q){ return (q==p) || (index(q, p "/")==1) }
function overlap(sa,sb,   na,nb,i,j,A,B,x,y){
  na=split(sa,A," "); nb=split(sb,B," ")
  for(i=1;i<=na;i++){ x=stem(A[i]); if(x=="")continue
    for(j=1;j<=nb;j++){ y=stem(B[j]); if(y=="")continue
      if(x==y || pathpref(x,y) || pathpref(y,x)) return 1 } }
  return 0
}
# simulation: a blocker is satisfied once it is not an unscheduled queued node
function blk_sat_sim(bid){ return !((bid in qseen) && !(bid in scheduled)) }
# dispatch-now: a blocker is satisfied only if it is neither queued nor in flight
function blk_done(bid){ return !((bid in qseen) || (bid in inflight)) }

/^##[[:space:]]+In flight/ { sec="in";   next }
/^##[[:space:]]+Queued/    { sec="q";    next }
/^##[[:space:]]+Done/      { sec="done"; next }
/^##[[:space:]]/           { sec="x";    next }
/^[[:space:]]*-[[:space:]]/ {
  id=idof($0); if(id=="") next
  if(sec=="done")        { done[id]=1 }
  else if(sec=="in")     { if(!(id in inflight)){ inflight[id]=1; ninf++ } }
  else if(sec=="q")      { if(!(id in qseen)){ qseen[id]=1; qids[++nq]=id; qblk[id]=blockersof($0); qscope[id]=scopeof($0); if(qscope[id]!="") anyscope=1 } }
  next
}
END{
  # ready-now frontier (all blockers Done)
  for(k=1;k<=nq;k++){ id=qids[k]; nb=split(qblk[id],B," "); rdy=1
    for(i=1;i<=nb;i++){ if(!blk_done(B[i])){ rdy=0; break } }
    if(rdy){ ready[++nr]=id }
  }
  if(mode=="ready"){ for(i=1;i<=nr;i++) print ready[i]; exit }

  # plan: simulate waves over the queued set (in-flight treated as completing)
  remaining=nq; wave=0; maxw=0
  while(remaining>0){
    fn=0
    for(k=1;k<=nq;k++){ id=qids[k]; if(id in scheduled) continue
      nb=split(qblk[id],B," "); ok=1
      for(i=1;i<=nb;i++){ if(!blk_sat_sim(B[i])){ ok=0; break } }
      if(ok) frontier[++fn]=id
    }
    if(fn==0){ cycle=1; break }
    wave++; wsize[wave]=fn; wlist[wave]=""
    for(i=1;i<=fn;i++){ wlist[wave]=wlist[wave] (i>1?" ":"") frontier[i] }
    for(i=1;i<=fn;i++) for(j=i+1;j<=fn;j++){
      a=frontier[i]; b=frontier[j]
      if(qscope[a]!="" && qscope[b]!="" && overlap(qscope[a],qscope[b]))
        warns[++nw]=sprintf("wave %d: %s and %s have overlapping scope - serialize (add blocked-by) or they collide in parallel", wave, a, b)
    }
    for(i=1;i<=fn;i++){ scheduled[frontier[i]]=1; remaining-- }
    if(fn>maxw) maxw=fn
    delete frontier
  }

  printf "DAG plan (%s):\n", bl
  printf "  queued: %d   ready now: %d   in-flight: %d\n", nq, nr, ninf
  if(cycle){
    stuck=""
    for(k=1;k<=nq;k++){ id=qids[k]; if(!(id in scheduled)) stuck=stuck (stuck==""?"":" ") id }
    printf "  warning: cycle / unresolvable blockers among: %s\n", stuck
  }
  printf "  schedule: %d wave(s), max parallel width %d\n", wave, maxw
  for(w=1;w<=wave;w++) printf "  wave %d (%d parallel): %s\n", w, wsize[w], wlist[w]
  if(nw>0){ for(i=1;i<=nw;i++) printf "  warning: %s\n", warns[i] }
  else if(anyscope) print "  scope: no overlaps within any wave"
  if(wave>1 && maxw==1 && !cycle) print "  note: fully serial (width 1) - consider decomposing into independent, disjoint-scope nodes to parallelize"
}
' "$BACKLOG"
