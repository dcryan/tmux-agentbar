#!/usr/bin/env bash
# agentbar-window-status.sh <window-index> [fallback-name] [session-id]
#
# Renders a tmux window's tab label for use inside window-status-format via
# `#(... #I '#W')`. The script OWNS the label so it can swap in the Claude
# session name when one is present:
#
#   - Window has a Claude agent  ->  "<session-name> <status-icon> "
#   - Otherwise                  ->  "<fallback-name> "
#
# The session name is Claude Code's terminal title (tmux #{pane_title}), minus
# the leading status glyph it prepends (e.g. "✳ gmail search" -> "gmail search").
# When Claude hasn't set a custom title yet (title is the bare host/dir) we fall
# back to the real window name, so #W is never visually lost.
#
# The status-icon column is always 2 chars wide (icon + space, or 2 spaces) so
# the icon never reflows; the name is stable per session so it doesn't flicker.

_SPINNER=(✢ ✳ ✶ ✻ ✽ ✻ ✶ ✳)
_COMPACT=(◌ ○ ◎ ◉ ● ◉ ◎ ○)

# Max characters for the session name before it is truncated with an ellipsis.
NAME_MAX="${AGENTBAR_NAME_MAX:-40}"

icon_for() {
    case "$1" in
        waiting)   echo "◷" ;;
        thinking)  echo "${_SPINNER[$(( $(date +%s) % ${#_SPINNER[@]} ))]}" ;;
        compacting) echo "${_COMPACT[$(( $(date +%s) % ${#_COMPACT[@]} ))]}" ;;
        done)      echo "✓" ;;
        idle|*)    echo "·" ;;
    esac
}

# Echo the pane_pid of the first pane in the window whose process subtree
# contains a known agent, or nothing. tmux's #{pane_current_command} is
# unreliable (Claude Code rewrites its process title to its version string),
# so we walk the tree and report which pane root the agent descends from.
agent_pane_pid() {
    local win_target="$1"
    local pids
    pids=$(tmux list-panes -t "$win_target" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ')
    [ -z "${pids// /}" ] && return 0

    ps -ao pid=,ppid=,args= 2>/dev/null | awk -v roots="$pids" '
        BEGIN { n = split(roots, r, /[[:space:]]+/); for (i=1; i<=n; i++) if (r[i] != "") root[r[i]] = r[i] }
        { pid=$1; ppid=$2; $1=""; $2=""; sub(/^  */,"",$0); argv[pid]=$0; parent[pid]=ppid }
        END {
            changed = 1
            while (changed) {
                changed = 0
                for (p in parent) if (!(p in root) && (parent[p] in root)) { root[p] = root[parent[p]]; changed = 1 }
            }
            for (p in root) if (argv[p] ~ /claude|aider|cursor|copilot|cline/) { print root[p]; exit 0 }
            exit 1
        }'
}

# Strip Claude's leading status glyph ("✳ name" -> "name") and surrounding
# whitespace. The glyph is a single space-delimited token with no ASCII
# alphanumerics; a real first word ("gmail", "MCP") is kept as-is.
clean_title() {
    local t="$1" first rest
    # trim leading/trailing whitespace
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    case "$t" in
        *' '*)
            first="${t%% *}"; rest="${t#* }"
            if printf '%s' "$first" | LC_ALL=C grep -q '[A-Za-z0-9]'; then
                printf '%s' "$t"
            else
                # drop the glyph token, then re-trim
                rest="${rest#"${rest%%[![:space:]]*}"}"
                printf '%s' "$rest"
            fi
            ;;
        *) printf '%s' "$t" ;;
    esac
}

win_idx="${1:-}"
fallback="${2:-}"
session_id="${3:-}"
[ -z "$win_idx" ] && { printf '%s ' "$fallback"; exit 0; }

command -v tmux >/dev/null 2>&1 || { printf '%s ' "$fallback"; exit 0; }

# Prefer the session id passed in from the format (deterministic, correct even
# with multiple clients attached). Fall back to an untargeted lookup for the
# legacy 2-arg call form.
[ -z "$session_id" ] && session_id=$(tmux display-message -p '#{session_id}' 2>/dev/null)
[ -z "$session_id" ] && { printf '%s ' "$fallback"; exit 0; }

win_target="${session_id}:${win_idx}"
pane_pid=$(agent_pane_pid "$win_target")

# No agent in this window: just render the real window name.
[ -z "$pane_pid" ] && { printf '%s ' "$fallback"; exit 0; }

# --- agent window: resolve the session name from the agent pane's title ---
label="$fallback"
title=$(tmux list-panes -t "$win_target" -F '#{pane_pid}|#{pane_title}' 2>/dev/null \
        | awk -F'|' -v p="$pane_pid" '$1==p { sub(/^[^|]*\|/,""); print; exit }')
name=$(clean_title "$title")

# Ignore the bare host name Claude shows before it has titled the session.
host_s=$(hostname -s 2>/dev/null)
host_f=$(hostname 2>/dev/null)
if [ -n "$name" ] && [ "$name" != "$host_s" ] && [ "$name" != "$host_f" ]; then
    label="$name"
fi

# Truncate over-long names so one tab can't dominate the status bar.
if [ "${#label}" -gt "$NAME_MAX" ]; then
    label="${label:0:$((NAME_MAX - 1))}…"
fi

# --- status icon (2-col, like before) ---
state_file="${TMPDIR:-/tmp}/tmux-agentbar/${session_id}/win-${win_idx}"
status="idle"
# line 1 only — line 2 (if present) holds the accountUuid for agentbar-status-right.sh
[ -f "$state_file" ] && status=$(sed -n '1p' "$state_file")

# Decay stale `waiting` → idle. Claude Code doesn't fire a hook when a
# notification is dismissed, so `waiting` can stick long after the user
# responded. `thinking` must NOT decay (long tasks legitimately run for
# minutes without firing another hook). `done`/`idle` are terminal.
if [ "$status" = "waiting" ] && [ -f "$state_file" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$state_file" 2>/dev/null || stat -c %Y "$state_file" 2>/dev/null || echo 0) ))
    [ "$age" -gt 30 ] && status="idle"
fi

printf '%s %s ' "$label" "$(icon_for "$status")"
