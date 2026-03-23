<h1 align="center">
<pre>
<span style="color:#FF9500">██╗   ██╗██╗███████╗██╗ ██████╗ ███╗   ██╗</span>
<span style="color:#FF9500">██║   ██║██║██╔════╝██║██╔═══██╗████╗  ██║</span>
<span style="color:#CC7700">██║   ██║██║███████╗██║██║   ██║██╔██╗ ██║</span>
<span style="color:#CC7700">╚██╗ ██╔╝██║╚════██║██║██║   ██║██║╚██╗██║</span>
<span style="color:#FFB74D"> ╚████╔╝ ██║███████║██║╚██████╔╝██║ ╚████║</span>
<span style="color:#FFB74D">  ╚═══╝  ╚═╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝</span>

<span style="color:#FF9500"> ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗</span>
<span style="color:#FF9500">██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝</span>
<span style="color:#CC7700">██║     ██║     ███████║██║   ██║██║  ██║█████╗  </span>
<span style="color:#CC7700">██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  </span>
<span style="color:#FFB74D">╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗</span>
<span style="color:#FFB74D"> ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝</span>
</pre>
</h1>

<p align="center">
<b>Let Claude see the world through your eyes</b><br>
<sub>Built by <a href="https://github.com/mrdulasolutions">@mrdulasolutions</a></sub>
</p>

<p align="center">
<img src="https://img.shields.io/badge/Channel_Mode-Claude_Code_Direct-FF9500?style=flat-square&logo=anthropic&logoColor=white" />
<img src="https://img.shields.io/badge/iPhone-1080p_@_30fps-FF9500?style=flat-square&logo=apple&logoColor=white" />
<img src="https://img.shields.io/badge/Ray--Ban_Meta-720p_@_30fps-FF9500?style=flat-square&logo=meta&logoColor=white" />
<img src="https://img.shields.io/badge/TTS-ElevenLabs_Flash-FF9500?style=flat-square" />
</p>

---

**VisionClaude** turns your iPhone or Meta Ray-Ban Smart Glasses into Claude's eyes and ears. Your phone connects directly to your Claude Code session — speak naturally, and Claude sees what you see, responds with voice, and uses ALL your MCP tools and skills.

```
iPhone/Glasses  ──→  Channel Plugin  ──→  Claude Code (Opus)
  (camera+voice)     (WebSocket)          ALL your MCP tools
                                          ALL your skills
                                          Full Cowork session
```

## Quick Start (5 minutes)

### What You Need

| Requirement | How to Get It |
|---|---|
| macOS 13+ | You probably have this |
| Node.js 18+ | `brew install node` |
| Bun | `curl -fsSL https://bun.sh/install \| bash` |
| Xcode 15+ | Mac App Store |
| iPhone (iOS 17+) | Physical device, USB cable |
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code` |

### Step 1: Clone and Setup

```bash
git clone https://github.com/mrdulasolutions/visionclaude.git
cd visionclaude/ClaudeVision
./setup.sh
```

The interactive installer handles dependencies, API keys, and Xcode project generation:

<p align="center">
<img src="ClaudeVision/docs/images/setup-screenshot.png" alt="VisionClaude Setup" width="500" />
</p>

### Step 2: Start the Channel

Add VisionClaude as an MCP server in your project's `.mcp.json`:

```json
{
  "mcpServers": {
    "visionclaude": {
      "command": "bun",
      "args": ["run", "/path/to/visionclaude/ClaudeVision/channel/server.ts"]
    }
  }
}
```

Then launch Claude Code with the channel enabled:

```bash
claude --dangerously-load-development-channels "server:visionclaude"
```

### Step 3: Get Your Token

Open the dashboard in your browser:

```
http://localhost:18790
```

You'll see your **Channel Token**, your **Mac's IP address**, and copy buttons for both. The dashboard also lets you send messages to your phone, configure ElevenLabs TTS, and monitor activity.

### Step 4: Connect Your Phone

Open the VisionClaude app on your iPhone, go to **Settings**, and enter:

| Setting | Value |
|---|---|
| **Host** | Your Mac's IP (shown on dashboard) |
| **Port** | `18790` |
| **Channel Token** | Copy from dashboard |

Tap **Connect**. You should see a green status indicator — you're now talking directly to your Claude Code session.

### Step 5: Start Talking

Point your camera at something and say *"What am I looking at?"* — Claude describes it. Say *"Email this to my team"* — Claude uses your email MCP tool. Every tool and skill in your Cowork session is available through voice.

---

## Features

### Vision
- **iPhone camera** — 1920x1080 (1080p) @ 30fps, continuous autofocus
- **Meta Ray-Ban glasses** — 1280x720 (720p) @ 30fps via DAT SDK
- High-performance `CADisplayLink` renderer (smooth video, not snapshots)
- 85% JPEG quality for accurate text/brand/object identification

### Voice
- **STT**: Apple Speech Recognition (on-device, privacy-first)
- **TTS**: ElevenLabs Flash v2.5 with 10 selectable voices, or Apple TTS fallback
- Tap-to-interrupt: stop Claude mid-sentence
- Bluetooth mic routing for hands-free glasses operation
- Configurable from the web dashboard or iOS app settings

### Channel Dashboard (http://localhost:18790)

<p align="center">
<img src="ClaudeVision/docs/images/dashboard-screenshot.png" alt="VisionClaude Dashboard" width="500" />
</p>

- Retro terminal UI with live status monitoring
- Auto-detects and displays your Mac's IP
- One-click copy for token, IP, and all settings
- Send messages to your phone from your Mac
- Configure ElevenLabs API key directly
- Activity log showing all inbound/outbound messages
- Live client connection count

### Security
- **Shared secret token** — auto-generated, required for all connections
- Token stored at `~/.claude/channels/visionclaude/.channel-token` (owner-only permissions)
- Health endpoint is public; everything else requires auth
- Override with `VISIONCLAUDE_TOKEN=your-custom-token` env var

### Auto-Approve Permissions

By default, Claude Code prompts for approval on every action from the phone. Choose your comfort level:

**Replies only** (safest) — add to `.claude/settings.local.json`:
```json
{
  "permissions": {
    "allow": [
      "mcp__visionclaude__reply",
      "mcp__visionclaude__edit_message",
      "Read(~/.claude/channels/visionclaude/**)"
    ]
  }
}
```

**All VisionClaude tools** (convenient):
```bash
claude --dangerously-load-development-channels "server:visionclaude" \
  --allowedTools "mcp__visionclaude__*"
