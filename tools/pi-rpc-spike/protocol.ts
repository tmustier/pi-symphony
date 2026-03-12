import { randomUUID } from "node:crypto";

export type RpcCommand = Record<string, unknown> & {
  id?: string;
  type: string;
};

export type RpcResponseEnvelope = {
  id?: string;
  type: "response";
  command: string;
  success: boolean;
  error?: string;
  data?: unknown;
};

export type RpcExtensionUiRequest = {
  id: string;
  type: "extension_ui_request";
  method: string;
  [key: string]: unknown;
};

export type RpcEventEnvelope = {
  type: string;
  [key: string]: unknown;
};

export function withCommandId<T extends RpcCommand>(command: T): T & { id: string } {
  return {
    ...command,
    id: command.id ?? randomUUID(),
  };
}

export function isRpcResponseEnvelope(value: unknown): value is RpcResponseEnvelope {
  return (
    isRecord(value) &&
    value.type === "response" &&
    typeof value.command === "string" &&
    typeof value.success === "boolean"
  );
}

export function isRpcExtensionUiRequest(value: unknown): value is RpcExtensionUiRequest {
  return (
    isRecord(value) &&
    value.type === "extension_ui_request" &&
    typeof value.id === "string" &&
    typeof value.method === "string"
  );
}

export function isRpcEventEnvelope(value: unknown): value is RpcEventEnvelope {
  return (
    isRecord(value) &&
    typeof value.type === "string" &&
    value.type !== "response" &&
    value.type !== "extension_ui_request"
  );
}

export function autoRespondToExtensionUiRequest(request: RpcExtensionUiRequest): RpcCommand | null {
  switch (request.method) {
    case "select":
    case "confirm":
    case "input":
    case "editor":
      return {
        type: "extension_ui_response",
        id: request.id,
        cancelled: true,
      };
    default:
      return null;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
