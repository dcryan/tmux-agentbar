#!/usr/bin/env bash
# cmux-usage-sentinels.sh — paint per-org Claude usage into the cmux custom sidebar.
#
# This is the ONLY cmux-aware piece. A cmux custom sidebar can't read files or the
# network — only a workspace's .title reaches it — so each org's usage rides two
# hidden "sentinel" workspaces whose titles this script overwrites. For each
# orgs/<org>/usage.json it ensures a 5h + 7d sentinel pair exists (auto-creating any
# that are missing) and repaints their titles. usage.swift filters titles by the
# "◈ " prefix into a top USAGE panel and hides them from the workspace list.
#
# Requires cmux running with automation.socketControlMode=automation (see cmux.json).
# Re-resolves sentinels by title every run (cmux dropped stable workspace UUIDs, so
# positional refs rotate across restarts) — restart-proof and idempotent.
set -uo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/agentbar"
MARK="◈"

command -v cmux >/dev/null 2>&1 || { echo "cmux-usage-sentinels: cmux not found" >&2; exit 0; }
cmux ping >/dev/null 2>&1        || { echo "cmux-usage-sentinels: cmux not running" >&2; exit 0; }

# Resolve a sentinel ref by exact title OR title-prefix (the anchor the sidebar shares).
resolve_ref() { # $1 = prefix, e.g. "◈ PERSONAL · 5h"
  cmux workspace list --json 2>/dev/null \
    | jq -r --arg p "$1" '.workspaces[] | select(.title == $p or (.title | startswith($p))) | .ref' 2>/dev/null \
    | head -1
}

# Ensure a sentinel exists for a title prefix; create (idle, unfocused) if missing. Echoes ref.
ensure_sentinel() { # $1 = bootstrap title / match prefix
  local ref
  ref=$(resolve_ref "$1")
  if [ -z "$ref" ]; then
    cmux new-workspace --name "$1" --command "exec sleep 2147483647" --focus false >/dev/null 2>&1
    ref=$(resolve_ref "$1")
  fi
  printf '%s' "$ref"
}

paint() { # $1 = match prefix  $2 = full new title
  local ref; ref=$(ensure_sentinel "$1")
  [ -n "$ref" ] || { echo "cmux-usage-sentinels: could not resolve/create sentinel '$1'" >&2; return 1; }
  cmux rename-workspace --workspace "$ref" "$2" >/dev/null 2>&1 \
    || echo "cmux-usage-sentinels: rename rejected for '$1' (set socketControlMode=automation + restart cmux)" >&2
}

shopt -s nullglob
found=0
for f in "$STATE"/orgs/*/usage.json; do
  found=1
  label=$(jq -r '.label // "CLAUDE"' "$f")
  fhp=$(jq -r '.five_hour.pct // 0' "$f");  fhs=$(jq -r '.five_hour.spark // " "' "$f");  fhr=$(jq -r '.five_hour.resets_in // "?"' "$f")
  shp=$(jq -r '.seven_day.pct // 0' "$f");  shs=$(jq -r '.seven_day.spark // " "' "$f");  shr=$(jq -r '.seven_day.resets_in // "?"' "$f")
  stale=$(jq -r '.stale // false' "$f"); suffix=""; [ "$stale" = true ] && suffix=" ⚠"
  paint "$MARK $label · 5h" "$MARK $label · 5h $fhs ${fhp}% $fhr$suffix"
  paint "$MARK $label · 7d" "$MARK $label · 7d $shs ${shp}% $shr$suffix"
done
[ "$found" = 1 ] || echo "cmux-usage-sentinels: no usage data yet (run claude-usage.sh --refresh)" >&2
