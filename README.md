```
         ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗
        ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝
        ██║     ██║     ███████║██║   ██║██║  ██║█████╗
        ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝
        ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗
         ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝

        ██╗   ██╗██╗███████╗██╗ ██████╗ ███╗   ██╗
        ██║   ██║██║██╔════╝██║██╔═══██╗████╗  ██║
        ██║   ██║██║███████╗██║██║   ██║██╔██╗ ██║
        ╚██╗ ██╔╝██║╚════██║██║██║   ██║██║╚██╗██║
         ╚████╔╝ ██║███████║██║╚██████╔╝██║ ╚████║
          ╚═══╝  ╚═╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝

        Let Claude see the world through your eyes
```

**ClaudeVision** turns your iPhone (or Meta Ray-Ban glasses) into Claude's eyes and ears. Point your camera, speak naturally, and Claude sees what you see — then responds with voice, using your connected tools like email, calendar, and more.

## How It Works

```
Phone Camera  →  Gateway Server  →  Claude API
Your Voice    →    (your Mac)    →  MCP Tools
Claude Reply  ←                  ←  (email, etc.)
```

1. **You speak** — on-device speech recognition transcribes your voice
2. **Camera captures** — latest frame grabbed as JPEG (~1fps)
3. **Gateway sends** — text + image to Claude via the Anthropic API
4. **Claude responds** — with vision understanding + tool actions
5. **You hear** — text-to-speech reads Claude's response aloud
6. **Loop repeats** — continuous conversation, hands-free

## Quick Start

```bash
git clone https://github.com/mrdulasolutions/visionclaude.git
cd visionclaude
./setup.sh
```

The interactive setup will walk you through everything:
- Check and install dependencies
- Configure your Anthropic API key
- Build the gateway server
- Generate the iOS Xcode project

## Requirements

| Requirement | Version |
|---|---|
| macOS | 13+ |
| Node.js | 18+ |
| Xcode | 15+ (for iOS app) |
| iPhone | iOS 17+ |
| Anthropic API Key | [Get one here](https://console.anthropic.com/settings/keys) |

## Architecture

### Gateway Server (Node.js)

Runs on your Mac. Bridges the iOS app to Claude's API and routes tool calls through MCP servers.

```
server/
├── src/
│   ├── index.ts              # Express entry point (port 18790)
│   ├── claude-client.ts      # Claude Messages API + vision + tool loop
│   ├── mcp-manager.ts        # MCP server lifecycle & tool discovery
│   ├── conversation.ts       # In-memory conversation store
│   └── routes/
│       ├── chat.ts           # POST /chat — main endpoint
│       ├── health.ts         # GET /health — status check
│       ├── tools.ts          # GET /tools — list MCP tools
│       └── config.ts         # GET/POST /config — runtime config
```

**Key feature:** Auto-discovers MCP tools from your Claude Desktop config. Any MCP server you add to Claude Desktop automatically becomes available through the gateway.

### iOS App (Swift/SwiftUI)

Runs on your iPhone. Captures camera + voice, sends to gateway, speaks responses.

```
ios/ClaudeVision/
├── Models/
│   ├── ClaudeConfig.swift        # Gateway connection settings
│   └── ChatModels.swift          # API request/response types
├── Services/
│   ├── ClaudeBridge.swift        # HTTP client → gateway
│   ├── SpeechManager.swift       # STT (Apple Speech) + TTS
│   ├── CameraManager.swift       # AVCaptureSession frame capture
│   ├── FrameSource.swift         # Protocol for camera/Ray-Ban
│   └── AudioSessionManager.swift # Audio session handling
├── ViewModels/
│   └── SessionViewModel.swift    # Pipeline orchestrator
└── Views/
    ├── ContentView.swift         # Camera preview + mic button
    ├── TranscriptView.swift      # Conversation history
    └── SettingsView.swift        # Gateway config UI
```

## API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Server status + connected MCP tool count |
| `/tools` | GET | List all discovered MCP tools |
| `/chat` | POST | Send text + images, get Claude's response |
| `/config` | GET/POST | View or update system prompt, model |

### Chat Request

```json
{
  "text": "What do you see?",
  "images": ["<base64 JPEG>"],
  "conversation_id": "optional-session-id"
}
```

### Chat Response

```json
{
  "text": "I can see a laptop on a desk with...",
  "tool_calls": [{"name": "read_emails", "result": {...}}],
  "conversation_id": "generated-session-id"
}
```

## Manual Setup

If you prefer not to use the setup script:

### Gateway Server

```bash
cd server
cp .env.example .env
# Edit .env and add your ANTHROPIC_API_KEY
npm install
npm run build
npm start
```

### iOS App

```bash
brew install xcodegen
cd ios
xcodegen generate
open ClaudeVision.xcodeproj
# Set your Development Team in Signing & Capabilities
# Build and run on your iPhone (⌘R)
```

## MCP Tools

ClaudeVision automatically discovers tools from your Claude Desktop configuration at:

```
~/Library/Application Support/Claude/claude_desktop_config.json
```

Any MCP server configured there will be available through voice commands. For example:
- "Check my email" → uses email MCP tools
- "What's on my calendar?" → uses calendar MCP tools
- "Send a message to..." → uses messaging MCP tools

## License

MIT

## Disclaimer

This project is not affiliated with, endorsed by, or officially connected to Anthropic, PBC. Claude is a trademark of Anthropic.

---

Built by [@mrdulasolutions](https://github.com/mrdulasolutions)
