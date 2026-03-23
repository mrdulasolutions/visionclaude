---
name: visionclaude-configure
description: Configure VisionClaude channel settings — ElevenLabs API key, voice, and port
---

# Configure VisionClaude Channel

The VisionClaude channel stores its settings in `~/.claude/channels/visionclaude/.env`.

## Setup Steps

1. **Create the env file** if it doesn't exist:
   ```
   mkdir -p ~/.claude/channels/visionclaude
   touch ~/.claude/channels/visionclaude/.env
   ```

2. **Set the ElevenLabs API key** for voice responses:
   ```
   ELEVENLABS_API_KEY=your_key_here
   ```

3. **Set the voice** (optional, defaults to Charlotte):
   Available voices:
   - `XB0fDUnXU5powFXDhCwa` — Charlotte (default, warm female)
   - `21m00Tcm4TlvDq8ikWAM` — Rachel (calm female)
   - `29vD33N1CtxCmqQRPOHJ` — Drew (male)
   - `2EiwWnXFnvU5JabPnv8n` — Clyde (deep male)
   - `EXAVITQu4vr4xnSDxMaL` — Sarah (soft female)
   - `MF3mGyEYCl7XYWbV9V6O` — Elli (young female)
   - `TxGEqnHWrfWFTfGW9XjX` — Josh (male)
   - `VR6AewLTigWG4xSOukaG` — Arnold (deep male)
   - `pNInz6obpgDQGcFmaJgB` — Adam (male)
   - `yoZ06aMxZJJ28mfd3POQ` — Sam (male)
   ```
   ELEVENLABS_VOICE_ID=XB0fDUnXU5powFXDhCwa
   ```

4. **Set the port** (optional, defaults to 18790):
   ```
   VISIONCLAUDE_PORT=18790
   ```

5. **Restart the channel** — Claude Code will re-spawn it automatically.

## Connecting the iOS App

1. Make sure your iPhone is on the same WiFi network as your Mac
2. Open VisionClaude on your phone
3. Go to Settings → Gateway Host
4. Enter your Mac's local IP and port (e.g., `192.168.1.100:18790`)
5. The app connects via WebSocket — you'll see "Connected" in the status bar
