import type Anthropic from "@anthropic-ai/sdk";

// ── Chat API ──

export interface ChatRequest {
  text: string;
  images?: string[]; // base64 JPEG strings
  conversation_id?: string;
  // "fast" (default) answers with the low-latency model; "smart" escalates
  // to the more capable one (e.g. the user asked to "tell me more").
  tier?: "fast" | "smart";
}

export interface ToolCallResult {
  name: string;
  result: unknown;
}

export interface ChatResponse {
  text: string;
  tool_calls: ToolCallResult[];
  conversation_id: string;
}

// ── Config API ──

export interface ConfigUpdate {
  system_prompt?: string;
  model?: string;
  fast_model?: string;
  max_tokens?: number;
}

export interface ServerConfig {
  systemPrompt: string;
  model: string;      // "smart" tier — escalations
  fastModel: string;  // "fast" tier — default for voice questions (latency)
  maxTokens: number;
}

// ── MCP ──

export interface MCPServerConfig {
  // Local stdio server
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  // Remote HTTP/SSE server
  url?: string;
  headers?: Record<string, string>;
}

export interface MCPConfigFile {
  mcpServers: Record<string, MCPServerConfig>;
}

// Claude Desktop config format
export interface ClaudeDesktopConfig {
  mcpServers?: Record<string, MCPServerConfig>;
}

export interface DiscoveredTool {
  serverName: string;
  name: string;
  description?: string;
  inputSchema: Record<string, unknown>;
}

// ── Conversation ──

export type MessageParam = Anthropic.MessageParam;
export type ContentBlock = Anthropic.ContentBlock;
export type ToolUseBlock = Anthropic.ToolUseBlock;
export type ToolResultBlockParam = Anthropic.ToolResultBlockParam;
export type Tool = Anthropic.Tool;
