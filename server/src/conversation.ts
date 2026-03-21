import { v4 as uuidv4 } from "uuid";
import type { MessageParam } from "./types.js";

const CONVERSATION_TTL_MS = 30 * 60 * 1000; // 30 minutes
const CLEANUP_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes

interface ConversationEntry {
  messages: MessageParam[];
  lastAccess: number;
}

export class ConversationStore {
  private store = new Map<string, ConversationEntry>();
  private cleanupTimer: ReturnType<typeof setInterval>;

  constructor() {
    this.cleanupTimer = setInterval(() => this.cleanup(), CLEANUP_INTERVAL_MS);
  }

  getOrCreate(conversationId?: string): { id: string; messages: MessageParam[] } {
    const id = conversationId || uuidv4();
    const entry = this.store.get(id);

    if (entry) {
      entry.lastAccess = Date.now();
      return { id, messages: entry.messages };
    }

    const newEntry: ConversationEntry = {
      messages: [],
      lastAccess: Date.now(),
    };
    this.store.set(id, newEntry);
    return { id, messages: newEntry.messages };
  }

  append(conversationId: string, ...messages: MessageParam[]): void {
    const entry = this.store.get(conversationId);
    if (entry) {
      entry.messages.push(...messages);
      entry.lastAccess = Date.now();
    }
  }

  private cleanup(): void {
    const now = Date.now();
    for (const [id, entry] of this.store) {
      if (now - entry.lastAccess > CONVERSATION_TTL_MS) {
        this.store.delete(id);
      }
    }
  }

  get size(): number {
    return this.store.size;
  }

  destroy(): void {
    clearInterval(this.cleanupTimer);
    this.store.clear();
  }
}
