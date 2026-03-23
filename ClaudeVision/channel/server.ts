#!/usr/bin/env bun
/**
 * VisionClaude Channel for Claude Code.
 *
 * Bridges an iOS app (camera + voice + Meta Ray-Ban glasses) into a running
 * Claude Code session via the MCP channel contract. Messages from the phone
 * arrive over WebSocket/HTTP and are pushed as channel notifications. Claude
 * replies via the reply tool, which forwards back to the iOS app.
 *
 * Supports:
 *  - Text messages (voice transcriptions)
 *  - Image uploads (camera frames, glasses frames)
 *  - Voice + image combo (describe what I see)
 *  - File attachments
 *  - ElevenLabs TTS for voice responses
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from '@modelcontextprotocol/sdk/types.js'
import { readFileSync, writeFileSync, mkdirSync, statSync, copyFileSync, existsSync } from 'fs'
import { homedir } from 'os'
import { join, extname, basename } from 'path'
import type { ServerWebSocket } from 'bun'

// ── Config ──────────────────────────────────────────────────────────────────
const PORT = Number(process.env.VISIONCLAUDE_PORT ?? 18790)
const STATE_DIR = join(homedir(), '.claude', 'channels', 'visionclaude')
const INBOX_DIR = join(STATE_DIR, 'inbox')    // images from phone
const OUTBOX_DIR = join(STATE_DIR, 'outbox')  // files from Claude
const ENV_FILE = join(STATE_DIR, '.env')

// Load .env for ElevenLabs key
try {
  for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
    const m = line.match(/^(\w+)=(.*)$/)
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2]
  }
} catch {}

const ELEVENLABS_KEY = process.env.ELEVENLABS_API_KEY ?? ''
const ELEVENLABS_VOICE = process.env.ELEVENLABS_VOICE_ID ?? 'XB0fDUnXU5powFXDhCwa' // Charlotte
const ELEVENLABS_MODEL = 'eleven_flash_v2_5'

// ── Types ───────────────────────────────────────────────────────────────────
type WireOut =
  | { type: 'reply'; id: string; text: string; audio_url?: string }
  | { type: 'status'; status: string }
  | { type: 'thinking'; text: string }

const clients = new Set<ServerWebSocket<unknown>>()
let seq = 0

function nextId() { return `vc${Date.now()}-${++seq}` }

function broadcast(m: WireOut) {
  const data = JSON.stringify(m)
  for (const ws of clients) if (ws.readyState === 1) ws.send(data)
}

function log(msg: string) {
  process.stderr.write(`[visionclaude] ${msg}\n`)
}

// ── ElevenLabs TTS ──────────────────────────────────────────────────────────
async function generateTTS(text: string): Promise<string | undefined> {
  if (!ELEVENLABS_KEY) return undefined
  try {
    const resp = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_VOICE}`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'xi-api-key': ELEVENLABS_KEY,
        },
        body: JSON.stringify({
          text: text.slice(0, 2000),
          model_id: ELEVENLABS_MODEL,
          voice_settings: { stability: 0.5, similarity_boost: 0.75 },
        }),
      }
    )
    if (!resp.ok) {
      log(`TTS error: ${resp.status}`)
      return undefined
    }
    mkdirSync(OUTBOX_DIR, { recursive: true })
    const buf = Buffer.from(await resp.arrayBuffer())
    const name = `tts-${Date.now()}.mp3`
    writeFileSync(join(OUTBOX_DIR, name), buf)
    return `/files/${name}`
  } catch (e) {
    log(`TTS error: ${e}`)
    return undefined
  }
}

// ── MCP Channel Server ──────────────────────────────────────────────────────
const mcp = new Server(
  { name: 'visionclaude', version: '1.0.0' },
  {
    capabilities: {
      tools: {},
      experimental: { 'claude/channel': {} },
    },
    instructions: [
      'VisionClaude bridges an iOS app with camera, voice, and Meta Ray-Ban glasses.',
      '',
      'Messages arrive as <channel source="visionclaude" ...>.',
      'If the tag has a file_path attribute, Read that file — it is an image from the phone camera or glasses.',
      '',
      'IMPORTANT VISION INSTRUCTIONS:',
      '- When an image is attached, ALWAYS describe what you see with high specificity.',
      '- Read all visible text exactly (signs, screens, labels, brands, prices).',
      '- Use proper nouns: "silver MacBook Pro" not "a laptop", "iPhone 15 Pro" not "a phone".',
      '- Note spatial relationships: "to the left of", "behind the", "on top of".',
      '- Be conversational — the user is wearing glasses or holding a phone, speak naturally.',
      '',
      'Reply ONLY through the reply tool — your transcript output never reaches the iOS app.',
      'Keep replies concise (1-3 sentences) for voice responses unless asked for detail.',
      `The iOS app connects via WebSocket at ws://localhost:${PORT}/ws.`,
    ].join('\n'),
  },
)

// ── Tools: reply + reply_with_voice ─────────────────────────────────────────
mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'reply',
      description: 'Send a text reply to the VisionClaude iOS app. If ElevenLabs is configured, TTS audio is generated automatically.',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'The reply text' },
          reply_to: { type: 'string', description: 'Message ID to reply to (optional)' },
          files: { type: 'array', items: { type: 'string' }, description: 'File paths to attach' },
        },
        required: ['text'],
      },
    },
    {
      name: 'edit_message',
      description: 'Edit a previously sent reply.',
      inputSchema: {
        type: 'object',
        properties: {
          message_id: { type: 'string' },
          text: { type: 'string' },
        },
        required: ['message_id', 'text'],
      },
    },
  ],
}))

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  const args = (req.params.arguments ?? {}) as Record<string, unknown>
  try {
    switch (req.params.name) {
      case 'reply': {
        const text = args.text as string
        const id = nextId()

        // Generate TTS audio in parallel
        const audioPromise = generateTTS(text)

        // Handle file attachments
        const files = (args.files as string[] | undefined) ?? []
        if (files[0]) {
          mkdirSync(OUTBOX_DIR, { recursive: true })
          const ext = extname(files[0]).toLowerCase()
          const out = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}${ext}`
          copyFileSync(files[0], join(OUTBOX_DIR, out))
        }

        const audioUrl = await audioPromise
        broadcast({ type: 'reply', id, text, audio_url: audioUrl })
        log(`→ reply: ${text.slice(0, 80)}${text.length > 80 ? '...' : ''}`)

        return { content: [{ type: 'text', text: `sent ${id}${audioUrl ? ' (with audio)' : ''}` }] }
      }

      case 'edit_message': {
        broadcast({ type: 'reply', id: args.message_id as string, text: args.text as string })
        return { content: [{ type: 'text', text: 'ok' }] }
      }

      default:
        return { content: [{ type: 'text', text: `unknown: ${req.params.name}` }], isError: true }
    }
  } catch (err) {
    return {
      content: [{ type: 'text', text: `${req.params.name}: ${err instanceof Error ? err.message : err}` }],
      isError: true,
    }
  }
})

// Connect MCP over stdio
await mcp.connect(new StdioServerTransport())

// ── Deliver messages from iOS to Claude ─────────────────────────────────────
function deliver(
  id: string,
  text: string,
  source: 'iphone' | 'rayban',
  image?: { path: string; name: string }
): void {
  void mcp.notification({
    method: 'notifications/claude/channel',
    params: {
      content: text || (image ? `(image from ${source})` : '(empty)'),
      meta: {
        chat_id: source,
        message_id: id,
        user: 'phone',
        source,
        ts: new Date().toISOString(),
        ...(image ? { file_path: image.path } : {}),
      },
    },
  })
  log(`← ${source}: ${text.slice(0, 60)}${image ? ` [+image: ${image.name}]` : ''}`)
}

// ── HTTP + WebSocket Server ─────────────────────────────────────────────────
function mime(ext: string) {
  const m: Record<string, string> = {
    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
    '.gif': 'image/gif', '.webp': 'image/webp', '.mp3': 'audio/mpeg',
    '.mp4': 'video/mp4', '.pdf': 'application/pdf', '.txt': 'text/plain',
  }
  return m[ext] ?? 'application/octet-stream'
}

Bun.serve({
  port: PORT,
  hostname: '0.0.0.0',  // allow LAN connections from phone
  fetch(req, server) {
    const url = new URL(req.url)

    // ── WebSocket upgrade ───────────────────────────────────────────────
    if (url.pathname === '/ws') {
      if (server.upgrade(req)) return
      return new Response('upgrade failed', { status: 400 })
    }

    // ── Health check ────────────────────────────────────────────────────
    if (url.pathname === '/health') {
      return Response.json({
        status: 'ok',
        mode: 'channel',
        clients: clients.size,
        tts: !!ELEVENLABS_KEY,
      })
    }

    // ── Serve files (TTS audio, attachments) ────────────────────────────
    if (url.pathname.startsWith('/files/')) {
      const f = url.pathname.slice(7)
      if (f.includes('..') || f.includes('/')) return new Response('bad', { status: 400 })
      try {
        return new Response(readFileSync(join(OUTBOX_DIR, f)), {
          headers: {
            'content-type': mime(extname(f).toLowerCase()),
            'access-control-allow-origin': '*',
          },
        })
      } catch {
        return new Response('404', { status: 404 })
      }
    }

    // ── Image upload from iOS app ───────────────────────────────────────
    if (url.pathname === '/upload' && req.method === 'POST') {
      return (async () => {
        const form = await req.formData()
        const id = String(form.get('id') ?? nextId())
        const text = String(form.get('text') ?? '')
        const source = (String(form.get('source') ?? 'iphone')) as 'iphone' | 'rayban'
        const f = form.get('image') ?? form.get('file')

        let image: { path: string; name: string } | undefined
        if (f instanceof File && f.size > 0) {
          mkdirSync(INBOX_DIR, { recursive: true })
          const ext = extname(f.name).toLowerCase() || '.jpg'
          const path = join(INBOX_DIR, `${Date.now()}-${source}${ext}`)
          writeFileSync(path, Buffer.from(await f.arrayBuffer()))
          image = { path, name: f.name }
          log(`📷 saved ${source} image: ${path} (${(f.size / 1024).toFixed(0)}KB)`)
        }

        deliver(id, text, source, image)
        return new Response(null, { status: 204 })
      })()
    }

    // ── Text-only message via POST ──────────────────────────────────────
    if (url.pathname === '/message' && req.method === 'POST') {
      return (async () => {
        const body = await req.json() as { text?: string; source?: string; id?: string }
        const id = body.id ?? nextId()
        const source = (body.source ?? 'iphone') as 'iphone' | 'rayban'
        deliver(id, body.text ?? '', source)
        return Response.json({ ok: true, id })
      })()
    }

    // ── CORS preflight ──────────────────────────────────────────────────
    if (req.method === 'OPTIONS') {
      return new Response(null, {
        headers: {
          'access-control-allow-origin': '*',
          'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'content-type',
        },
      })
    }

    // ── Root: show status page ──────────────────────────────────────────
    if (url.pathname === '/') {
      return new Response(STATUS_HTML, {
        headers: { 'content-type': 'text/html; charset=utf-8' },
      })
    }

    return new Response('404', { status: 404 })
  },

  websocket: {
    open: ws => {
      clients.add(ws)
      log(`📱 client connected (${clients.size} total)`)
      ws.send(JSON.stringify({ type: 'status', status: 'connected' }))
    },
    close: ws => {
      clients.delete(ws)
      log(`📱 client disconnected (${clients.size} total)`)
    },
    message: (_, raw) => {
      try {
        const msg = JSON.parse(String(raw)) as {
          id?: string
          text?: string
          source?: string
          image?: string  // base64
        }
        const id = msg.id ?? nextId()
        const source = (msg.source ?? 'iphone') as 'iphone' | 'rayban'

        // If image is included as base64, save to disk
        let image: { path: string; name: string } | undefined
        if (msg.image) {
          mkdirSync(INBOX_DIR, { recursive: true })
          const buf = Buffer.from(msg.image, 'base64')
          const path = join(INBOX_DIR, `${Date.now()}-${source}.jpg`)
          writeFileSync(path, buf)
          image = { path, name: `${source}-frame.jpg` }
          log(`📷 saved ${source} frame via WS (${(buf.length / 1024).toFixed(0)}KB)`)
        }

        if (msg.text?.trim() || image) {
          deliver(id, msg.text?.trim() ?? '', source, image)
        }
      } catch (e) {
        log(`WS parse error: ${e}`)
      }
    },
  },
})

log(`🚀 VisionClaude channel running on http://0.0.0.0:${PORT}`)
log(`   WebSocket: ws://localhost:${PORT}/ws`)
log(`   Health:    http://localhost:${PORT}/health`)
log(`   Upload:    POST http://localhost:${PORT}/upload`)
log(`   TTS:       ${ELEVENLABS_KEY ? '✅ ElevenLabs configured' : '❌ No ElevenLabs key'}`)

// ── Status HTML ─────────────────────────────────────────────────────────────
const STATUS_HTML = `<!doctype html>
<meta charset="utf-8"><title>VisionClaude Channel</title>
<style>
  body { font-family: -apple-system, sans-serif; max-width: 600px; margin: 40px auto; padding: 20px; background: #1a1a2e; color: #e0e0e0; }
  h1 { color: #E87B35; font-size: 24px; }
  .status { background: #16213e; padding: 16px; border-radius: 8px; margin: 16px 0; }
  .ok { color: #4ade80; } .warn { color: #facc15; }
  code { background: #0f3460; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
  a { color: #E87B35; }
</style>
<h1>🕶️ VisionClaude Channel</h1>
<div class="status">
  <p><span class="ok">●</span> Channel server running</p>
  <p>Mode: <strong>Claude Code Channel</strong> (direct session integration)</p>
  <p>Port: <code>${PORT}</code></p>
  <p>WebSocket: <code>ws://localhost:${PORT}/ws</code></p>
  <p>TTS: ${ELEVENLABS_KEY ? '<span class="ok">● ElevenLabs configured</span>' : '<span class="warn">● No ElevenLabs key</span>'}</p>
</div>
<div class="status">
  <h3>How it works</h3>
  <p>Your iOS app connects via WebSocket. Messages are pushed directly into your running Claude Code session. Claude has full access to ALL your MCP tools and skills.</p>
  <p>No separate API key. No gateway. Direct integration.</p>
</div>
`
