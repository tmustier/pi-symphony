import { describe, expect, it } from "vitest";

import { SpikeRunCollector } from "./summary.js";

describe("SpikeRunCollector", () => {
  it("accumulates events, tools, extension UI methods, and proof metadata", () => {
    const collector = new SpikeRunCollector();

    collector.setIssueContext("SPIKE-1", "/tmp/workspace");
    collector.setSessionName("SPIKE-1: Validate Pi RPC worker flow");
    collector.recordEvent({
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: "SPIKE_OK " },
    });
    collector.recordEvent({
      type: "message_update",
      assistantMessageEvent: { type: "text_delta", delta: "SPIKE-1" },
    });
    collector.recordEvent({ type: "tool_execution_start", toolName: "bash" });
    collector.recordExtensionUiRequest({
      type: "extension_ui_request",
      id: "1",
      method: "notify",
    });
    collector.recordResponse({
      type: "response",
      command: "get_state",
      success: true,
      data: { sessionFile: "/tmp/workspace/session.jsonl" },
    });
    collector.recordResponse({
      type: "response",
      command: "get_last_assistant_text",
      success: true,
      data: { text: "SPIKE_OK SPIKE-1" },
    });
    collector.recordResponse({
      type: "response",
      command: "get_session_stats",
      success: true,
      data: { tokens: { total: 42 } },
    });
    collector.recordResponse({
      type: "response",
      command: "export_html",
      success: true,
      data: { path: "/tmp/session.html" },
    });
    collector.recordEvent({ type: "agent_end" });
    collector.recordStderr("warning: test stderr");

    const summary = collector.finalize();

    expect(summary.success).toBe(true);
    expect(summary.issueIdentifier).toBe("SPIKE-1");
    expect(summary.workspacePath).toBe("/tmp/workspace");
    expect(summary.sessionName).toBe("SPIKE-1: Validate Pi RPC worker flow");
    expect(summary.sessionFile).toBe("/tmp/workspace/session.jsonl");
    expect(summary.finalAssistantText).toBe("SPIKE_OK SPIKE-1");
    expect(summary.exportedHtmlPath).toBe("/tmp/session.html");
    expect(summary.sessionStats).toEqual({ tokens: { total: 42 } });
    expect(summary.toolCounts).toEqual({ bash: 1 });
    expect(summary.extensionUiMethods).toEqual(["notify"]);
    expect(summary.stderrLines).toEqual(["warning: test stderr"]);
  });

  it("marks timed out runs as unsuccessful", () => {
    const collector = new SpikeRunCollector();

    collector.markTimedOut();
    collector.markAborted();

    const summary = collector.finalize();

    expect(summary.success).toBe(false);
    expect(summary.timedOut).toBe(true);
    expect(summary.aborted).toBe(true);
  });
});
