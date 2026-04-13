#!/usr/bin/env bash
# cmux-report.sh <status>
#
# Writes the given status for the tmux window the caller is running in.
# Designed to be invoked from Claude Code hooks (UserPromptSubmit, Stop,
# Notification, SessionStart). Silently no-ops when not inside tmux.
#
# Status must be one of: idle | thinking | waiting | done

status="${1:-}"
case "$status" in
    idle|thinking|waiting|done) ;;
    *) exit 0 ;;
esac

# Must be inside tmux (hook fired from a tmux-hosted Claude pane).
[ -z "${TMUX_PANE:-}" ] && exit 0
command -v tmux >/dev/null 2>&1 || exit 0

session_id=$(tmux display-message -p -t "$TMUX_PANE" '#{session_id}' 2>/dev/null)
win_idx=$(tmux display-message -p -t "$TMUX_PANE" '#{window_index}' 2>/dev/null)
[ -z "$session_id" ] || [ -z "$win_idx" ] && exit 0

state_dir="${TMPDIR:-/tmp}/tmux-cmux/${session_id}"
mkdir -p "$state_dir" 2>/dev/null
printf '%s\n' "$status" > "$state_dir/win-${win_idx}"
