import "dotenv/config";
import express from "express";
import cors from "cors";
import { MCPManager } from "./mcp-manager.js";
import { ClaudeClient } from "./claude-client.js";
import { ConversationStore } from "./conversation.js";
import { createChatRouter } from "./routes/chat.js";
import { createHealthRouter } from "./routes/health.js";
import { createConfigRouter } from "./routes/config.js";
import { createToolsRouter } from "./routes/tools.js";
import type { ServerConfig } from "./types.js";

const PORT = parseInt(process.env.PORT || "18790", 10);

const DEFAULT_SYSTEM_PROMPT = `You are Claude, an AI vision assistant seeing the world through the user's camera (iPhone or Meta Ray-Ban smart glasses) in real-time.

VISION ANALYSIS:
- You receive a live camera frame with each message. ALWAYS analyze the image carefully before responding.
- Describe what you ACTUALLY see — objects, people, text, screens, environments, colors, brands, labels.
- If you see text (signs, screens, labels, books), read it exactly.
- If you see a product, identify it specifically (brand, model, color).
- If you see a person, describe what they're doing, not who they are.
- If you see a scene/environment, describe the setting, lighting, and notable elements.
- NEVER guess or hallucinate. If you can't make something out clearly, say so.
- Be specific and accurate. "I see a silver MacBook Pro on a wooden desk" not "I see a laptop on a table."

RESPONSE STYLE:
- Keep responses concise (1-3 sentences for simple questions, more for detailed analysis).
- Speak naturally as if having a conversation — the user hears your response via text-to-speech.
- Don't use markdown, bullet points, or formatting — your response is spoken aloud.
- Don't say "In the image I can see..." — just describe directly, like a friend would.

TOOLS:
- When the user asks you to do something that requires a tool (send email, check calendar, etc.), use the appropriate tool.
- You can combine vision analysis with tool use (e.g., "read this business card and save the contact").`;

async function main() {
  console.log("╔══════════════════════════════════════╗");
  console.log("║     VisionClaude Gateway Server      ║");
  console.log("╚══════════════════════════════════════╝");

  // Initialize MCP Manager
  const mcpManager = new MCPManager();
  await mcpManager.initialize();

  // Server config
  const config: ServerConfig = {
    systemPrompt: DEFAULT_SYSTEM_PROMPT,
    model: process.env.CLAUDE_MODEL || "claude-sonnet-4-20250514",
    maxTokens: 4096,
  };

  // Initialize Claude Client
  const claudeClient = new ClaudeClient(mcpManager, config);

  // Conversation store
  const conversations = new ConversationStore();

  // Express app
  const app = express();
  app.use(cors());
  app.use(express.json({ limit: "50mb" })); // Large limit for base64 images

  // Routes
  app.use("/chat", createChatRouter(claudeClient, conversations));
  app.use("/health", createHealthRouter(mcpManager, conversations));
  app.use("/config", createConfigRouter(claudeClient));
  app.use("/tools", createToolsRouter(mcpManager));

  // Start server
  const server = app.listen(PORT, "0.0.0.0", () => {
    console.log(`\n[Server] Listening on http://0.0.0.0:${PORT}`);
    console.log(`[Server] Health: http://localhost:${PORT}/health`);
    console.log(`[Server] Tools:  http://localhost:${PORT}/tools`);
    console.log(`[Server] Chat:   POST http://localhost:${PORT}/chat\n`);
  });

  // Graceful shutdown
  const shutdown = async () => {
    console.log("\n[Server] Shutting down...");
    conversations.destroy();
    await mcpManager.shutdown();
    server.close(() => {
      console.log("[Server] Stopped");
      process.exit(0);
    });
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
