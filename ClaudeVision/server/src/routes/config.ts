import { Router } from "express";
import type { ClaudeClient } from "../claude-client.js";
import type { ConfigUpdate } from "../types.js";

export function createConfigRouter(claudeClient: ClaudeClient): Router {
  const router = Router();

  router.get("/", (_req, res) => {
    res.json(claudeClient.getConfig());
  });

  router.post("/", (req, res) => {
    const body = req.body as ConfigUpdate;

    const updates: Record<string, unknown> = {};
    if (body.system_prompt !== undefined) updates.systemPrompt = body.system_prompt;
    if (body.model !== undefined) updates.model = body.model;
    if (body.max_tokens !== undefined) updates.maxTokens = body.max_tokens;

    claudeClient.updateConfig(updates);
    res.json({ updated: Object.keys(updates), config: claudeClient.getConfig() });
  });

  return router;
}
