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

const DEFAULT_SYSTEM_PROMPT = `You are Claude, an AI assistant with vision capabilities and access to various tools.
You can see images from the user's camera and help them with tasks using your connected tools.
Be concise and helpful. When you see something in an image, describe it naturally.
When the user asks you to do something that requires a tool, use the appropriate tool.`;

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
