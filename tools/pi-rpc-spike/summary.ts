import type { RpcEventEnvelope, RpcExtensionUiRequest, RpcResponseEnvelope } from "./protocol.js";

export type SpikeRunSummary = {
  startedAt: string;
  completedAt?: string;
  durationMs?: number;
  success: boolean;
  timedOut: boolean;
  aborted: boolean;
  issueIdentifier?: string;
  workspacePath?: string;
  sessionName?: string;
  sessionFile?: string;
  finalAssistantText?: string | null;
  exportedHtmlPath?: string;
  sessionStats?: unknown;
  eventCounts: Record<string, number>;
  toolCounts: Record<string, number>;
  extensionUiMethods: string[];
  stderrLines: string[];
};

export class SpikeRunCollector {
  private readonly startedAtMs = Date.now();
  private readonly eventCounts = new Map<string, number>();
  private readonly toolCounts = new Map<string, number>();
  private readonly extensionUiMethods = new Set<string>();
  private readonly stderrLines: string[] = [];

  private streamedAssistantText = "";
  private completedAtMs?: number;
  private finalAssistantText?: string | null;
  private exportedHtmlPath?: string;
  private issueIdentifier?: string;
  private workspacePath?: string;
  private sessionName?: string;
  private sessionFile?: string;
  private sessionStats?: unknown;
  private timedOut = false;
  private aborted = false;

  recordResponse(response: RpcResponseEnvelope): void {
    const commandKey = `response:${response.command}`;
    this.eventCounts.set(commandKey, (this.eventCounts.get(commandKey) ?? 0) + 1);

    if (response.command === "set_session_name" && response.success) {
      this.sessionName = typeof response.data === "string" ? response.data : this.sessionName;
    }

    if (response.command === "get_state" && response.success && isRecord(response.data)) {
      this.sessionFile =
        typeof response.data.sessionFile === "string"
          ? response.data.sessionFile
          : this.sessionFile;
    }

    if (
      response.command === "get_last_assistant_text" &&
      response.success &&
      isRecord(response.data)
    ) {
      this.finalAssistantText = typeof response.data.text === "string" ? response.data.text : null;
    }

    if (response.command === "get_session_stats" && response.success) {
      this.sessionStats = response.data;
    }

    if (response.command === "export_html" && response.success && isRecord(response.data)) {
      this.exportedHtmlPath =
        typeof response.data.path === "string" ? response.data.path : this.exportedHtmlPath;
    }
  }

  recordEvent(event: RpcEventEnvelope): void {
    this.eventCounts.set(event.type, (this.eventCounts.get(event.type) ?? 0) + 1);

    if (
      event.type === "message_update" &&
      isRecord(event.assistantMessageEvent) &&
      event.assistantMessageEvent.type === "text_delta" &&
      typeof event.assistantMessageEvent.delta === "string"
    ) {
      this.streamedAssistantText += event.assistantMessageEvent.delta;
    }

    if (event.type === "tool_execution_start" && typeof event.toolName === "string") {
      this.toolCounts.set(event.toolName, (this.toolCounts.get(event.toolName) ?? 0) + 1);
    }

    if (event.type === "agent_end") {
      this.completedAtMs = Date.now();
    }
  }

  recordExtensionUiRequest(request: RpcExtensionUiRequest): void {
    this.eventCounts.set(request.type, (this.eventCounts.get(request.type) ?? 0) + 1);
    this.extensionUiMethods.add(request.method);
  }

  recordStderr(line: string): void {
    this.stderrLines.push(line);
  }

  markTimedOut(): void {
    this.timedOut = true;
  }

  markAborted(): void {
    this.aborted = true;
  }

  setIssueContext(issueIdentifier: string, workspacePath: string): void {
    this.issueIdentifier = issueIdentifier;
    this.workspacePath = workspacePath;
  }

  setSessionName(sessionName: string): void {
    this.sessionName = sessionName;
  }

  finalize(): SpikeRunSummary {
    const completedAtMs = this.completedAtMs ?? Date.now();

    return {
      startedAt: new Date(this.startedAtMs).toISOString(),
      completedAt: new Date(completedAtMs).toISOString(),
      durationMs: completedAtMs - this.startedAtMs,
      success: !this.timedOut && !this.aborted,
      timedOut: this.timedOut,
      aborted: this.aborted,
      issueIdentifier: this.issueIdentifier,
      workspacePath: this.workspacePath,
      sessionName: this.sessionName,
      sessionFile: this.sessionFile,
      finalAssistantText: this.finalAssistantText ?? (this.streamedAssistantText || null),
      exportedHtmlPath: this.exportedHtmlPath,
      sessionStats: this.sessionStats,
      eventCounts: Object.fromEntries(this.eventCounts),
      toolCounts: Object.fromEntries(this.toolCounts),
      extensionUiMethods: Array.from(this.extensionUiMethods),
      stderrLines: this.stderrLines,
    };
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
