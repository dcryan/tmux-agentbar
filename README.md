# tmux-cmux

A tmux plugin inspired by [cmux](https://cmux.dev) — session-level AI agent workspace management.

## Concept

```
Session: "work"
├── Window 0: cmux-dash  ← persistent dashboard (auto-refreshing)
├── Window 1: api-server  → claude: thinking ⠋
├── Window 2: frontend    → claude: waiting  ⚡
├── Window 3: infra       → claude: done     ✓
└── Window 4: docs        → claude: idle     ○
```

Each **window = a project**. The dashboard (window 0) shows all windows with their rolled-up agent status. Multiple Claude instances in one window get aggregated to the "worst" status (waiting > thinking > done > idle).

## Features

- **Session Dashboard** — Persistent window showing all projects and their agent statuses at a glance
- **Smart Status Detection** — Monitors agent panes to detect: idle, thinking, waiting for input, done
- **Status Rollup** — Multiple agent panes per window roll up to the most urgent status
- **Desktop Notifications** — OS-native alerts when agents need input (macOS + Linux)
- **Status Bar** — Compact segment: `⚡2 ⠋1 ✓3 feat/oauth●`
- **Project Launcher** — Spawn pre-configured window layouts with agent running

## Requirements

- tmux 3.2+ (for `display-popup`)
- bash 4+
- git (optional, for branch display)

## Install

### With TPM

```bash
set -g @plugin 'your-user/tmux-cmux'
```

Then `prefix + I` to install.

### Manual

```bash
git clone https://github.com/your-user/tmux-cmux ~/.tmux/plugins/tmux-cmux
echo 'run-shell ~/.tmux/plugins/tmux-cmux/tmux-cmux.tmux' >> ~/.tmux.conf
tmux source ~/.tmux.conf
```

## Key Bindings

| Key           | Action                           |
|---------------|----------------------------------|
| `prefix + M`  | Toggle session dashboard         |
| `prefix + C`  | Launch new project window        |
| `prefix + N`  | Notification summary popup       |
| `0-9`         | (in dashboard) Jump to window    |

## CLI

```bash
# Add scripts/ to your PATH
export PATH="$HOME/.tmux/plugins/tmux-cmux/scripts:$PATH"

cmux launch -d ~/projects/api -s split-h     # new project window
cmux dash                                      # toggle dashboard
cmux windows                                   # list window statuses
cmux notify start                              # start background monitor
```

## Configuration

```bash
# ~/.tmux.conf (set before loading plugin)
set -g @cmux-agent-cmd     "claude"                    # agent binary
set -g @cmux-poll-interval "3"                         # scan frequency (seconds)
set -g @cmux-notify-style  "fg=black,bg=blue,bold"     # pane highlight style
```

## Status Model

| Status     | Icon | Meaning                           |
|------------|------|-----------------------------------|
| `idle`     | ○    | No agent running or not started   |
| `thinking` | ⠋    | Agent actively working            |
| `waiting`  | ⚡    | Agent needs user input            |
| `done`     | ✓    | Agent finished task               |

When a window has multiple agent panes, the **most urgent** status wins:
`waiting > thinking > done > idle`

## Extending for Other Agents

In `scripts/cmux-common.sh`, add to `is_agent_pane()`:

```bash
case "$cmd" in
    claude|aider|cursor|your-agent) return 0 ;;
esac
```

In `scripts/cmux-notify.sh`, add detection patterns to `WAIT_PATTERNS`, `THINKING_PATTERNS`, or `DONE_PATTERNS`.

## License

MIT
