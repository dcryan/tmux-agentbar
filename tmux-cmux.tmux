#!/usr/bin/env bash
# tmux-cmux — metadata view for tmux windows running AI agents.
# TPM-compatible entry point.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$CURRENT_DIR/scripts"

# ── Options with defaults ────────────────────────────────────────────
tmux set-option -gq @cmux-agent-cmd     "claude"
tmux set-option -gq @cmux-poll-interval "3"

# ── Keybinding: popup dashboard ──────────────────────────────────────
tmux bind-key o display-popup -E -w 80% -h 70% "$SCRIPTS_DIR/cmux-sidebar.sh loop"

tmux display-message "tmux-cmux loaded ✓  (prefix+o = dashboard)"
