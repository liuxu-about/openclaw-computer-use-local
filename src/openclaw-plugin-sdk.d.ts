declare module "openclaw/plugin-sdk/plugin-entry" {
  export type ToolResult = {
    content: Array<{ type: "text"; text: string }>;
    details?: Record<string, unknown>;
  };

  export type ToolDefinition<Params = unknown> = {
    name: string;
    description: string;
    parameters: unknown;
    execute: (id: string, params: Params) => Promise<ToolResult> | ToolResult;
  };

  export type PluginAPI = {
    pluginConfig: unknown;
    registerTool<Params>(definition: ToolDefinition<Params>, options?: { optional?: boolean }): void;
  };

  export function definePluginEntry(entry: {
    id: string;
    name: string;
    description?: string;
    register(api: PluginAPI): void;
  }): unknown;
}
