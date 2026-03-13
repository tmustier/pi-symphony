import fs from "node:fs";
import path from "node:path";

export interface ProofPaths {
  proofDir: string;
  eventsFile: string;
  summaryFile: string;
}

export interface ProofRecorderState {
  paths: ProofPaths;
  workspaceRoot: string;
  sessionFile: string | null;
  startedAt: string;
  eventCounts: Record<string, number>;
  toolCounts: Record<string, number>;
}

export interface ProofSummary {
  workspaceRoot: string;
  sessionFile: string | null;
  startedAt: string;
  finishedAt: string;
  eventCounts: Record<string, number>;
  toolCounts: Record<string, number>;
  finalAssistantText: string | null;
}

export function createProofPaths(workspaceRoot: string, sessionFile?: string | null): ProofPaths {
  const proofDir = sessionFile
    ? path.join(path.dirname(sessionFile), "proof")
    : path.join(workspaceRoot, ".pi-symphony-proof");

  return {
    proofDir,
    eventsFile: path.join(proofDir, "events.jsonl"),
    summaryFile: path.join(proofDir, "summary.json"),
  };
}

export function createProofRecorder(
  workspaceRoot: string,
  sessionFile?: string | null,
): ProofRecorderState {
  const paths = createProofPaths(workspaceRoot, sessionFile ?? null);
  fs.mkdirSync(paths.proofDir, { recursive: true });

  return {
    paths,
    workspaceRoot,
    sessionFile: sessionFile ?? null,
    startedAt: new Date().toISOString(),
    eventCounts: {},
    toolCounts: {},
  };
}

export function recordProofEvent(
  state: ProofRecorderState,
  eventType: string,
  payload: unknown,
  timestamp = new Date().toISOString(),
): void {
  const entry = {
    timestamp,
    type: eventType,
    payload: sanitizeForJson(payload),
  };

  fs.appendFileSync(state.paths.eventsFile, `${JSON.stringify(entry)}\n`, "utf8");
  state.eventCounts[eventType] = (state.eventCounts[eventType] ?? 0) + 1;

  if (eventType === "tool_execution_end") {
    const toolName = extractToolName(payload);
    if (toolName !== null) {
      state.toolCounts[toolName] = (state.toolCounts[toolName] ?? 0) + 1;
    }
  }
}

export function writeProofSummary(
  state: ProofRecorderState,
  messages: unknown[] = [],
  finishedAt = new Date().toISOString(),
): ProofSummary {
  const summary: ProofSummary = {
    workspaceRoot: state.workspaceRoot,
    sessionFile: state.sessionFile,
    startedAt: state.startedAt,
    finishedAt,
    eventCounts: { ...state.eventCounts },
    toolCounts: { ...state.toolCounts },
    finalAssistantText: extractFinalAssistantText(messages),
  };

  fs.writeFileSync(state.paths.summaryFile, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
  return summary;
}

export function extractFinalAssistantText(messages: unknown[]): string | null {
  for (const message of [...messages].reverse()) {
    const text = assistantTextFromMessage(message);
    if (text !== null) {
      return text;
    }
  }

  return null;
}

export function sanitizeForJson(value: unknown, depth = 0): unknown {
  if (depth >= 4) {
    return "[truncated-depth]";
  }

  if (typeof value === "string") {
    return value.length > 4_000 ? `${value.slice(0, 4_000)}…` : value;
  }

  if (
    value === null ||
    typeof value === "number" ||
    typeof value === "boolean" ||
    typeof value === "undefined"
  ) {
    return value ?? null;
  }

  if (Array.isArray(value)) {
    return value.slice(0, 20).map((item) => sanitizeForJson(item, depth + 1));
  }

  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>).slice(0, 30);
    return Object.fromEntries(
      entries.map(([key, nested]) => [key, sanitizeForJson(nested, depth + 1)]),
    );
  }

  return String(value);
}

function extractToolName(payload: unknown): string | null {
  if (typeof payload !== "object" || payload === null) {
    return null;
  }

  const toolName = (payload as Record<string, unknown>).toolName;
  return typeof toolName === "string" && toolName.length > 0 ? toolName : null;
}

function assistantTextFromMessage(message: unknown): string | null {
  if (typeof message !== "object" || message === null) {
    return null;
  }

  const messageRecord = message as Record<string, unknown>;
  if (messageRecord.role !== "assistant") {
    return null;
  }

  if (typeof messageRecord.content === "string") {
    return messageRecord.content;
  }

  if (Array.isArray(messageRecord.content)) {
    const text = messageRecord.content
      .flatMap((block) => {
        if (typeof block === "string") {
          return [block];
        }

        if (
          typeof block === "object" &&
          block !== null &&
          typeof (block as Record<string, unknown>).text === "string"
        ) {
          return [(block as Record<string, string>).text];
        }

        return [];
      })
      .join("\n")
      .trim();

    return text.length > 0 ? text : null;
  }

  const text = messageRecord.text;
  return typeof text === "string" && text.length > 0 ? text : null;
}
