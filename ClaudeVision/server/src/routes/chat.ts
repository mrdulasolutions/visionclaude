import { Router } from "express";
import type { ClaudeClient } from "../claude-client.js";
import type { ConversationStore } from "../conversation.js";
import type { ChatRequest, ChatResponse } from "../types.js";

export function createChatRouter(
  claudeClient: ClaudeClient,
  conversations: ConversationStore
): Router {
  const router = Router();

  router.post("/", async (req, res) => {
    try {
      const body = req.body as ChatRequest;

      if (!body.text && (!body.images || body.images.length === 0)) {
        res.status(400).json({ error: "Must provide text or images" });
        return;
      }

      const { id, messages } = conversations.getOrCreate(body.conversation_id);

      const { responseText, toolCalls } = await claudeClient.chat(
        messages,
        body.text || "",
        body.images
      );

      // Update conversation history
      const userContent: any[] = [];
      if (body.images && body.images.length > 0) {
        for (const img of body.images) {
          userContent.push({
            type: "image",
            source: { type: "base64", media_type: "image/jpeg", data: img },
          });
        }
      }
      if (body.text) {
        userContent.push({ type: "text", text: body.text });
      }

      conversations.append(
        id,
        { role: "user", content: userContent },
        { role: "assistant", content: responseText }
      );

      const response: ChatResponse = {
        text: responseText,
        tool_calls: toolCalls,
        conversation_id: id,
      };

      res.json(response);
    } catch (err) {
      console.error("[Chat] Error:", err);
      const message = err instanceof Error ? err.message : "Internal error";
      res.status(500).json({ error: message });
    }
  });

  return router;
}
