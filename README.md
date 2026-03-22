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
<img src="https://img.shields.io/badge/iPhone-1080p_@_30fps-FF9500?style=flat-square&logo=apple&logoColor=white" />
<img src="https://img.shields.io/badge/Ray--Ban_Meta-720p_@_30fps-FF9500?style=flat-square&logo=meta&logoColor=white" />
<img src="https://img.shields.io/badge/TTS-ElevenLabs_Flash-FF9500?style=flat-square" />
<img src="https://img.shields.io/badge/API-Claude_Sonnet-FF9500?style=flat-square&logo=anthropic&logoColor=white" />
</p>

---

**VisionClaude** turns your iPhone or Meta Ray-Ban Smart Glasses into Claude's eyes and ears. Point your camera, speak naturally, and Claude sees what you see — then responds with voice, using your connected tools and skills.

## How It Works

```
iPhone (1080p)  ╲
  or             → Gateway Server → Claude API
Ray-Ban (720p)  ╱   (your Mac)    → MCP Tools + Skills
Your Voice      →                 ← (email, calendar, etc.)
ElevenLabs TTS  ←   Claude Reply
```

1. **You speak** — on-device speech recognition (or Ray-Ban mic via Bluetooth)
2. **Camera captures** — 1080p iPhone or 720p Ray-Ban frame as high-quality JPEG
3. **Gateway sends** — text + image to Claude with your skills injected
4. **Claude responds** — with accurate vision analysis + tool actions
5. **You hear** — ElevenLabs Flash TTS reads the response (10 voice options)
6. **Loop repeats** — continuous hands-free conversation

## Quick Start

```bash
git clone https://github.com/mrdulasolutions/visionclaude.git
cd visionclaude/ClaudeVision
./setup.sh
```

The interactive setup walks you through everything with step-by-step guidance:

<p align="center">
<img src="ClaudeVision/docs/images/setup-screenshot.png" alt="VisionClaude Setup" width="500" />
</p>

## Requirements

