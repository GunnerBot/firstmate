# shellcheck shell=bash
# Shared codebase-memory-mcp (cmm) pinned-version probe for bootstrap and
# graph health.
# Usage: . bin/fm-cmm-lib.sh
#
# cmm is a single static binary, not a versioned package feed; the pin is an
# exact match on the one validated version, not a minimum. Any other version
# counts as missing so blast-radius queries never run against an unvalidated
# graph engine. Every cmm invocation prints "level=info ..." noise to stderr
# first, so version parsing strips those lines.

FM_CMM_PIN=0.8.1

fm_cmm_version() {
  command -v codebase-memory-mcp >/dev/null 2>&1 || return 1
  codebase-memory-mcp --version 2>&1 | grep -v '^level=info' | awk '{print $NF}' | head -1
}

fm_cmm_compatible() {
  local v
  v=$(fm_cmm_version) || return 1
  [ "$v" = "$FM_CMM_PIN" ]
}
