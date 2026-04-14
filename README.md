# tmux-agentbar

Per-window AI agent status indicators for tmux, inspired by [cmux](https://cmux.dev).

When Claude Code (or any compatible agent) runs inside a tmux window, the tab shows a live status icon and highlights via the tmux bell when the agent needs your attention — so you can leave background agents running and glance at the status bar to see which ones are waiting, thinking, or done.

## How it works

Two scripts, coupled by small state files in `$TMPDIR/tmux-agentbar/<session-id>/win-<N>`:

- `scripts/agentbar-report.sh <status>` — invoked from agent hooks. Writes the status, and for `waiting` / `done` rings the terminal bell so tmux flips the tab to its `window-status-bell-style` (reverse video by default) until you focus it.
- `scripts/agentbar-window-status.sh <window-index>` — invoked from tmux's `window-status-format` every second. Walks the pane's process tree to detect running agents, reads the state file, prints a 2-column status icon.

## Install

Clone the repo:

```bash
git clone https://github.com/dcryan/tmux-agentbar ~/Development/tmux-agentbar
```

### tmux (`~/.tmux.conf`)

Render the per-window icon. tmux's default `monitor-bell on` + `window-status-bell-style reverse` handle the tab highlight — no extra tmux config needed beyond the format strings:

```tmux
set -g status-interval 1
setw -g window-status-format         "#I #W #(~/Development/tmux-agentbar/scripts/agentbar-window-status.sh #I)"
setw -g window-status-current-format "#I #W #(~/Development/tmux-agentbar/scripts/agentbar-window-status.sh #I)"
```

### Claude Code (`~/.claude/settings.json`)

Wire status reporting into the hook events:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/Development/tmux-agentbar/scripts/agentbar-report.sh thinking" }] }],
    "Notification":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/Development/tmux-agentbar/scripts/agentbar-report.sh waiting"  }] }],
    "Stop":             [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/Development/tmux-agentbar/scripts/agentbar-report.sh done"     }] }],
    "SessionStart":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "~/Development/tmux-agentbar/scripts/agentbar-report.sh idle"     }] }]
  }
}
```

## Status model

| Status     | Icon        | Meaning                            | Bell?   |
|------------|-------------|------------------------------------|---------|
| `idle`     | `·`         | Session started, no activity       | no      |
| `thinking` | `✢✳✶✻` (spinner) | Agent is working              | no      |
| `waiting`  | `◷`         | Agent is waiting on user input     | **yes** |
| `done`     | `✓`         | Agent finished its turn            | **yes** |

Stale `waiting` decays to `idle` after 30s — Claude Code doesn't fire a hook when a notification is dismissed, so without the decay the icon would stick.

## Extending to other agents

`agentbar-window-status.sh` only renders an icon for windows whose process tree contains a known agent. The current matcher is:

```
claude|aider|cursor|copilot|cline
```

To add another agent, append its binary name to that regex in `agentbar-window-status.sh`. Any tool whose hooks (or wrapper) can call `agentbar-report.sh` with one of the four statuses will integrate.

## Requirements

- tmux 3.2+
- bash 3.2+ (macOS default is fine)

## License

MIT
