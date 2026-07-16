import "dotenv/config";
import express from "express";
import cors from "cors";
import { MCPManager } from "./mcp-manager.js";
import { ClaudeClient } from "./claude-client.js";
import { ConversationStore } from "./conversation.js";
import { SkillLoader } from "./skill-loader.js";
import { gatewayAuth, rateLimiter, RequestQueue } from "./middleware.js";
import { showBanner, showServerInfo, c } from "./console-theme.js";
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
  // ── Show Banner ──
  showBanner();

  // ── Initialize MCP Manager ──
  const mcpManager = new MCPManager();
  await mcpManager.initialize();

  // ── Initialize Skill Loader ──
  const skillLoader = new SkillLoader();
  skillLoader.load();

  // ── Build system prompt with skills ──
  const systemPrompt = DEFAULT_SYSTEM_PROMPT + skillLoader.buildSystemPromptSection();

  // ── Server config ──
  const config: ServerConfig = {
    systemPrompt,
    // Smart tier: escalations ("tell me more"). The old default,
    // claude-sonnet-4-20250514, is deprecated (retires June 2026).
    model: process.env.CLAUDE_MODEL || "claude-sonnet-5",
    // Fast tier: the default for voice questions — lowest latency.
    fastModel: process.env.CLAUDE_FAST_MODEL || "claude-haiku-4-5",
    maxTokens: 4096,
  };

  // ── Initialize Claude Client ──
  const claudeClient = new ClaudeClient(mcpManager, config);

  // ── Conversation store ──
  const conversations = new ConversationStore();

  // ── Request queue (prevents concurrent Claude API races) ──
  const requestQueue = new RequestQueue(2); // max 2 concurrent API calls

  // ── Express app ──
  const app = express();
  app.use(cors());
  app.use(express.json({ limit: "50mb" }));

  // ── Security middleware ──
  app.use(gatewayAuth());    // Optional API key auth (set GATEWAY_API_KEY in .env)
  app.use(rateLimiter(30));  // 30 requests per minute per IP

  // ── Routes ──
  app.use("/chat", createChatRouter(claudeClient, conversations, requestQueue));
  app.use("/health", createHealthRouter(mcpManager, conversations, skillLoader));
  app.use("/config", createConfigRouter(claudeClient));
  app.use("/tools", createToolsRouter(mcpManager));

  // Skills endpoint
  app.get("/skills", (_req, res) => {
    res.json({
      skills: skillLoader.getSkillList(),
      count: skillLoader.count,
    });
  });

  // Skills reload endpoint
  app.post("/skills/reload", (_req, res) => {
    skillLoader.reload();
    // Update system prompt with new skills
    const newPrompt = DEFAULT_SYSTEM_PROMPT + skillLoader.buildSystemPromptSection();
    claudeClient.updateConfig({ systemPrompt: newPrompt });
    res.json({
      message: "Skills reloaded",
      skills: skillLoader.getSkillList(),
      count: skillLoader.count,
    });
  });

  // ── Start server ──
  const server = app.listen(PORT, "0.0.0.0", () => {
    const mcpServers = mcpManager.getServerNames();
    const toolCount = mcpManager.getToolsForClaude().length;
    showServerInfo(PORT, mcpServers.length, toolCount, skillLoader.count);
  });

  // ── Graceful shutdown ──
  const shutdown = async () => {
    console.log(c.orange("\n   ▸ Shutting down VisionClaude Gateway..."));
    conversations.destroy();
    await mcpManager.shutdown();
    server.close(() => {
      console.log(c.dim("   Gateway stopped.\n"));
      process.exit(0);
    });
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error(c.error("Fatal error:"), err);
  process.exit(1);
});
