#!/usr/bin/env bash
# Exercises the CLI against a throwaway config and a fake Chrome "Local State".
set -euo pipefail
BIN="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CHROME_ROUTER_CONFIG="$TMP/config.json"
export CHROME_ROUTER_LOCAL_STATE="$HERE/local-state.json"

pass=0; fail=0
expect() { # expect <description> <needle> <cmd...>
  local desc="$1" needle="$2"; shift 2
  local out; out="$("$@" 2>&1 || true)"
  if [[ "$out" == *"$needle"* ]]; then pass=$((pass+1)); else
    fail=$((fail+1)); printf 'FAIL: %s\n  wanted: %s\n  got:    %s\n' "$desc" "$needle" "$out"; fi
}

expect "profiles lists names"     "Side Project"       "$BIN" profiles
expect "no config → browser default" "last-used profile" "$BIN" test https://example.com

"$BIN" default Personal >/dev/null
"$BIN" add '*.company.com' Work >/dev/null
"$BIN" add 'github.com/company-org' 'me@company.com' >/dev/null
"$BIN" add '^https://docs\.google\.com/.*/d/side-' 'Profile 2' --regex >/dev/null
"$BIN" add Work --from Slack >/dev/null
"$BIN" add 'notion.so' Work --from com.tinyspeck.slackmacgap --at 1 >/dev/null

expect "subdomain glob"           "Work [Profile 1"    "$BIN" test https://jira.company.com/browse/X-1
expect "apex matches *.domain"    "Work [Profile 1"    "$BIN" test https://company.com
expect "lookalike domain"         "Personal [Default"  "$BIN" test https://evilcompany.com
expect "path prefix"              "Work [Profile 1"    "$BIN" test https://github.com/company-org/repo/pull/1
expect "path prefix exact"        "Work [Profile 1"    "$BIN" test github.com/company-org
expect "path prefix not sibling"  "Personal [Default"  "$BIN" test https://github.com/company-org-fork
expect "path prefix + query"     "Work [Profile 1"    "$BIN" test "https://github.com/company-org?tab=repos"
expect "other github → default"   "via default"        "$BIN" test https://github.com/torvalds/linux
expect "regex"                    "Side Project"       "$BIN" test 'https://docs.google.com/document/d/side-abc/edit'
expect "from app by name"         "via rule #5"        "$BIN" test https://random.dev --from slack
expect "from + match by bundle id" "via rule #1"       "$BIN" test https://notion.so/x --from com.tinyspeck.slackmacgap
expect "match without from fails"  "via default"       "$BIN" test https://notion.so
expect "rules listing"            "5. from Slack"      "$BIN" rules
expect "unknown profile warns"    "warning: no profile" "$BIN" add x.com Nope
"$BIN" remove 6 >/dev/null
expect "move"                     "1. match *.company.com" "$BIN" move 2 1
expect "bad rule number"          "not a valid rule number" "$BIN" remove 99
expect "bad regex rejected"       "error"              "$BIN" add '(' Work --regex
expect "unknown browser"          "unknown browser"    "$BIN" browser netscape
expect "brave alias"              "com.brave.Browser"  "$BIN" browser brave

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
