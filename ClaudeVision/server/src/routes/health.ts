import { Router } from "express";
import type { MCPManager } from "../mcp-manager.js";
import type { ConversationStore } from "../conversation.js";

export function createHealthRouter(
  mcpManager: MCPManager,
  conversations: ConversationStore
): Router {
  const router = Router();

  router.get("/", async (_req, res) => {
    const servers = mcpManager.getServerStatus();
    const toolCount = mcpManager.getAllDiscoveredTools().length;

    res.json({
      status: "ok",
      uptime: process.uptime(),
      mcp: {
        servers,
        totalTools: toolCount,
      },
      conversations: conversations.size,
    });
  });

  return router;
}
