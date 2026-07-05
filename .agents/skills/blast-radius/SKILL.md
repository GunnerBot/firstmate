---
name: blast-radius
description: Agent-only impact-analysis playbook for ship tasks. Before changing code, scope the blast radius of the symbols you will touch (graph union grep, never graph alone); after implementing, verify the diff's real reach and test coverage. Java repos use the cmm code knowledge graph; every other stack runs the same steps grep-only. Crewmates load this from the path given in their brief.
user-invocable: false
---

# Blast Radius

Impact analysis for a change: who calls what you are about to touch, how far the
change reaches, and which tests cover it. Run SCOPE before you write code and
VERIFY after, both from the repo root of your worktree.

Engine: `codebase-memory-mcp` (cmm) for Java repos. Every cmm call prints
`level=info ...` noise to stderr, so pipe through `grep -v '^level=info'`
before parsing JSON, and send each `query_graph` payload as a single line or
cmm rejects it with `query is required`.

## Step 0 - graph health (always first)

```sh
<FM_ROOT>/bin/fm-graph-health.sh . --index
```

`<FM_ROOT>` is the firstmate root named in your brief.

- `HEALTHY` - use graph union grep below.
- `N/A` (no Java) - run every step grep-only; that is complete for this repo, not degraded.
- `MISSING`/`STALE` that `--index` could not heal - report it in your status, then proceed grep-only.
  Never present grep-only results from a repo that expected a graph as exhaustive.

A silent false negative ("no impact") from a stale or missing graph is the worst
failure mode; naming the mode you ran in costs one line.

## SCOPE (before implementing)

1. **Targets.** List the symbols (functions, methods, classes, scripts) your change will touch.
2. **Callers, graph half** (Java + HEALTHY only). Reverse callers per target, depth capped at 2; the confidence filter is mandatory (unfiltered CALLS edges are mostly suffix-match noise):

```sh
codebase-memory-mcp cli query_graph '{"project":"<SLUG>","query":"MATCH (caller)-[r:CALLS]->(t:Method {name:\"<target>\"}) WHERE r.confidence >= 0.5 RETURN caller.qualified_name AS caller, caller.file_path AS file LIMIT 200"}' 2>&1 | grep -v '^level=info'
```

3. **Callers, grep half** (ALWAYS, even when the graph returned results - the graph misses method references, reflective dispatch, event indirection, and everything non-Java):

```sh
grep -rn --exclude-dir=.git --exclude-dir=target --exclude-dir=node_modules -E "\b<target>\b" .
```

   Drop the target's own definition and comment-only hits; when unsure, keep the hit.
   For shell repos, also sweep sourcing and invocation: `grep -rn "<script-name>" .` catches `. lib.sh`, `"$SCRIPT_DIR/tool.sh"`, and tmux/send-keys indirection.

4. **Union and tag** each caller `graph`/`grep`/`both`. Grep-only hits are the graph's blind spots; never drop them.
5. **Covering tests.** Any union caller under a test tree (`src/test/java`, `tests/`, `*Test.java`, `*.test.sh`, `*_test.*`) is a covering test. Flag every target with none as `NO COVERING TESTS`.
6. **Noise rule.** A target with more than 50 direct callers is a high-fan-in boundary: report per-module counts instead of call sites.
7. **Record** the scope as an "Impact scope" section in your working notes and reflect it in your status line before implementing, for example `working: impact scope 3 targets, 14 callers, 2 uncovered`.

## VERIFY (after implementing, before done)

1. Diff your branch against its base and map changed hunks to changed symbols.
2. Re-run SCOPE steps 2-5 for the changed symbols, then subtract everything inside your own diff: what remains is the out-of-diff blast radius - callers whose behavior you changed without touching them.
3. Every out-of-diff caller must be either covered by a test you ran or explicitly listed as reviewed-safe in your report; a changed symbol with zero covering tests must be named in your status or PR body, never silently shipped.
4. Include the result as an "Impact" section in the PR body or scout report:

```md
## Impact
Targets changed: <n>  Out-of-diff callers: <n>  Uncovered: <list or none>
Mode: graph+grep | grep-only (<reason>)
```

Detection only: this playbook never edits production code by itself.
