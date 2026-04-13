#!/usr/bin/env bash
# cmux-sidebar.sh — Session-level dashboard rendered in a tmux popup.
#
# Usage:
#   cmux-sidebar.sh render   One-shot render
#   cmux-sidebar.sh loop     Continuous render loop (run inside the popup)

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/cmux-common.sh"

POLL_INTERVAL="$(cmux_opt poll-interval 3)"

# ── Color codes ──────────────────────────────────────────────────────
RST="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
FG_CYAN="\033[36m"
FG_GREEN="\033[32m"
FG_YELLOW="\033[33m"
FG_BLUE="\033[34m"
FG_GRAY="\033[90m"
BG_YELLOW="\033[43m"
FG_BLACK="\033[30m"

status_color() {
    case "$1" in
        waiting)  echo -e "${FG_YELLOW}" ;;
        thinking) echo -e "${FG_BLUE}" ;;
        done)     echo -e "${FG_GREEN}" ;;
        idle|*)   echo -e "${FG_GRAY}" ;;
    esac
}

# ── Render the dashboard ─────────────────────────────────────────────
render() {
    local session_name
    session_name=$(tmux display-message -p '#{session_name}' 2>/dev/null)

    echo -e ""
    echo -e "  ${FG_CYAN}${BOLD}tmux-cmux${RST}  ${DIM}session: ${session_name}${RST}"
    echo -e "  ${DIM}────────────────────────────────────${RST}"

    eval "$(session_status_summary)"
    echo -e "  ${FG_YELLOW}⚡ ${waiting}${RST}  ${FG_BLUE}⠋ ${thinking}${RST}  ${FG_GREEN}✓ ${done}${RST}  ${FG_GRAY}○ ${idle}${RST}"
    echo -e ""

    local windows
    windows=$(tmux list-windows -F '#{window_index}|#{window_name}|#{window_panes}' 2>/dev/null) || return

    while IFS='|' read -r idx name pane_count; do
        [ -z "$idx" ] && continue

        local ws sc icon
        ws=$(get_window_status "$idx")
        sc=$(status_color "$ws")
        icon=$(status_icon "$ws")

        local win_target="${session_name}:${idx}"
        local cwd branch dirty ports pane_path

        pane_path=$(tmux display-message -t "$win_target" -p '#{pane_current_path}' 2>/dev/null)
        cwd=$(echo "$pane_path" | sed "s|$HOME|~|")
        branch=$(git_branch_for "$pane_path")
        dirty=$(git_dirty_for "$pane_path")

        local first_pid
        first_pid=$(tmux display-message -t "$win_target" -p '#{pane_pid}' 2>/dev/null)
        ports=$(listening_ports_for "$first_pid")

        local agent_count=0 panes
        panes=$(tmux list-panes -t "$win_target" -F '#{pane_id}' 2>/dev/null)
        for p in $panes; do
            is_agent_pane "$p" && agent_count=$((agent_count + 1))
        done

        local badge=""
        if [ "$ws" = "waiting" ]; then
            badge=" ${BG_YELLOW}${FG_BLACK}${BOLD} INPUT ${RST}"
        fi

        echo -e "  ${sc}${BOLD}${icon}${RST} ${BOLD}${idx}:${name}${RST}${badge}"
        echo -e "    ${FG_GRAY}📂 ${cwd}${RST}"
        if [ "$branch" != "-" ]; then
            echo -e "    ${FG_GREEN}🌿 ${branch}${RST}${FG_YELLOW}${dirty}${RST}$([ -n "$ports" ] && echo " ${FG_GRAY}· :${ports}${RST}")"
        fi
        echo -e "    ${FG_GRAY}${agent_count} agent(s) · ${ws}${RST}"
        echo -e ""
    done <<< "$windows"

    echo -e "  ${DIM}────────────────────────────────────${RST}"
    echo -e "  ${DIM}0-9=jump to window  esc/q=close  r=refresh${RST}"
}

# ── Interactive loop (runs inside the popup) ─────────────────────────
run_loop() {
    trap 'exit 0' INT TERM

    while true; do
        # Buffer the full frame so a row-by-row render (many forks) isn't
        # visible. Repaint in place via cursor-home + erase-below; that avoids
        # the blank flash `clear` causes between frames.
        local frame
        frame=$(render)
        printf '\033[H%s\033[J' "$frame"

        if read -rsn1 -t "$POLL_INTERVAL" key 2>/dev/null; then
            case "$key" in
                q|Q|$'\e')
                    exit 0
                    ;;
                [0-9])
                    tmux select-window -t "$key" 2>/dev/null
                    exit 0
                    ;;
                r|R)
                    continue
                    ;;
            esac
        fi
    done
}

case "${1:-loop}" in
    render)  render ;;
    loop)    run_loop ;;
    *)       echo "Usage: cmux-sidebar.sh {render|loop}" >&2; exit 1 ;;
esac
