export type ExtensionNotifyLevel = "info" | "success" | "warning" | "error";

export interface ExtensionUI {
  notify(message: string, level: ExtensionNotifyLevel): void;
  setStatus?(key: string, value: string | undefined): void;
}

export interface SessionManagerLike {
  getSessionFile?(): string | null | undefined;
}

export interface ExtensionContextLike {
  hasUI?: boolean;
  ui?: ExtensionUI;
  sessionManager?: SessionManagerLike;
}

export interface ToolCallEventLike {
  toolName: string;
  input: Record<string, unknown>;
  toolCallId?: string;
}

export interface ToolExecutionEndEventLike {
  toolCallId?: string;
  toolName?: string;
  result?: unknown;
  isError?: boolean;
}

export interface TurnEndEventLike {
  turnIndex?: number;
  message?: unknown;
  toolResults?: unknown[];
}

export interface AgentEndEventLike {
  messages?: unknown[];
}

export interface ToolContentPart {
  type: "text";
  text: string;
}

export interface ToolExecutionResult {
  content: ToolContentPart[];
  details?: Record<string, unknown>;
  isError?: boolean;
}

export interface ToolDefinitionLike {
  name: string;
  label: string;
  description: string;
  promptSnippet?: string;
  promptGuidelines?: string[];
  parameters: Record<string, unknown>;
  execute(
    toolCallId: string,
    params: unknown,
    signal: AbortSignal,
    onUpdate?: ((update: ToolExecutionResult) => void) | undefined,
    ctx?: ExtensionContextLike,
  ): Promise<ToolExecutionResult>;
}

export interface ExtensionApiLike {
  on(eventName: string, handler: (event: unknown, ctx: ExtensionContextLike) => unknown): void;
  registerTool?(definition: ToolDefinitionLike): void;
}

export interface ToolBlockResult {
  block: true;
  reason: string;
}
