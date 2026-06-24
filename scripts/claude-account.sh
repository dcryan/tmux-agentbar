#!/usr/bin/env bash
# claude-account.sh — resolve the ACTIVE Claude account/org identity and maintain a
# tiny registry that cmux + tmux-agentbar both read.
#
# Identity is read from ${CLAUDE_CONFIG_DIR:-~/.claude}/.claude.json → .oauthAccount,
# so a project that sets CLAUDE_CONFIG_DIR (e.g. via direnv) resolves to its own
# account. Rate limits are owned by the ORGANIZATION, so usage is keyed by org while
# identity/sessions are keyed by account.
#
# Subcommands:
#   id      print active accountUuid           (empty + exit 1 if logged out)
#   org     print active organizationUuid       (empty + exit 1 if logged out)
#   label   print human label for the active org (from registry, else derived)
#   color   print tmux color slot for the active org
#   sync    write accounts/<uuid>/meta.json + orgs/<org>/{label,color}  (idempotent)
#   show    pretty-print the resolved identity   (debug)
set -uo pipefail

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/agentbar"

# Resolve the .claude.json that holds the active login. With CLAUDE_CONFIG_DIR set,
# Claude Code relocates it under that dir; otherwise it lives at ~/.claude.json (home
# root) — NOT inside ~/.claude/. Fall back across the known locations.
_resolve_claude_json() {
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then echo "$CLAUDE_CONFIG_DIR/.claude.json"; return; fi
  local c
  for c in "$HOME/.claude.json" "$HOME/.claude/.claude.json"; do
    [ -f "$c" ] && { echo "$c"; return; }
  done
  echo "$HOME/.claude.json"
}
CLAUDE_JSON="$(_resolve_claude_json)"

# tmux color slots cycled for org badges (deterministic per org uuid).
PALETTE=(colour4 colour2 colour5 colour3 colour6 colour1 colour12 colour10)

_oa() { jq -r --arg k "$1" '.oauthAccount[$k] // empty' "$CLAUDE_JSON" 2>/dev/null; }
acct() { _oa accountUuid; }
org()  { _oa organizationUuid; }

# Deterministic color slot from the org uuid (hash → palette). Stable across runs.
color_for() {
  local o="$1" h
  [ -n "$o" ] || { echo "${PALETTE[0]}"; return; }
  h=$(printf '%s' "$o" | cksum | awk '{print $1}')
  echo "${PALETTE[$(( h % ${#PALETTE[@]} ))]}"
}

# Sensible default label. Personal org (name is "<email>'s Organization" or contains
# the account email) → "PERSONAL"; otherwise an UPPERCASE slug of the org name's first
# word, with a "(max 20x)" hint for a 20x Max tier. `sync` writes this ONCE so a user
# hand-edit of orgs/<org>/label is never clobbered.
derive_label() {
  local name type tier email first
  name=$(_oa organizationName); type=$(_oa organizationType)
  tier=$(_oa organizationRateLimitTier); email=$(_oa emailAddress)
  [ -n "$name" ] || { echo "CLAUDE"; return; }
  case "$name" in
    *"'s Organization") echo "PERSONAL"; return ;;
    *"$email"*)         echo "PERSONAL"; return ;;
  esac
  first=$(printf '%s' "$name" | awk '{print toupper($1)}' | tr -cd 'A-Z0-9')
  [ -n "$first" ] || first="CLAUDE"
  case "$tier" in
    *20x*) echo "$first (max 20x)" ;;
    *)     echo "$first" ;;
  esac
}

cmd_sync() {
  local a o tmp
  a=$(acct); o=$(org)
  [ -n "$a" ] && [ -n "$o" ] || return 0   # logged out → nothing to sync
  mkdir -p "$STATE/accounts/$a" "$STATE/orgs/$o"
  # meta.json — always refreshed from .claude.json (the source of truth)
  tmp="$STATE/accounts/$a/.meta.$$"
  jq -n \
    --arg a "$a" --arg o "$o" \
    --arg email "$(_oa emailAddress)" --arg name "$(_oa displayName)" \
    --arg orgname "$(_oa organizationName)" --arg otype "$(_oa organizationType)" \
    --arg tier "$(_oa organizationRateLimitTier)" --arg color "$(color_for "$o")" \
    '{accountUuid:$a, organizationUuid:$o, emailAddress:$email, displayName:$name,
      organizationName:$orgname, organizationType:$otype,
      organizationRateLimitTier:$tier, color:$color}' \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE/accounts/$a/meta.json"
  # label — default written once; never overwrite a user edit
  [ -f "$STATE/orgs/$o/label" ] || printf '%s\n' "$(derive_label)" > "$STATE/orgs/$o/label"
  # color — deterministic, safe to refresh
  printf '%s\n' "$(color_for "$o")" > "$STATE/orgs/$o/color"
}

case "${1:-show}" in
  id)    a=$(acct); [ -n "$a" ] && echo "$a" || exit 1 ;;
  org)   o=$(org);  [ -n "$o" ] && echo "$o" || exit 1 ;;
  label) o=$(org);  cat "$STATE/orgs/$o/label" 2>/dev/null || derive_label ;;
  color) o=$(org);  cat "$STATE/orgs/$o/color" 2>/dev/null || color_for "$o" ;;
  sync)  cmd_sync ;;
  show)
    echo "config:  $CLAUDE_JSON"
    echo "account: $(acct)"
    echo "org:     $(org)"
    echo "label:   $( { o=$(org); cat "$STATE/orgs/$o/label" 2>/dev/null; } || derive_label )"
    echo "color:   $(color_for "$(org)")" ;;
  *) echo "usage: claude-account.sh {id|org|label|color|sync|show}" >&2; exit 2 ;;
esac
