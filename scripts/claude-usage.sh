#!/usr/bin/env bash
# claude-usage.sh — fetch Claude rate-limit utilization and cache it for any consumer
# (cmux sidebar, tmux-agentbar). ONE writer, many readers.
#
# Data source: Anthropic's unofficial OAuth usage endpoint (the same one `ccusage`
# uses). Returns server-side utilization (0-100) + reset timestamps for the rolling
# 5-hour and 7-day windows. No stable/official API — the `anthropic-beta` header may
# change. The OAuth token is read FRESH from the macOS Keychain each run and is never
# printed or persisted.
#
# Usage is owned by the ORGANIZATION, so the cache is written per-org:
#   ${XDG_STATE_HOME:-~/.local/state}/agentbar/orgs/<organizationUuid>/usage.json
#
# Modes:
#   (none)/--print   human-readable one-liner (live fetch)
#   --json           print the cache JSON for the active org to stdout (live fetch)
#   --raw            print raw API JSON (token NOT included) — debugging
#   --refresh        fetch + atomically write the active org's usage.json (for hooks)
set -uo pipefail

USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"
OAUTH_BETA="oauth-2025-04-20"
KEYCHAIN_SERVICE="Claude Code-credentials"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/agentbar"
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"   # the config DIR (for .credentials.json fallback)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "claude-usage: $*" >&2; exit 1; }

# The .claude.json login file lives at ~/.claude.json (home root) by default, or under
# CLAUDE_CONFIG_DIR when set — NOT inside ~/.claude/. Keep this in sync with claude-account.sh.
_resolve_claude_json() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then echo "$CLAUDE_CONFIG_DIR/.claude.json"; return; fi
  local c
  for c in "$HOME/.claude.json" "$HOME/.claude/.claude.json"; do
    [ -f "$c" ] && { echo "$c"; return; }
  done
  echo "$HOME/.claude.json"
}
CLAUDE_JSON="$(_resolve_claude_json)"

org_id()    { jq -r '.oauthAccount.organizationUuid // empty' "$CLAUDE_JSON" 2>/dev/null; }
org_label() { "$HERE/claude-account.sh" label 2>/dev/null || echo CLAUDE; }

# Read the OAuth access token: Keychain first (macOS), then a file fallback (Linux/
# Windows, or a CLAUDE_CONFIG_DIR profile). Never echoed.
read_token() {
  local raw tok
  if raw=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) && [ -n "$raw" ]; then :
  elif [ -f "$CONFIG_DIR/.credentials.json" ]; then raw=$(cat "$CONFIG_DIR/.credentials.json")
  else return 1; fi
  tok=$(printf '%s' "$raw" | jq -r '.claudeAiOauth.accessToken // .accessToken // empty' 2>/dev/null)
  [ -n "$tok" ] && printf '%s' "$tok"
}

fetch() {
  curl -fsS --max-time 15 "$USAGE_ENDPOINT" \
    -H "Authorization: Bearer $1" \
    -H "anthropic-beta: $OAUTH_BETA" \
    -H "Content-Type: application/json"
}

# --- parsing helpers (jq-sanitized: untrusted API text never reaches the shell) ---

# clamp to integer percent 0..100; null/non-numeric → 0
to_pct() { jq -rn --arg v "${1:-}" '(($v|tonumber?)//0)|if .<0 then 0 elif .>100 then 100 else . end|round' 2>/dev/null || echo 0; }

# pull a bucket field, snake_case with camelCase fallback for both bucket and field
bucket() { # $1=json $2=bucket_snake $3=bucket_camel $4=field_snake $5=field_camel
  printf '%s' "$1" | jq -r --arg bs "$2" --arg bc "$3" --arg fs "$4" --arg fc "$5" \
    '((.[$bs]//.[$bc])//{})|(.[$fs]//.[$fc]//empty)' 2>/dev/null
}

