import fs from "fs";
import path from "path";
import { c } from "./console-theme.js";

export interface Skill {
  name: string;
  description: string;
  trigger: string;
  content: string;
  filePath: string;
}

const HOME = process.env.HOME || "~";

const SKILL_SEARCH_PATHS = [
  // ── VisionClaude's own skills ──
  path.join(process.cwd(), "..", "skills"),
  path.join(process.cwd(), "skills"),

  // ── Claude Code / Desktop plugins ──
  path.join(HOME, ".claude", "plugins", "marketplaces", "claude-plugins-official", "plugins"),
  path.join(HOME, ".claude", "plugins", "marketplaces", "claude-plugins-official", "external_plugins"),

  // ── Claude scheduled tasks ──
  path.join(HOME, ".claude", "scheduled-tasks"),

  // ── User's Desktop repos (where custom skills live) ──
  path.join(HOME, "Desktop", "Claude Repo"),
  path.join(HOME, "Desktop", "Cursor Repo"),
  path.join(HOME, "Desktop", "ExChek Client Repos"),
  path.join(HOME, "Desktop", "Agentpaytest"),
];

/**
 * Parse SKILL.md frontmatter and content.
 * Frontmatter format:
 * ---
 * description: Short description
 * trigger: keyword or phrase
 * ---
 * Content here...
 */
function parseSkillFile(filePath: string): Skill | null {
  try {
    const raw = fs.readFileSync(filePath, "utf-8");
    const dirName = path.basename(path.dirname(filePath));

    let description = "";
    let trigger = "";
    let content = raw;

    // Parse YAML-style frontmatter
    const frontmatterMatch = raw.match(/^---\s*\n([\s\S]*?)\n---\s*\n([\s\S]*)$/);
    if (frontmatterMatch) {
      const frontmatter = frontmatterMatch[1];
      content = frontmatterMatch[2].trim();

      const descMatch = frontmatter.match(/description:\s*(.+)/i);
      if (descMatch) description = descMatch[1].trim().replace(/^["']|["']$/g, "");

      const triggerMatch = frontmatter.match(/trigger:\s*(.+)/i);
      if (triggerMatch) trigger = triggerMatch[1].trim().replace(/^["']|["']$/g, "");
    }

    // If no frontmatter, try to extract description from first line
    if (!description) {
      const firstLine = content.split("\n")[0];
      if (firstLine.startsWith("#")) {
        description = firstLine.replace(/^#+\s*/, "").trim();
      } else {
        description = firstLine.substring(0, 100).trim();
      }
    }

    // Default trigger to the directory name
    if (!trigger) trigger = dirName;

    return {
      name: dirName,
      description,
      trigger,
      content,
      filePath,
    };
  } catch {
    return null;
  }
}

/**
 * Recursively find all SKILL.md files in a directory.
 */
function findSkillFiles(dir: string, maxDepth: number = 5): string[] {
  const results: string[] = [];

  if (!fs.existsSync(dir)) return results;

  function walk(currentDir: string, depth: number) {
    if (depth > maxDepth) return;

    try {
      const entries = fs.readdirSync(currentDir, { withFileTypes: true });
      for (const entry of entries) {
        const fullPath = path.join(currentDir, entry.name);
        if (entry.isDirectory() && entry.name !== "node_modules" && entry.name !== ".git") {
          walk(fullPath, depth + 1);
        } else if (
          entry.isFile() &&
          (entry.name === "SKILL.md" || entry.name === "skill.md")
        ) {
          results.push(fullPath);
        }
      }
    } catch {
      // Permission denied or other FS error — skip
    }
  }

  walk(dir, 0);
  return results;
}

export class SkillLoader {
  private skills: Map<string, Skill> = new Map();
  private searchPaths: string[];

  constructor(extraPaths?: string[]) {
    this.searchPaths = [...SKILL_SEARCH_PATHS, ...(extraPaths || [])];
  }

  /**
   * Discover and load all skills from search paths.
   */
  load(): void {
    this.skills.clear();

    console.log(c.label("[Skills]") + " Scanning for skills...");

    for (const searchPath of this.searchPaths) {
      const skillFiles = findSkillFiles(searchPath);
      for (const filePath of skillFiles) {
        const skill = parseSkillFile(filePath);
        if (skill && !this.skills.has(skill.name)) {
          this.skills.set(skill.name, skill);
        }
      }
    }

    if (this.skills.size > 0) {
      const names = Array.from(this.skills.values())
        .map((s) => s.name)
        .join(", ");
      console.log(
        c.label("[Skills]") +
          c.success(` Loaded ${this.skills.size} skill(s): `) +
          c.dim(names)
      );
    } else {
      console.log(
        c.label("[Skills]") +
          c.dim(" No skills found (add SKILL.md files to skills/ directory)")
      );
    }
  }

  /**
   * Reload skills (call when files change or on demand).
   */
  reload(): void {
    const prevCount = this.skills.size;
    this.load();
    const diff = this.skills.size - prevCount;
    if (diff !== 0) {
      console.log(
        c.label("[Skills]") +
          ` Reloaded: ${diff > 0 ? "+" : ""}${diff} skill(s)`
      );
    }
  }

  /**
   * Get all loaded skills.
   */
  getAll(): Skill[] {
    return Array.from(this.skills.values());
  }

  /**
   * Get a skill by name.
   */
  get(name: string): Skill | undefined {
    return this.skills.get(name);
  }

  /**
   * Find skills matching a query (by name or trigger).
   */
  match(query: string): Skill[] {
    const lower = query.toLowerCase();
    return this.getAll().filter(
      (s) =>
        s.name.toLowerCase().includes(lower) ||
        s.trigger.toLowerCase().includes(lower) ||
        s.description.toLowerCase().includes(lower)
    );
  }

  /**
   * Build a skills summary for the system prompt.
   */
  buildSystemPromptSection(): string {
    if (this.skills.size === 0) return "";

    const lines = [
      "\n\nAVAILABLE SKILLS:",
      "You have access to the following specialized skills. When the user's request matches a skill, use its instructions:",
      "",
    ];

    for (const skill of this.skills.values()) {
      lines.push(`- ${skill.name}: ${skill.description}`);
    }

    lines.push(
      "",
      "To use a skill, follow its instructions when the user's request is relevant."
    );

    return lines.join("\n");
  }

  /**
   * Get skill content to inject into a conversation when matched.
   */
  getSkillPrompt(name: string): string | null {
    const skill = this.skills.get(name);
    if (!skill) return null;

    return `[SKILL: ${skill.name}]\n${skill.content}\n[/SKILL]`;
  }

  /**
   * Get count for health endpoint.
   */
  get count(): number {
    return this.skills.size;
  }

  /**
   * Get skill info for tools/skills endpoint.
   */
  getSkillList(): { name: string; description: string; trigger: string }[] {
    return this.getAll().map((s) => ({
      name: s.name,
      description: s.description,
      trigger: s.trigger,
    }));
  }
}
