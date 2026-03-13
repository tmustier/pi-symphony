import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  createProofPaths,
  createProofRecorder,
  extractFinalAssistantText,
  recordProofEvent,
  sanitizeForJson,
  writeProofSummary,
} from "./recorder.js";

describe("proof recorder", () => {
  const tempRoots: string[] = [];

  afterEach(() => {
    for (const tempRoot of tempRoots.splice(0)) {
      fs.rmSync(tempRoot, { recursive: true, force: true });
    }
  });

  it("stores proof artifacts alongside the Pi session file when available", () => {
    const sessionFile = "/tmp/pi-rpc/session.jsonl";

    expect(createProofPaths("/workspace", sessionFile)).toEqual({
      proofDir: "/tmp/pi-rpc/proof",
      eventsFile: "/tmp/pi-rpc/proof/events.jsonl",
      summaryFile: "/tmp/pi-rpc/proof/summary.json",
    });
  });

  it("falls back to a workspace-local proof directory when no session file exists", () => {
    expect(createProofPaths("/workspace", null)).toEqual({
      proofDir: "/workspace/.pi-symphony-proof",
      eventsFile: "/workspace/.pi-symphony-proof/events.jsonl",
      summaryFile: "/workspace/.pi-symphony-proof/summary.json",
    });
  });

  it("records proof events and writes a summary", () => {
    const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "pi-symphony-proof-"));
    tempRoots.push(tempRoot);

    const workspaceRoot = path.join(tempRoot, "workspace");
    const sessionDir = path.join(tempRoot, "session");
    const sessionFile = path.join(sessionDir, "worker.jsonl");
    fs.mkdirSync(workspaceRoot, { recursive: true });
    fs.mkdirSync(sessionDir, { recursive: true });

    const recorder = createProofRecorder(workspaceRoot, sessionFile);

    recordProofEvent(recorder, "turn_end", { turnIndex: 1, message: { role: "assistant" } });
    recordProofEvent(recorder, "tool_execution_end", {
      toolName: "bash",
      result: { stdout: "ok" },
      isError: false,
    });

    const summary = writeProofSummary(recorder, [
      { role: "user", content: "hello" },
      { role: "assistant", content: [{ type: "text", text: "done" }] },
    ]);

    const events = fs
      .readFileSync(recorder.paths.eventsFile, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line) as { type: string });

    expect(events.map((entry) => entry.type)).toEqual(["turn_end", "tool_execution_end"]);
    expect(summary.finalAssistantText).toBe("done");
    expect(summary.toolCounts).toEqual({ bash: 1 });
    expect(JSON.parse(fs.readFileSync(recorder.paths.summaryFile, "utf8"))).toMatchObject({
      finalAssistantText: "done",
      toolCounts: { bash: 1 },
    });
  });

  it("extracts final assistant text from mixed message shapes", () => {
    expect(
      extractFinalAssistantText([
        { role: "assistant", content: "first" },
        { role: "assistant", content: [{ type: "text", text: "second" }] },
      ]),
    ).toBe("second");
  });

  it("sanitizes nested proof payloads", () => {
    expect(
      sanitizeForJson({
        text: "x".repeat(5_000),
        nested: { level1: { level2: { level3: { level4: { level5: true } } } } },
      }),
    ).toEqual({
      text: `${"x".repeat(4_000)}…`,
      nested: {
        level1: {
          level2: {
            level3: "[truncated-depth]",
          },
        },
      },
    });
  });
});
