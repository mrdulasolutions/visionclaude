import Anthropic from "@anthropic-ai/sdk";
import type { MCPManager } from "./mcp-manager.js";
import type {
  MessageParam,
  ToolUseBlock,
  ToolResultBlockParam,
  ServerConfig,
  ToolCallResult,
} from "./types.js";

const MAX_TOOL_ITERATIONS = 10;

export class ClaudeClient {
  private anthropic: Anthropic;
  private mcpManager: MCPManager;
  private config: ServerConfig;

  constructor(mcpManager: MCPManager, config: ServerConfig) {
    this.anthropic = new Anthropic();
    this.mcpManager = mcpManager;
    this.config = config;
  }

  updateConfig(updates: Partial<ServerConfig>): void {
    Object.assign(this.config, updates);
  }

  getConfig(): ServerConfig {
    return { ...this.config };
  }

  async chat(
    history: MessageParam[],
    text: string,
    images?: string[]
  ): Promise<{ responseText: string; toolCalls: ToolCallResult[] }> {
    // Build the user message content
    const content: Anthropic.ContentBlockParam[] = [];

    // Add images as vision content blocks
    if (images && images.length > 0) {
      for (const base64 of images) {
        content.push({
          type: "image",
          source: {
            type: "base64",
            media_type: "image/jpeg",
            data: base64,
          },
        });
      }
    }

    // Add text
    if (text) {
      content.push({ type: "text", text });
    }

    // Append user message to history
    const userMessage: MessageParam = { role: "user", content };
    const messages = [...history, userMessage];

    // Get tools from MCP
    const tools = this.mcpManager.getToolsForClaude();

    // Tool use loop
    const allToolCalls: ToolCallResult[] = [];
    let currentMessages = messages;

    for (let iteration = 0; iteration < MAX_TOOL_ITERATIONS; iteration++) {
      const response = await this.anthropic.messages.create({
        model: this.config.model,
        max_tokens: this.config.maxTokens,
        system: this.config.systemPrompt,
        messages: currentMessages,
        ...(tools.length > 0 ? { tools } : {}),
      });

      // Check if response contains tool use
      const toolUseBlocks = response.content.filter(
        (block): block is ToolUseBlock => block.type === "tool_use"
      );

      if (toolUseBlocks.length === 0 || response.stop_reason === "end_turn") {
        // Final response — extract text
        const textBlocks = response.content
          .filter((block) => block.type === "text")
          .map((block) => (block as Anthropic.TextBlock).text);

        const responseText = textBlocks.join("\n");

        // Return the messages to append to history (user + assistant)
        return { responseText, toolCalls: allToolCalls };
      }

      // Process tool calls
      const assistantMessage: MessageParam = {
        role: "assistant",
        content: response.content,
      };

      const toolResults: ToolResultBlockParam[] = [];

      for (const toolUse of toolUseBlocks) {
        console.log(`[Claude] Tool call: ${toolUse.name}`);
        try {
          const result = await this.mcpManager.invokeTool(
            toolUse.name,
            toolUse.input as Record<string, unknown>
          );
          allToolCalls.push({ name: toolUse.name, result });
          toolResults.push({
            type: "tool_result",
            tool_use_id: toolUse.id,
            content: JSON.stringify(result),
          });
        } catch (err) {
          const errorMsg =
            err instanceof Error ? err.message : "Unknown error";
          console.error(`[Claude] Tool error (${toolUse.name}):`, errorMsg);
          allToolCalls.push({ name: toolUse.name, result: { error: errorMsg } });
          toolResults.push({
            type: "tool_result",
            tool_use_id: toolUse.id,
            content: JSON.stringify({ error: errorMsg }),
            is_error: true,
          });
        }
      }

      const toolResultMessage: MessageParam = {
        role: "user",
        content: toolResults,
      };

      // Continue the loop with tool results
      currentMessages = [
        ...currentMessages,
        assistantMessage,
        toolResultMessage,
      ];
    }

    // Exceeded max iterations
    return {
      responseText:
        "I attempted to use several tools but reached the maximum number of iterations. Please try again with a simpler request.",
      toolCalls: allToolCalls,
    };
  }
}
