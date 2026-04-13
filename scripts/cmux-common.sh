#!/usr/bin/env bash
# cmux-common.sh — Shared helpers for tmux-cmux (session-level architecture)
#
# Status model:
#   Each window tracks a rolled-up status from all its agent panes.
#   Statuses: idle → thinking → waiting → done
#   Priority: waiting > thinking > done > idle  (worst wins)

# ── Config helpers ───────────────────────────────────────────────────
cmux_opt() {
    local key="$1" default="$2"
    local val
    val=$(tmux show-option -gqv "@cmux-${key}" 2>/dev/null)
    echo "${val:-$default}"
}

# ── State directory (shared across all scripts) ─────────────────────
cmux_state_dir() {
    local session
    session=$(tmux display-message -p '#{session_id}' 2>/dev/null || echo "default")
    local dir="${TMPDIR:-/tmp}/tmux-cmux/${session}"
    mkdir -p "$dir" 2>/dev/null
    echo "$dir"
}

# ── Status enum ──────────────────────────────────────────────────────
# Priority order (higher = more urgent, used for rollup)
status_priority() {
    case "$1" in
        waiting)  echo 3 ;;
        thinking) echo 2 ;;
        done)     echo 1 ;;
        idle|*)   echo 0 ;;
    esac
}

# Braille spinner frames for `thinking` — one frame per status-interval tick
# (tmux's #() only re-runs this often). Keyed on wall-clock seconds so every
# tab animates in sync.
_SPINNER_FRAMES=(⠋ ⠙ ⠸ ⠴ ⠦ ⠇)
status_icon() {
    case "$1" in
        waiting)  echo "◷" ;;
        thinking) echo "${_SPINNER_FRAMES[$(( $(date +%s) % ${#_SPINNER_FRAMES[@]} ))]}" ;;
        done)     echo "✓" ;;
        idle|*)   echo "○" ;;
    esac
}

# ── Per-window status read/write ─────────────────────────────────────
# Write status for a specific window
# Usage: set_window_status <window_id> <status>
set_window_status() {
    local win_id="$1" status="$2"
    local state_dir
    state_dir="$(cmux_state_dir)"
    echo "$status" > "$state_dir/win-${win_id}"
}

# Read status for a specific window
# Usage: get_window_status <window_id>  →  stdout: idle|thinking|waiting|done
get_window_status() {
    local win_id="$1"
    local state_dir
    state_dir="$(cmux_state_dir)"
    local f="$state_dir/win-${win_id}"
    if [ -f "$f" ]; then
        cat "$f"
    else
        echo "idle"
    fi
}

# ── Per-pane agent status (used to compute window rollup) ────────────
set_pane_status() {
    local pane_id="$1" status="$2"
    local state_dir
    state_dir="$(cmux_state_dir)"
    echo "$status" > "$state_dir/pane-${pane_id}"
}

get_pane_status() {
    local pane_id="$1"
    local state_dir
    state_dir="$(cmux_state_dir)"
    local f="$state_dir/pane-${pane_id}"
    if [ -f "$f" ]; then
        cat "$f"
    else
        echo "idle"
    fi
}

# Roll up all pane statuses in a window to a single window status.
# The "worst" (highest priority) pane status wins.
rollup_window_status() {
    local win_target="$1"  # e.g. "mysession:2"
    local state_dir
    state_dir="$(cmux_state_dir)"

    local worst="idle"
    local worst_pri=0

    local panes
    panes=$(tmux list-panes -t "$win_target" -F '#{pane_id}' 2>/dev/null) || return

    for pane_id in $panes; do
        local ps
        ps=$(get_pane_status "$pane_id")
        local pri
        pri=$(status_priority "$ps")
        if [ "$pri" -gt "$worst_pri" ]; then
            worst="$ps"
            worst_pri="$pri"
        fi
    done

    # Extract bare window index for storage
    local win_idx
    win_idx=$(tmux display-message -t "$win_target" -p '#{window_index}' 2>/dev/null)
    set_window_status "$win_idx" "$worst"
    echo "$worst"
}

# ── Pane metadata helpers ────────────────────────────────────────────
pane_pid() {
    tmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null
}

