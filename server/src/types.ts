import type Anthropic from "@anthropic-ai/sdk";

// ── Chat API ──

export interface ChatRequest {
  text: string;
  images?: string[]; // base64 JPEG strings
  conversation_id?: string;
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
  max_tokens?: number;
}

export interface ServerConfig {
  systemPrompt: string;
  model: string;
  maxTokens: number;
}

// ── MCP ──

export interface MCPServerConfig {
  command: string;
  args?: string[];
  env?: Record<string, string>;
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