```

**Full hands-free** (use with care — skips ALL prompts):
```bash
claude --dangerously-load-development-channels "server:visionclaude" \
  -p bypassPermissions
```

---

## Gateway Mode (Alternative)

If you don't use Claude Code, the standalone gateway server works with just an Anthropic API key:

```bash
cd ClaudeVision/server
cp .env.example .env        # Add your ANTHROPIC_API_KEY
npm install && npm run build && npm start
```

Gateway Mode auto-discovers MCP servers from your Claude Desktop config and skills from your local repos. It uses the Claude API directly instead of going through Claude Code.

### Adding MCP Servers (Gateway Mode)

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

**Local server:**
```json
{
  "mcpServers": {
    "slack": {
      "command": "npx",
      "args": ["-y", "@anthropic/mcp-slack"],
      "env": { "SLACK_BOT_TOKEN": "xoxb-your-token" }
    }
  }
}
```

**Remote server:**
```json
{
  "mcpServers": {
    "paysponge": {
      "url": "https://api.wallet.paysponge.com/mcp",
      "headers": { "Authorization": "Bearer your-api-key" }
    }
  }
}
```

Restart the gateway after changes: `lsof -ti:18790 | xargs kill -9 && npm start`

---

## Meta Ray-Ban Glasses

1. Install **Meta AI** app → pair glasses via Bluetooth
2. **Developer Mode**: Meta AI → Settings → your glasses → Developer Mode → ON
3. Restart glasses (hold button 15s to power off, press to power on)
4. Register at [developers.meta.com](https://developers.meta.com): Create app → Wearables → iOS config (Team ID + Bundle ID `com.claudevision.app`) → create version → assign to release channel
5. In VisionClaude: Settings → **Connect Glasses via Meta AI** → Approve
6. Switch camera source to **Meta Ray-Ban**

The DAT SDK is included via SPM from [facebook/meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios).

By using the Wearables Device Access Toolkit, you agree to the [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms) and [Acceptable Use Policy](https://wearables.developer.meta.com/acceptable-use-policy).

---

## ElevenLabs Voices

Configure via the web dashboard (http://localhost:18790) or iOS app Settings.

| Voice | Style | Gender |
|---|---|---|
| Rachel | Calm & warm | Female |
| Drew | Well-rounded | Male |
| Clyde | Deep & strong | Male |
| Paul | Ground news | Male |
| Domi | Assertive | Female |
| Dave | British conversational | Male |
| Fin | Irish | Male |
| Sarah | Soft & young | Female |
| Antoni | Well-rounded | Male |
| Elli | Young & emotional | Female |

Uses `eleven_flash_v2_5` model for lowest latency.

---

## Architecture

```
ClaudeVision/
├── channel/                    # Channel Mode (recommended)
│   ├── server.ts               # MCP channel + WebSocket + dashboard
│   ├── status.html             # Retro web dashboard
│   └── package.json
├── server/                     # Gateway Mode (standalone alternative)
│   ├── src/
│   │   ├── index.ts            # Express + branded ASCII console
│   │   ├── claude-client.ts    # Claude API + vision + tool loop
│   │   ├── mcp-manager.ts      # MCP server lifecycle (stdio + remote)
│   │   ├── skill-loader.ts     # SKILL.md auto-discovery
│   │   └── routes/             # REST endpoints
│   └── skills/                 # Built-in skills
├── ios/                        # iOS app (Swift/SwiftUI)
│   ├── Models/                 # Config, API types
│   ├── Services/               # Camera, speech, Ray-Ban, bridge
│   ├── ViewModels/             # Session orchestrator
│   └── Views/                  # UI (Apple HIG design)
├── setup.sh                    # Interactive installer
├── LICENSE                     # MIT
├── CONTRIBUTING.md
└── CODE_OF_CONDUCT.md
```

---

## License

MIT

## Disclaimer

This project is not affiliated with, endorsed by, or officially connected to Anthropic, PBC, Meta Platforms, Inc., or ElevenLabs, Inc. Claude is a trademark of Anthropic. Meta, Ray-Ban, and the Meta Wearables Device Access Toolkit are trademarks of Meta Platforms, Inc. ElevenLabs is a trademark of ElevenLabs, Inc.

---

<p align="center">
Built by <a href="https://github.com/mrdulasolutions">@mrdulasolutions</a>
</p>
