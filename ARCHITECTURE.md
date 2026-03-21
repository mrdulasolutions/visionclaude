# VisionClaw → VisionClaude Architecture Plan

## Overview

Retool VisionClaw to replace Gemini Live API + OpenClaw with Claude API + Cowork MCP tools.

```
Meta Ray-Ban Glasses (or phone camera)
       |
       | video frames + mic audio
       v
iOS App (VisionClaude)
       |
       | Local STT (Apple Speech) converts audio → text
       | JPEG frames (~1fps) captured from camera
       |
       | HTTP POST /chat  { text, images[], conversation_id }
       v
Claude Gateway Server (Node.js, runs on Mac)
       |
       |-- Claude Messages API (with vision)
       |      - Sends text + base64 images
       |      - Receives text response + tool_use blocks
       |
       |-- MCP Tool Router
       |      - When Claude returns tool_use, invokes MCP servers
       |      - Slack, Gmail, Calendar, HubSpot, Apollo, etc.
       |      - Returns tool results back to Claude for final response
       |
       v
Response { text, tool_results[] }
       |
       v
iOS App → AVSpeechSynthesizer (TTS) → Speaker
```

## Component Breakdown

### 1. Claude Gateway Server (Node.js)

**Location:** `samples/CameraAccess/server/claude-gateway/`

**Purpose:** Sits on the user's Mac (same network as phone). Accepts requests from the iOS app, orchestrates Claude API calls with vision, and routes tool calls through MCP servers.

**Endpoints:**

- `POST /chat` — Main conversation endpoint
  - Body: `{ text: string, images: string[] (base64 JPEG), conversation_id: string }`
  - Response: `{ text: string, tool_calls: [{ name, result }], conversation_id: string }`
  - Internally manages message history per conversation_id
  - Sends images as Claude vision content blocks
  - Handles tool_use → tool_result loop automatically

- `GET /health` — Health check (drop-in compatible with OpenClaw)

- `POST /config` — Update system prompt, model, etc. at runtime

**Tech stack:**
- `@anthropic-ai/sdk` for Claude API
- `@modelcontextprotocol/sdk` for MCP client
- Express.js for HTTP server
- Conversation history stored in-memory (per session)

**MCP Integration:**
- Reads MCP server configs from a JSON file (similar to claude_desktop_config.json)
- Spawns MCP server processes and connects as client
- When Claude returns `tool_use`, looks up the tool in connected MCP servers and invokes it
- Returns `tool_result` back to Claude for the final text response

**Tool Declaration:**
- On startup, connects to all configured MCP servers
- Collects their tool schemas
- Passes them to Claude as `tools` in the Messages API
- Claude decides when to call them based on conversation context

### 2. iOS App Changes

#### ClaudeConfig.swift (replaces GeminiConfig)
- `gatewayHost` — Mac's Bonjour hostname (e.g., `http://Matts-Mac.local`)
- `gatewayPort` — default 18790 (avoids conflict with OpenClaw's 18789)
- `apiKey` — Anthropic API key (passed to gateway, or gateway has its own)
- `systemInstruction` — system prompt for Claude
- `videoFrameInterval` — still ~1fps
- `videoJPEGQuality` — still 0.5

#### ClaudeBridge.swift (replaces OpenClawBridge)
- HTTP client that talks to the gateway's `/chat` endpoint
- Sends text + accumulated images
- Manages conversation_id for session continuity
- Simpler than OpenClawBridge — no separate tool routing needed

#### SpeechManager.swift (new)
- **STT:** Apple Speech framework (`SFSpeechRecognizer`)
  - Continuous recognition from mic audio
  - Returns transcribed text in real-time
  - Handles interim vs final results
- **TTS:** `AVSpeechSynthesizer`
  - Speaks Claude's text responses
  - Supports interruption (user starts talking → stop TTS)
  - Voice selection (Siri voices for natural sound)

#### ClaudeSessionViewModel.swift (replaces GeminiSessionViewModel)
- Orchestrates the full pipeline:
  1. SpeechManager captures mic → transcribes text
  2. Camera captures frames → accumulates latest frame
  3. On speech end (pause detected), sends text + latest frame(s) to ClaudeBridge
  4. ClaudeBridge calls gateway → Claude responds
  5. Response text → SpeechManager TTS → speaker
- Manages session state, transcripts, tool call status

#### AudioManager.swift changes
- Simplified: no longer sends raw PCM to WebSocket
- Still handles audio session setup (voiceChat/videoChat modes)
- Still handles interruption recovery
- Mic audio goes to SpeechManager for STT instead of Gemini

### 3. What Stays the Same

- **Camera pipeline** — DAT SDK video stream + iPhone camera mode unchanged
- **WebRTC streaming** — Live POV sharing to browser stays as-is
- **Views** — Mostly same UI, just wired to ClaudeSessionViewModel
- **Settings UI** — Updated labels (Claude Gateway instead of OpenClaw)

## Key Design Decisions

### Why local STT/TTS instead of streaming audio?
Claude doesn't have a real-time WebSocket audio API like Gemini Live. The trade-off is slightly higher latency (STT → API call → TTS vs. native audio streaming), but we get Claude's superior reasoning, vision, and tool ecosystem. Apple's on-device speech recognition is fast (~200ms) and the API call adds ~1-2s, so total latency should be 2-4s.

### Why a gateway server instead of direct API calls from iOS?
1. MCP servers run as local processes — can't spawn them on iOS
2. Keeps the API key on the Mac, not on the phone
3. Gateway can manage complex tool_use → tool_result loops
4. Easy to add more MCP servers without app changes
5. Same gateway can serve Android app later

### Why not keep Gemini for audio + use Claude for tools?
Simpler architecture with one AI backend. Avoids coordinating two AI systems. Claude's vision is excellent and system prompts give consistent behavior across voice and tool interactions.

## Migration Path

1. Build gateway server first (can test with curl)
2. Add SpeechManager to iOS app
3. Create ClaudeBridge + ClaudeSessionViewModel
4. Wire up to existing views
5. Test end-to-end
6. Keep Gemini code in place (feature flag) for A/B comparison
