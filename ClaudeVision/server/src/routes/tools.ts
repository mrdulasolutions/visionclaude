import { Router } from "express";
import type { MCPManager } from "../mcp-manager.js";

export function createToolsRouter(mcpManager: MCPManager): Router {
  const router = Router();

  router.get("/", (_req, res) => {
    const tools = mcpManager.getAllDiscoveredTools();
    res.json({
      count: tools.length,
      tools: tools.map((t) => ({
        server: t.serverName,
        name: t.name,
        description: t.description,
        inputSchema: t.inputSchema,
      })),
    });
  });

  router.get("/health", async (_req, res) => {
    const health = await mcpManager.healthCheck();
    res.json(health);
  });

  return router;
}
