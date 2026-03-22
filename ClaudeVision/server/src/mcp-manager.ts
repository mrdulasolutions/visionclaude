import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { readFile } from "fs/promises";
import { homedir } from "os";
import { join } from "path";
import { c } from "./console-theme.js";
import type {
  MCPServerConfig,
  ClaudeDesktopConfig,
  DiscoveredTool,
  Tool,
} from "./types.js";

interface ConnectedServer {
  name: string;
  client: Client;
  tools: DiscoveredTool[];
  type: "stdio" | "remote";
}

export class MCPManager {
  private servers = new Map<string, ConnectedServer>();
  private toolToServer = new Map<string, string>(); // toolName → serverName

  async initialize(configPath?: string): Promise<void> {
    const config = await this.loadConfig(configPath);
    const serverEntries = Object.entries(config);

    if (serverEntries.length === 0) {
      console.log(c.label("[MCP]") + c.dim(" No MCP servers configured"));
      return;
    }

    console.log(
      c.label("[MCP]") + ` Connecting to ${serverEntries.length} server(s)...`
    );

    const results = await Promise.allSettled(
      serverEntries.map(([name, cfg]) => this.connectServer(name, cfg))
    );

    for (let i = 0; i < results.length; i++) {
      const result = results[i];
      const name = serverEntries[i][0];
      if (result.status === "rejected") {
        console.error(
          c.label("[MCP]") + c.error(` Failed to connect to "${name}": `) + result.reason
        );
      }
    }

    console.log(
      c.label("[MCP]") +
        c.success(
          ` Connected to ${this.servers.size}/${serverEntries.length} servers, discovered ${this.toolToServer.size} tools`
        )
    );
  }

  private async loadConfig(
    configPath?: string
  ): Promise<Record<string, MCPServerConfig>> {
    // Priority: explicit path → env var → Claude Desktop config
    const paths = [
      configPath,
      process.env.MCP_CONFIG_PATH,
      join(
        homedir(),
        "Library",
        "Application Support",
        "Claude",
        "claude_desktop_config.json"
      ),
    ].filter(Boolean) as string[];

    for (const path of paths) {
      try {
        const raw = await readFile(path, "utf-8");
        const parsed = JSON.parse(raw);

        // Support both { mcpServers: {} } and Claude Desktop format
        const servers: Record<string, MCPServerConfig> =
          parsed.mcpServers || {};

        if (Object.keys(servers).length > 0) {
          console.log(c.label("[MCP]") + ` Loaded config from ${path}`);
          return servers;
        }
      } catch {
        // Try next path
      }
    }

    console.log(
      c.label("[MCP]") + c.dim(" No MCP config found at any default location")
    );
    return {};
  }

  private async connectServer(
    name: string,
    config: MCPServerConfig
  ): Promise<void> {
    const client = new Client(
      { name: "visionclaude-gateway", version: "1.0.0" },
      { capabilities: {} }
    );

    // Determine transport type: remote URL or local stdio
    if (config.url) {
      await this.connectRemoteServer(name, config, client);
    } else if (config.command) {
      await this.connectStdioServer(name, config, client);
    } else {
      throw new Error(`Server "${name}" has no command or url configured`);
    }

    // Discover tools
    const toolsResponse = await client.listTools();
    const tools: DiscoveredTool[] = (toolsResponse.tools || []).map((t) => ({
      serverName: name,
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema as Record<string, unknown>,
    }));

    // Register
    const isRemote = !!config.url;
    const server: ConnectedServer = {
      name,
      client,
      tools,
      type: isRemote ? "remote" : "stdio",
    };
    this.servers.set(name, server);

    for (const tool of tools) {
      this.toolToServer.set(tool.name, name);
    }

    const typeLabel = isRemote ? c.cyan("[remote]") : c.dim("[local]");
    console.log(
      c.label("[MCP]") +
        ` "${name}" ${typeLabel} connected — ${tools.length} tool(s): ${tools.map((t) => t.name).join(", ")}`
    );
  }

  private async connectRemoteServer(
    name: string,
    config: MCPServerConfig,
    client: Client
  ): Promise<void> {
    const url = new URL(config.url!);

    // Build headers (auth tokens, etc.)
    const headers: Record<string, string> = {};
    if (config.headers) {
      Object.assign(headers, config.headers);
    }

    // Try StreamableHTTP first (newer protocol), fall back to SSE
    try {
      const transport = new StreamableHTTPClientTransport(url, { requestInit: { headers } });
      await client.connect(transport);
      console.log(
        c.label("[MCP]") + c.dim(` "${name}" using StreamableHTTP transport`)
      );
    } catch {
      // Fall back to SSE transport
      console.log(
        c.label("[MCP]") + c.dim(` "${name}" StreamableHTTP failed, trying SSE...`)
      );
      const sseTransport = new SSEClientTransport(url, { requestInit: { headers } });
      await client.connect(sseTransport);
      console.log(
        c.label("[MCP]") + c.dim(` "${name}" using SSE transport`)
      );
    }
  }

  private async connectStdioServer(
    name: string,
    config: MCPServerConfig,
    client: Client
  ): Promise<void> {
    const transport = new StdioClientTransport({
      command: config.command!,
      args: config.args,
      env: { ...process.env, ...config.env } as Record<string, string>,
    });

    await client.connect(transport);
  }

  async invokeTool(
    toolName: string,
    args: Record<string, unknown>
  ): Promise<unknown> {
    const serverName = this.toolToServer.get(toolName);
    if (!serverName) {
      throw new Error(`Unknown tool: ${toolName}`);
    }

    const server = this.servers.get(serverName);
    if (!server) {
      throw new Error(`Server "${serverName}" not connected`);
    }

    console.log(
      c.label("[MCP]") + ` Invoking ${c.value(toolName)} on "${serverName}"...`
    );

    const result = await server.client.callTool({
      name: toolName,
      arguments: args,
    });

    return result;
  }

  getToolsForClaude(): Tool[] {
    const tools: Tool[] = [];
    for (const server of this.servers.values()) {
      for (const tool of server.tools) {
        tools.push({
          name: tool.name,
          description: tool.description || "",
          input_schema: tool.inputSchema as Tool["input_schema"],
        });
      }
    }
    return tools;
  }

  getAllDiscoveredTools(): DiscoveredTool[] {
    const all: DiscoveredTool[] = [];
    for (const server of this.servers.values()) {
      all.push(...server.tools);
    }
    return all;
  }

  getServerNames(): string[] {
    return Array.from(this.servers.keys());
  }

  getServerStatus(): { name: string; toolCount: number; type: string }[] {
    return Array.from(this.servers.values()).map((s) => ({
      name: s.name,
      toolCount: s.tools.length,
      type: s.type,
    }));
  }

  async healthCheck(): Promise<{
    healthy: string[];
    unhealthy: string[];
  }> {
    const healthy: string[] = [];
    const unhealthy: string[] = [];

    for (const [name, server] of this.servers) {
      try {
        await server.client.listTools();
        healthy.push(name);
      } catch {
        unhealthy.push(name);
      }
    }

    return { healthy, unhealthy };
  }

  async shutdown(): Promise<void> {
    console.log(c.label("[MCP]") + " Shutting down all servers...");
    for (const [name, server] of this.servers) {
      try {
        await server.client.close();
        console.log(c.label("[MCP]") + c.dim(` "${name}" disconnected`));
      } catch (err) {
        console.error(
          c.label("[MCP]") + c.error(` Error disconnecting "${name}": `) + err
        );
      }
    }
    this.servers.clear();
    this.toolToServer.clear();
  }
}
