#!/usr/bin/env bash
# Behavior tests for fm-framework-detect.sh.
#
# Detection is pure file inspection and best-effort: a recognized repo yields a
# toolchain block naming build/test/run commands; an unrecognized one (or a
# missing clone) yields the explicit "not auto-detected" fallback and still exits
# 0, because a detection miss must never break brief scaffolding. A
# project-committed framework.md wins verbatim over detection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DETECT="$ROOT/bin/fm-framework-detect.sh"
TMP=$(fm_test_tmproot fm-framework-detect-tests)

# TypeScript + pnpm + src/
d="$TMP/ts"; mkdir -p "$d/src"; : > "$d/package.json"; : > "$d/tsconfig.json"; : > "$d/pnpm-lock.yaml"
out=$("$DETECT" "$d")
assert_contains "$out" "language: TypeScript" "TypeScript detected"
assert_contains "$out" "pnpm test" "pnpm test command chosen from lockfile"
assert_contains "$out" "source root: \`src/\`" "src/ reported as source root"
assert_contains "$out" "tsguide.html" "TypeScript -> Google TS style guide URL"

# Python + uv
d="$TMP/py"; mkdir -p "$d"; : > "$d/pyproject.toml"; : > "$d/uv.lock"
out=$("$DETECT" "$d")
assert_contains "$out" "language: Python" "Python detected"
assert_contains "$out" "uv run pytest" "uv test command chosen from lockfile"
assert_contains "$out" "pyguide.html" "Python -> Google Python style guide URL"

# Go
d="$TMP/go"; mkdir -p "$d"; : > "$d/go.mod"
out=$("$DETECT" "$d")
assert_contains "$out" "language: Go" "Go detected"
assert_contains "$out" "go test ./..." "go test command"
assert_contains "$out" "styleguide/go" "Go -> Google Go style guide URL"

# Rust (no dedicated Google style guide -> explicit fallback line)
d="$TMP/rs"; mkdir -p "$d"; : > "$d/Cargo.toml"
out=$("$DETECT" "$d")
assert_contains "$out" "language: Rust" "Rust detected"
assert_contains "$out" "no dedicated Google guide for Rust" "Rust -> no-Google-guide fallback"

# Java (Maven)
d="$TMP/jv"; mkdir -p "$d"; : > "$d/pom.xml"
out=$("$DETECT" "$d")
assert_contains "$out" "Maven" "Maven detected"
assert_contains "$out" "mvn -q test" "mvn test command"
assert_contains "$out" "javaguide.html" "Java -> Google Java style guide URL"

# Unknown stack -> graceful fallback that tells the crewmate to ask
d="$TMP/unknown"; mkdir -p "$d"; : > "$d/notes.txt"
out=$("$DETECT" "$d")
assert_contains "$out" "not auto-detected" "unknown stack -> fallback block"
assert_contains "$out" "needs-decision" "fallback points crewmate at needs-decision"
assert_contains "$out" "google.github.io/styleguide" "fallback still points at the Google style guide index"

# Missing clone -> graceful, exit 0, fallback block (never breaks scaffolding)
out=$("$DETECT" "$TMP/does-not-exist"); rc=$?
expect_code 0 "$rc" "missing path exits 0"
assert_contains "$out" "not auto-detected" "missing path -> fallback block"

# Project-committed framework.md wins verbatim over detection
d="$TMP/committed"; mkdir -p "$d"; : > "$d/go.mod"; printf 'CUSTOM TOOLCHAIN DOC\n' > "$d/framework.md"
out=$("$DETECT" "$d")
assert_contains "$out" "CUSTOM TOOLCHAIN DOC" "committed framework.md emitted verbatim"
assert_not_contains "$out" "language: Go" "committed framework.md wins over detection"

pass "fm-framework-detect: detection across stacks, graceful fallback, committed-file precedence"