# ISO8601 → epoch seconds (BSD/macOS date); handles Z, +00:00, fractional secs
iso_epoch() {
  local i="$1"
  { [ -z "$i" ] || [ "$i" = null ]; } && { echo ""; return; }
  i=$(printf '%s' "$i" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "$i" +%s 2>/dev/null || echo ""
}

# epoch → compact "in" duration: now | 37m | 4h12m | 2d3h
human() {
  local t="$1" now diff d h m
  [ -n "$t" ] || { echo "?"; return; }
  now=$(date +%s); diff=$(( t - now ))
  [ "$diff" -gt 0 ] || { echo now; return; }
  d=$(( diff/86400 )); h=$(( (diff%86400)/3600 )); m=$(( (diff%3600)/60 ))
  if   [ "$d" -gt 0 ]; then echo "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then echo "${h}h${m}m"
  else echo "${m}m"; fi
}

# single vertical-block sparkline glyph (like the Claude Code statusline): pct →
# ' ▁▂▃▄▅▆▇█' at 1/8 resolution. Any nonzero pct rounds UP to at least ▁ (visible).
spark() {
  local p="${1:-0}" i; local g=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  [ "$p" -lt 0 ] && p=0; [ "$p" -gt 100 ] && p=100
  [ "$p" -le 0 ] && { printf ' '; return; }
  i=$(( (p*8 + 99) / 100 )); [ "$i" -lt 1 ] && i=1; [ "$i" -gt 8 ] && i=8
  printf '%s' "${g[$((i-1))]}"
}

# raw API json → cache json on stdout
build_json() {
  local raw="$1" o label fhp shp fhr shr fhe she fhh shh
  o=$(org_id); label=$(org_label)
  fhp=$(to_pct "$(bucket "$raw" five_hour fiveHour utilization utilization)")
  shp=$(to_pct "$(bucket "$raw" seven_day sevenDay utilization utilization)")
  fhr=$(bucket "$raw" five_hour fiveHour resets_at resetsAt)
  shr=$(bucket "$raw" seven_day sevenDay resets_at resetsAt)
  fhe=$(iso_epoch "$fhr"); she=$(iso_epoch "$shr")
  fhh=$(human "$fhe");     shh=$(human "$she")
  jq -n \
    --arg o "$o" --arg label "$label" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson fhp "$fhp" --arg fhr "$fhr" --arg fhh "$fhh" --arg fhs "$(spark "$fhp")" \
    --argjson shp "$shp" --arg shr "$shr" --arg shh "$shh" --arg shs "$(spark "$shp")" \
    '{org:$o, label:$label, updated_at:$ts, stale:false,
      five_hour:{pct:$fhp, resets_at:$fhr, resets_in:$fhh, spark:$fhs},
      seven_day:{pct:$shp, resets_at:$shr, resets_in:$shh, spark:$shs}}'
}

# mark an existing cache stale (best effort) so a frozen meter is visible, not silent
mark_stale() {
  local c="$1" tmp
  [ -f "$c" ] || return 0
  tmp="$c.stale.$$"
  jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.stale=true | .updated_at=$ts' "$c" \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$c"
}

main() {
  local mode="${1:---print}" o cache tok raw j tmp
  o=$(org_id) || true
  [ -n "$o" ] || die "not logged in (no organizationUuid in $CLAUDE_JSON)"
  cache="$STATE/orgs/$o/usage.json"

  case "$mode" in
    --raw)
      tok=$(read_token) || die "no Claude credentials (Keychain '$KEYCHAIN_SERVICE')"
      raw=$(fetch "$tok") || die "usage request failed (token expired? endpoint changed? offline?)"
      printf '%s\n' "$raw" | jq . 2>/dev/null || printf '%s\n' "$raw"
      ;;
    --json)
      tok=$(read_token) || die "no Claude credentials"
      raw=$(fetch "$tok") || die "usage request failed"
      build_json "$raw"
      ;;
    --print|"")
      tok=$(read_token) || die "no Claude credentials"
      raw=$(fetch "$tok") || die "usage request failed"
      j=$(build_json "$raw")
      printf '%s: 5h %s %s%% (resets %s) · 7d %s %s%% (resets %s)\n' \
        "$(jq -r .label <<<"$j")" \
        "$(jq -r .five_hour.spark <<<"$j")" "$(jq -r .five_hour.pct <<<"$j")" "$(jq -r .five_hour.resets_in <<<"$j")" \
        "$(jq -r .seven_day.spark <<<"$j")" "$(jq -r .seven_day.pct <<<"$j")" "$(jq -r .seven_day.resets_in <<<"$j")"
      ;;
    --refresh)
      mkdir -p "$STATE/orgs/$o"
      tok=$(read_token) || { mark_stale "$cache"; die "no Claude credentials"; }
      raw=$(fetch "$tok") || { mark_stale "$cache"; die "usage request failed"; }
      tmp="$STATE/orgs/$o/.usage.$$"
      build_json "$raw" > "$tmp" 2>/dev/null && mv -f "$tmp" "$cache" || { rm -f "$tmp"; die "failed to build cache"; }
      echo "refreshed $cache"
      ;;
    *) die "unknown mode '$mode' (use --print | --json | --raw | --refresh)" ;;
  esac
}

main "$@"
