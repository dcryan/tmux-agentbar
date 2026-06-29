# tmux-agentbar

Per-window AI agent status indicators for tmux, inspired by [cmux](https://cmux.dev).

When Claude Code (or any compatible agent) runs inside a tmux window, the tab shows a live status icon and highlights via the tmux bell when the agent needs your attention — so you can leave background agents running and glance at the status bar to see which ones are waiting, thinking, or done.

## How it works

Two scripts, coupled by small state files in `$TMPDIR/tmux-agentbar/<session-id>/win-<N>`:

- `scripts/agentbar-report.sh <status>` — invoked from agent hooks. Writes the status, and for `waiting` / `done` rings the terminal bell so tmux flips the tab to its `window-status-bell-style` (reverse video by default) until you focus it.
- `scripts/agentbar-window-status.sh <window-index> [fallback-name]` — invoked from tmux's `window-status-format` every second. Walks the pane's process tree to detect running agents, reads the state file, and renders the tab label: `<name> <status-icon>`. For agent windows the `<name>` is the **Claude session name** (Claude Code's terminal title, `#{pane_title}`, minus its leading status glyph); for everything else it's the real window name passed in as `[fallback-name]`.

## Install

Clone the repo:

```bash
git clone https://github.com/dcryan/tmux-agentbar ~/Development/tmux-agentbar
```

### tmux (`~/.tmux.conf`)

Render the per-window label + icon. The script now owns the whole label, so drop the literal `#W` and pass it in as the fallback name instead (quoted, since window names can contain spaces). tmux's default `monitor-bell on` + `window-status-bell-style reverse` handle the tab highlight — no extra tmux config needed beyond the format strings:

```tmux
set -g status-interval 1
setw -g window-status-format         "#I #(~/Development/tmux-agentbar/scripts/agentbar-window-status.sh #I '#W' '#{session_id}')"
setw -g window-status-current-format "#I #(~/Development/tmux-agentbar/scripts/agentbar-window-status.sh #I '#W' '#{session_id}')"
```

For windows running a Claude agent, the tab shows the **session name** instead of the bare window name — e.g. `2 gmail subject line search ◷` rather than `2 claude ◷`. The name comes from Claude Code's terminal title and updates live; `#W` itself is never changed (so `automatic-rename`, `choose-tree`, etc. are unaffected). Cap the displayed length with `AGENTBAR_NAME_MAX` (default 40).

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

## Claude usage meters

A shared provider publishes live Claude rate-limit usage (the rolling **5-hour** and
**7-day** windows) that any UI can consume — the tmux `status-right`, the cmux custom
sidebar, etc. **One writer, many readers.**

### Identity: account vs organization

Rate limits are owned by the **organization**, not the user account. So usage is keyed
by `organizationUuid` while a session/window is tagged by `accountUuid`. Identity is
read from `${CLAUDE_CONFIG_DIR:-~/.claude}/.claude.json` → `.oauthAccount`, so a project
that sets `CLAUDE_CONFIG_DIR` (e.g. via direnv) resolves to its own account/subscription.

### Scripts

| Script | Role |
|--------|------|
| `claude-account.sh {id\|org\|label\|color\|sync}` | resolve the active account/org; `sync` writes the registry below |
| `claude-usage.sh {--print\|--json\|--raw\|--refresh}` | fetch usage from Anthropic's (unofficial) `oauth/usage` endpoint; `--refresh` writes the cache |
| `usage-refresh.sh` | fire-and-forget wrapper: `--refresh` + repaint cmux, backgrounded (for hooks) |
| `cmux-usage-sentinels.sh` | paint usage into the cmux sidebar via hidden "sentinel" workspaces (cmux-only) |
| `agentbar-status-right.sh <session_id> <window_index>` | emit a tmux `status-right` segment for the active window |

### State (shared cache)

```
${XDG_STATE_HOME:-~/.local/state}/agentbar/
├── accounts/<accountUuid>/meta.json   # identity + display color
└── orgs/<organizationUuid>/
    ├── label                          # "PERSONAL" | "ACME (max 20x)"  (hand-editable)
    └── usage.json                     # { five_hour:{pct,resets_in,spark}, seven_day:{…}, stale }

$TMPDIR/tmux-agentbar/<session_id>/win-<idx>   # line 1: status   line 2: accountUuid
```

The meter glyph is a single vertical-block sparkline ` ▁▂▃▄▅▆▇█` (1/8 resolution), like
the Claude Code statusline.

### Wiring

- **Claude Code hooks** (`~/.claude/settings.json`): `SessionStart` → `claude-account.sh sync`;
  `UserPromptSubmit` + `Stop` → `usage-refresh.sh` (`"async": true`).
- **tmux** (`~/.tmux.conf`): `set -g status-right "#(…/agentbar-status-right.sh #{session_id} #{window_index})"`.
- **cmux**: `automation.socketControlMode: "automation"` in `cmux.json`, plus the
  `usage.swift` custom sidebar (matches sentinel titles by the `◈ ` prefix).

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
