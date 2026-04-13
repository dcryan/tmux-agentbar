#!/usr/bin/env bash
# cmux-window-status.sh <window-index>
#
# Prints a single icon representing the rolled-up agent status of the
# given window (in the current session). Intended for use inside
# tmux's window-status-format via `#(... #I)`.
#
# Output: one of ⚡ ⠋ ✓ ○  (plus a trailing space). Always two columns so
# the tab width never changes — prevents status-bar reflow flicker.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/cmux-common.sh"

blank() { printf '  '; exit 0; }

win_idx="${1:-}"
[ -z "$win_idx" ] && blank

session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null)
[ -z "$session_name" ] && blank

win_target="${session_name}:${win_idx}"

agent_found=0
panes=$(tmux list-panes -t "$win_target" -F '#{pane_id}' 2>/dev/null)
for p in $panes; do
    if is_agent_pane "$p"; then
        agent_found=1
        break
    fi
done

[ "$agent_found" = "0" ] && blank

status=$(get_window_status "$win_idx")

# Decay stale `waiting` → idle. Claude Code doesn't fire a hook when a
# notification is dismissed, so `waiting` can stick long after the user has
# responded. `thinking` must NOT decay (long tasks legitimately take minutes
# without firing another hook). `done`/`idle` are terminal and don't decay.
if [ "$status" = "waiting" ]; then
    state_file="${TMPDIR:-/tmp}/tmux-cmux/$(tmux display-message -p '#{session_id}' 2>/dev/null)/win-${win_idx}"
    if [ -f "$state_file" ]; then
        age=$(( $(date +%s) - $(stat -f %m "$state_file" 2>/dev/null || stat -c %Y "$state_file" 2>/dev/null || echo 0) ))
        [ "$age" -gt 30 ] && status="idle"
    fi
fi

printf '%s ' "$(status_icon "$status")"
