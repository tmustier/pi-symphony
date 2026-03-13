import type {
  AgentEndEventLike,
  ExtensionApiLike,
  ExtensionContextLike,
  ToolExecutionEndEventLike,
  TurnEndEventLike,
} from "../shared/pi-types.js";
import {
  type ProofRecorderState,
  createProofRecorder,
  recordProofEvent,
  writeProofSummary,
} from "./recorder.js";

export default function proofExtension(pi: ExtensionApiLike): void {
  let state: ProofRecorderState | null = null;
  let finalized = false;

  pi.on("session_start", async (_event, rawContext) => {
    const ctx = rawContext as ExtensionContextLike;
    const sessionFile = ctx.sessionManager?.getSessionFile?.() ?? null;

    state = createProofRecorder(process.cwd(), sessionFile);
    finalized = false;
    recordProofEvent(state, "session_start", { sessionFile });

    if (ctx.hasUI && ctx.ui?.setStatus) {
      ctx.ui.setStatus("proof", `proof:${state.paths.proofDir}`);
    }
  });

  pi.on("tool_execution_end", async (rawEvent) => {
    if (state === null) {
      return undefined;
    }

    const event = rawEvent as ToolExecutionEndEventLike;
    recordProofEvent(state, "tool_execution_end", {
      toolCallId: event.toolCallId,
      toolName: event.toolName,
      isError: event.isError ?? false,
      result: event.result,
    });
    return undefined;
  });

  pi.on("turn_end", async (rawEvent) => {
    if (state === null) {
      return undefined;
    }

    const event = rawEvent as TurnEndEventLike;
    recordProofEvent(state, "turn_end", {
      turnIndex: event.turnIndex,
      message: event.message,
      toolResults: event.toolResults ?? [],
    });
    return undefined;
  });

  pi.on("agent_end", async (rawEvent, rawContext) => {
    if (state === null) {
      return undefined;
    }

    const event = rawEvent as AgentEndEventLike;
    const ctx = rawContext as ExtensionContextLike;

    recordProofEvent(state, "agent_end", {
      messageCount: Array.isArray(event.messages) ? event.messages.length : 0,
    });

    const summary = writeProofSummary(state, Array.isArray(event.messages) ? event.messages : []);
    finalized = true;

    if (ctx.hasUI && ctx.ui) {
      ctx.ui.notify(
        `proof summary written: ${summary.finalAssistantText ?? "(no assistant text)"}`,
        "info",
      );
      if (ctx.ui.setStatus) {
        ctx.ui.setStatus("proof", `proof:${state.paths.summaryFile}`);
      }
    }

    return undefined;
  });

  pi.on("session_shutdown", async () => {
    if (state === null || finalized) {
      return undefined;
    }

    recordProofEvent(state, "session_shutdown", {});
    writeProofSummary(state, []);
    finalized = true;
    return undefined;
  });
}
