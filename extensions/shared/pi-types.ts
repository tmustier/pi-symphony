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

export interface ExtensionApiLike {
  on(eventName: string, handler: (event: unknown, ctx: ExtensionContextLike) => unknown): void;
}

export interface ToolBlockResult {
  block: true;
  reason: string;
}
