#!/usr/bin/env bash
# Start a Claude Code session wired to the VisionClaude channel.
#
#   ./start.sh            interactive, prompts for every reply
#   ./start.sh --auto     auto-approve the channel's reply/edit tools
#   ./start.sh --yolo     hands-free: skips ALL permission prompts
#
# Any extra arguments are passed straight through to `claude`.
set -euo pipefail

CHANNEL="server:visionclaude"
DASHBOARD="http://localhost:18790"

auto=0
yolo=0
passthrough=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--auto)          auto=1 ;;
    -y|--yolo|--bypass) yolo=1 ;;
    -h|--help)
      sed -n '2,8p' "$0" | cut -c3-
      exit 0
      ;;
    *) passthrough+=("$1") ;;
  esac
  shift
done

if ! command -v claude >/dev/null 2>&1; then
  echo "claude CLI not found. Install it with: npm install -g @anthropic-ai/claude-code" >&2
  exit 1
fi

args=(--dangerously-load-development-channels "$CHANNEL")

# The channel exposes mcp__visionclaude__reply / __edit_message. Allowing them means
# Claude can answer the phone without a prompt per message; everything else still asks.
if [[ $auto -eq 1 ]]; then
  args+=(--allowedTools "mcp__visionclaude__*")
fi

# Bypasses every permission check, including writes and shell commands. Use with care.
if [[ $yolo -eq 1 ]]; then
  args+=(--permission-mode bypassPermissions)
fi

ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "unknown")

echo "VisionClaude channel: $CHANNEL"
echo "Dashboard:            $DASHBOARD  (channel token lives here)"
echo "Phone should connect: host $ip, port 18790"
[[ $auto -eq 1 ]] && echo "Mode:                 auto-approving mcp__visionclaude__*"
[[ $yolo -eq 1 ]] && echo "Mode:                 HANDS-FREE — all permission prompts bypassed"
echo

exec claude "${args[@]}" ${passthrough[@]+"${passthrough[@]}"}
