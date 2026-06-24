#!/usr/bin/env bash
# usage-refresh.sh — fire-and-forget: refresh the Claude usage cache for the active
# org and repaint the cmux sentinels, in the BACKGROUND, so the calling Claude Code
# hook returns instantly (the fetch can take a few seconds and must never block a turn).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
( "$here/claude-usage.sh" --refresh && "$here/cmux-usage-sentinels.sh" ) >/dev/null 2>&1 &
exit 0