| Requirement | Version |
|---|---|
| macOS | 13+ |
| Node.js | 18+ |
| Xcode | 15+ (for iOS app) |
| iPhone | iOS 17+ (physical device, not Simulator) |
| Anthropic API Key | [console.anthropic.com](https://console.anthropic.com/settings/keys) |
| ElevenLabs Key | Optional — [elevenlabs.io](https://elevenlabs.io/app/settings/api-keys) |

## Features

### Vision
- **iPhone camera** at 1920×1080 (1080p) @ 30fps with continuous autofocus
- **Meta Ray-Ban glasses** at 1280×720 (720p) @ 30fps via DAT SDK
- High-performance `CADisplayLink` video renderer (smooth live feed, not snapshots)
- 85% JPEG quality for accurate text reading and object identification

### Voice
- **STT**: Apple Speech Recognition (on-device, privacy-first)
- **TTS**: ElevenLabs Flash v2.5 (low-latency streaming) with 10 selectable voices
- Fallback to Apple TTS when no ElevenLabs key configured
- Hands-free mode: auto-starts listening when using Ray-Ban glasses
- Tap-to-interrupt: stop Claude mid-sentence by tapping the mic button
- Bluetooth mic routing for Ray-Ban glasses (HFP)

### Skills (Auto-Discovered)
The gateway scans for `SKILL.md` files across your system:

| Path | What's Found |
|---|---|
| `server/skills/` | VisionClaude built-in skills |
| `~/.claude/plugins/` | Claude Code marketplace plugins |
| `~/Desktop/Claude Repo/` | Your Claude project skills |
| `~/Desktop/Cursor Repo/` | Your Cursor project skills |
| `~/Desktop/ExChek Client Repos/` | ExChek compliance skills |

Skills are injected into Claude's system prompt automatically. Hot-reload anytime:

```bash
curl -X POST http://localhost:18790/skills/reload
```

### MCP Tools (Auto-Discovered)
Reads your Claude Desktop config and connects to the same MCP servers:

```
~/Library/Application Support/Claude/claude_desktop_config.json
```

Add servers in Claude Desktop → restart the gateway → they appear in VisionClaude.

```
Claude Desktop  ──→  MCP servers (email, calendar, etc.)
                         ↑
VisionClaude    ──→  Gateway Server ──→ same MCP servers
(your phone)         (your Mac)
```

### Settings (Persisted)
All settings save to `UserDefaults` and survive app restarts:
- Gateway host/port
- Camera source (iPhone or Ray-Ban)
- ElevenLabs API key and voice selection
- JPEG quality and frame interval

## Architecture

### Gateway Server (Node.js)

```
server/
├── src/
│   ├── index.ts              # Express entry + branded ASCII console
│   ├── claude-client.ts      # Claude Messages API + vision + tool loop
│   ├── mcp-manager.ts        # MCP server lifecycle & tool discovery
│   ├── skill-loader.ts       # SKILL.md auto-discovery & injection
│   ├── console-theme.ts      # Anthropic orange terminal theme
│   ├── conversation.ts       # In-memory conversation store
│   └── routes/
│       ├── chat.ts           # POST /chat — text + images → Claude
│       ├── health.ts         # GET /health — status + MCP + skills
│       ├── tools.ts          # GET /tools — list MCP tools
│       └── config.ts         # GET/POST /config — runtime settings
├── skills/                   # Built-in skills (add SKILL.md here)
│   ├── vision-describe/
│   └── read-text/
└── .env                      # API keys (git-ignored)
```

### iOS App (Swift/SwiftUI)

```
ios/ClaudeVision/
├── Models/
│   ├── ClaudeConfig.swift        # Persistent settings (Codable + UserDefaults)
│   └── ChatModels.swift          # API request/response types
├── Services/
│   ├── ClaudeBridge.swift        # HTTP client → gateway
│   ├── SpeechManager.swift       # STT + ElevenLabs TTS (10 voices)
│   ├── CameraManager.swift       # AVCaptureSession 1080p @ 30fps
│   ├── RayBanManager.swift       # DAT SDK streaming + registration
│   ├── FrameSource.swift         # Protocol for camera/Ray-Ban
│   └── AudioSessionManager.swift # Bluetooth HFP mic routing
├── ViewModels/
│   └── SessionViewModel.swift    # Pipeline orchestrator
└── Views/
    ├── ContentView.swift         # Camera preview + RayBanVideoView
    ├── TranscriptView.swift      # Conversation history
    └── SettingsView.swift        # Full settings UI + voice picker
```

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Status, MCP servers, skills, conversations |
| `/tools` | GET | List all discovered MCP tools |
| `/skills` | GET | List all loaded skills |
| `/skills/reload` | POST | Hot-reload skills from disk |
| `/chat` | POST | Send text + images, get Claude's response |
| `/config` | GET/POST | View or update system prompt, model |

### Chat Request

```json
{
  "text": "What am I looking at?",
  "images": ["<base64 JPEG>"],
  "conversation_id": "optional-session-id"
}
```

### Chat Response

```json
{
  "text": "That's a silver MacBook Pro on a wooden desk with...",
  "tool_calls": [{"name": "send_email", "result": {...}}],
  "conversation_id": "generated-session-id"
}
```

## Meta Ray-Ban Glasses

### Setup

1. Install the **Meta AI** app on your iPhone
2. Pair your glasses via Bluetooth
3. Enable **Developer Mode**: Meta AI → Settings → your glasses → Developer Mode → ON
4. Restart glasses (hold button 15s → power off → press to power on)
5. Register your app on [developers.meta.com](https://developers.meta.com):
   - Create app → select "Wearables"
   - iOS config: Team ID + Bundle ID (`com.claudevision.app`)
   - Create version → assign to release channel
6. In VisionClaude: Settings → **Connect Glasses via Meta AI** → Approve
7. Switch camera source to **Meta Ray-Ban** → live video feed starts

The DAT SDK is included via SPM from [facebook/meta-wearables-dat-ios](https://github.com/facebook/meta-wearables-dat-ios).

### Developer Terms

By using the Wearables Device Access Toolkit, you agree to the [Meta Wearables Developer Terms](https://wearables.developer.meta.com/terms) and [Acceptable Use Policy](https://wearables.developer.meta.com/acceptable-use-policy).

## ElevenLabs Voices

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

Uses `eleven_flash_v2_5` model with streaming for lowest latency.

## Manual Setup

### Gateway Server

```bash
cd ClaudeVision/server
cp .env.example .env        # Add your ANTHROPIC_API_KEY
npm install
npm run build
npm start
```

### iOS App

```bash
brew install xcodegen
cd ClaudeVision/ios
xcodegen generate
open ClaudeVision.xcodeproj
# Signing & Capabilities → select your Team
# Connect iPhone via USB → select in device dropdown
# ⌘R to build and run
```

## License

MIT

## Disclaimer

This project is not affiliated with, endorsed by, or officially connected to Anthropic, PBC or Meta Platforms, Inc. Claude is a trademark of Anthropic. Meta, Ray-Ban, and the Meta Wearables Device Access Toolkit are trademarks of Meta Platforms, Inc. ElevenLabs is a trademark of ElevenLabs, Inc.

---

<p align="center">
Built by <a href="https://github.com/mrdulasolutions">@mrdulasolutions</a>
</p>
