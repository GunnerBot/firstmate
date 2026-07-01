#!/usr/bin/env bash
# Best-effort detection of a repo's toolchain (language, build/test/run commands,
# source root), emitted as a markdown block for inclusion in a crewmate ship brief.
#
# This is ENRICHMENT, never a gate. Detection is pure file inspection: it never
# runs a build and never requires any tool to be installed. When nothing is
# recognized - an unknown stack, a docs/config repo, or a missing clone - it emits
# a clear "not auto-detected" block telling the crewmate to fall back to the
# project's own AGENTS.md/README or ask, so the crewmate's native flow is unchanged
# either way. It always exits 0; a detection miss is never an error.
#
# Precedence: if <repo>/framework.md exists (a project-committed toolchain
# description), it wins verbatim over detection - the project's own word beats a guess.
#
# Usage: fm-framework-detect.sh <repo-path>
set -eu

REPO=${1:?usage: fm-framework-detect.sh <repo-path>}

emit() { printf '%s\n' "$@"; }
have() { [ -f "$REPO/$1" ]; }

# A project-committed framework.md is authoritative - prefer it verbatim.
if [ -f "$REPO/framework.md" ]; then
  cat "$REPO/framework.md"
  exit 0
fi

lang="" build="" test="" run="" src=""

if have package.json; then
  lang="JavaScript/TypeScript"
  if have tsconfig.json; then lang="TypeScript"; fi
  if have pnpm-lock.yaml; then pm=pnpm; elif have yarn.lock; then pm=yarn; else pm=npm; fi
  build="$pm install"; test="$pm test"; run="$pm start"
  if [ -d "$REPO/src" ]; then src="src/"; fi
elif have pyproject.toml || have setup.py || have requirements.txt; then
  lang="Python"
  if have uv.lock; then build="uv sync"; test="uv run pytest"
  elif have poetry.lock; then build="poetry install"; test="poetry run pytest"
  else build="pip install -e ."; test="pytest"; fi
  run="python -m <module>"
  for d in src app; do if [ -d "$REPO/$d" ]; then src="$d/"; break; fi; done
elif have go.mod; then
  lang="Go"; build="go build ./..."; test="go test ./..."; run="go run ."
elif have Cargo.toml; then
  lang="Rust"; build="cargo build"; test="cargo test"; run="cargo run"; src="src/"
elif have pom.xml; then
  lang="Java (Maven)"; build="mvn -q compile"; test="mvn -q test"; run="mvn -q spring-boot:run"; src="src/main/java/"
elif have build.gradle || have build.gradle.kts; then
  lang="Java/Kotlin (Gradle)"; build="./gradlew build"; test="./gradlew test"; run="./gradlew run"; src="src/main/"
elif have Gemfile; then
  lang="Ruby"; build="bundle install"; test="bundle exec rake test"; run="bundle exec ruby <entrypoint>"
fi

if [ -z "$lang" ]; then
  emit "**Repo toolchain:** not auto-detected." \
       "Use the project's \`AGENTS.md\`/\`README\` or infer the build/test/run commands from the repo itself. If they stay unclear, append \`needs-decision\` and ask - do not guess a build system."
  exit 0
fi

emit "**Repo toolchain** (best-effort auto-detection - verify against the repo before relying on it):" \
     "- language: $lang" \
     "- build: \`$build\`" \
     "- test: \`$test\`" \
     "- run: \`$run\`"
if [ -n "$src" ]; then emit "- source root: \`$src\`"; fi
exit 0