pane_cwd() {
    tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

pane_cmd() {
    tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# ── Git helpers ──────────────────────────────────────────────────────
git_branch_for() {
    local dir="$1"
    git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || \
    git -C "$dir" rev-parse --short HEAD 2>/dev/null || \
    echo "-"
}

git_dirty_for() {
    local dir="$1"
    if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null | head -1)" ]; then
        echo "●"
    fi
}

# ── Port detection ───────────────────────────────────────────────────
listening_ports_for() {
    local pid="$1"
    if command -v lsof &>/dev/null; then
        lsof -iTCP -sTCP:LISTEN -a -p "$pid" -Fn 2>/dev/null | \
            grep '^n' | sed 's/^n.*://' | sort -u | tr '\n' ',' | sed 's/,$//'
    elif command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep "pid=$pid" | \
            awk '{print $4}' | sed 's/.*://' | sort -u | tr '\n' ',' | sed 's/,$//'
    fi
}

# ── Agent detection ──────────────────────────────────────────────────
is_agent_pane() {
    local pane="$1"
    local cmd
    cmd=$(pane_cmd "$pane")
    case "$cmd" in
        claude|claude-code|aider|cursor|copilot|cline) return 0 ;;
    esac

    # Walk descendants of the pane's root pid (shell) and match on full argv.
    # pane_current_command is unreliable for programs that rewrite their proc
    # title (e.g. Claude Code reports its version string), so we inspect args.
    local pid
    pid=$(pane_pid "$pane")
    if [ -n "$pid" ]; then
        # Snapshot the process table, then walk the descendant tree of $pid.
        local match
        match=$(ps -ao pid=,ppid=,args= 2>/dev/null | awk -v root="$pid" '
            { pid=$1; ppid=$2; $1=""; $2=""; sub(/^  */,"",$0); argv[pid]=$0; parent[pid]=ppid }
            END {
                tree[root]=1; changed=1
                while (changed) {
                    changed=0
                    for (p in parent) {
                        if (!(p in tree) && (parent[p] in tree)) { tree[p]=1; changed=1 }
                    }
                }
                for (p in tree) {
                    if (argv[p] ~ /claude|aider|cursor|copilot|cline/) { print "1"; exit }
                }
            }')
        [ "$match" = "1" ] && return 0
    fi

    # Also honor manual registration.
    local state_dir
    state_dir="$(cmux_state_dir)"
    [ -f "$state_dir/agent-${pane}" ] && return 0
    return 1
}

# Mark a pane as an agent pane (for manual registration)
register_agent_pane() {
    local pane_id="$1" agent_cmd="${2:-claude}"
    local state_dir
    state_dir="$(cmux_state_dir)"
    echo "$agent_cmd" > "$state_dir/agent-${pane_id}"
}

# ── Session summary helpers ──────────────────────────────────────────
# Count windows by status. Outputs: "waiting=N thinking=N done=N idle=N"
session_status_summary() {
    local waiting=0 thinking=0 done=0 idle=0
    local windows
    windows=$(tmux list-windows -F '#{window_index}' 2>/dev/null) || return

    for win_idx in $windows; do
        local ws
        ws=$(get_window_status "$win_idx")
        case "$ws" in
            waiting)  waiting=$((waiting + 1)) ;;
            thinking) thinking=$((thinking + 1)) ;;
            done)     done=$((done + 1)) ;;
            *)        idle=$((idle + 1)) ;;
        esac
    done
    echo "waiting=$waiting thinking=$thinking done=$done idle=$idle"
}

# ── Cleanup stale state ─────────────────────────────────────────────
cleanup_stale_state() {
    local state_dir
    state_dir="$(cmux_state_dir)"

    # Remove pane state files for panes that no longer exist
    local live_panes
    live_panes=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | tr '\n' ' ')

    for f in "$state_dir"/pane-* "$state_dir"/agent-*; do
        [ -f "$f" ] || continue
        local pane_id
        pane_id=$(basename "$f" | sed 's/^pane-//;s/^agent-//')
        if ! echo "$live_panes" | grep -q "$pane_id"; then
            rm -f "$f"
        fi
    done
}
