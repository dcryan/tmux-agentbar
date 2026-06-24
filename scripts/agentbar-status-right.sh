#!/usr/bin/env bash
# agentbar-status-right.sh <session_id> <window_index>
#
# Emits a tmux status-right segment for the session's ACTIVE window: the Claude org
# badge (colored per account) + 5h/7d usage, read from the shared cache that
# claude-usage.sh writes. Because tmux expands #{session_id}/#{window_index} in
# status-right against the active window, the segment tracks whatever account the
# focused tab is using. Cheap (file reads only) — safe at status-interval 1.
#
# Prints nothing until a session stamps its account (agentbar-report.sh) and usage is
# cached. Output uses tmux style escapes (#[fg=...]) which tmux interprets from #().
set -uo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/agentbar"
sid="${1:-}"; win="${2:-}"
[ -n "$sid" ] && [ -n "$win" ] || exit 0

# per-window state file (line 1 = status, line 2 = accountUuid) — same path agentbar-report.sh writes
statefile="${TMPDIR:-/tmp}/tmux-agentbar/${sid}/win-${win}"
[ -f "$statefile" ] || exit 0
acct=$(sed -n '2p' "$statefile" 2>/dev/null)
[ -n "$acct" ] || exit 0

meta="$STATE/accounts/$acct/meta.json"
[ -f "$meta" ] || exit 0
org=$(jq -r '.organizationUuid // empty' "$meta" 2>/dev/null)
[ -n "$org" ] || exit 0

color=$(cat "$STATE/orgs/$org/color" 2>/dev/null || jq -r '.color // "colour4"' "$meta")
label=$(cat "$STATE/orgs/$org/label" 2>/dev/null || jq -r '.organizationName // "CLAUDE"' "$meta")

usage="$STATE/orgs/$org/usage.json"
if [ -f "$usage" ]; then
  fhp=$(jq -r '.five_hour.pct // 0' "$usage"); fhs=$(jq -r '.five_hour.spark // " "' "$usage")
  shp=$(jq -r '.seven_day.pct // 0' "$usage"); shs=$(jq -r '.seven_day.spark // " "' "$usage")
  warn=""; [ "$(jq -r '.stale // false' "$usage")" = true ] && warn=" #[fg=colour1]⚠#[default]"
  printf '#[fg=%s]%s#[default] 5h %s %s%% · 7d %s %s%%%s ' "$color" "$label" "$fhs" "$fhp" "$shs" "$shp" "$warn"
else
  printf '#[fg=%s]%s#[default] ' "$color" "$label"
fi
