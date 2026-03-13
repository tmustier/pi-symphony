import { describe, expect, it } from "vitest";

import {
  evaluateBashCommand,
  evaluatePathAccess,
  evaluateToolCall,
  extractPathTokens,
} from "./policy.js";

describe("workspace guard policy", () => {
  const workspaceRoot = "/tmp/pi-symphony/workspace";

  it("allows relative file access within the workspace", () => {
    expect(evaluatePathAccess(workspaceRoot, "src/index.ts")).toEqual({
      blocked: false,
      matchedPath: "src/index.ts",
    });

    expect(evaluateToolCall(workspaceRoot, "write", { path: "README.md" })).toEqual({
      blocked: false,
      matchedPath: "README.md",
    });
  });

  it("blocks file paths that escape the workspace", () => {
    expect(evaluatePathAccess(workspaceRoot, "../secrets.env")).toMatchObject({
      blocked: true,
      matchedPath: "../secrets.env",
    });

    expect(evaluatePathAccess(workspaceRoot, "/etc/hosts")).toMatchObject({
      blocked: true,
      matchedPath: "/etc/hosts",
    });
  });

  it("extracts suspicious path tokens from bash commands", () => {
    expect(extractPathTokens("cat ../secret.txt && echo hi > /tmp/out.txt")).toEqual([
      "../secret.txt",
      "/tmp/out.txt",
    ]);
  });

  it("allows bash commands that stay inside the workspace", () => {
    expect(evaluateBashCommand(workspaceRoot, "git status && find src -type f")).toEqual({
      blocked: false,
    });

    expect(evaluateToolCall(workspaceRoot, "bash", { command: "cat ./README.md" })).toEqual({
      blocked: false,
    });
  });

  it("blocks bash commands with explicit path traversal or absolute paths", () => {
    expect(evaluateBashCommand(workspaceRoot, "cat ../secret.txt")).toMatchObject({
      blocked: true,
      matchedPath: "../secret.txt",
    });

    expect(
      evaluateToolCall(workspaceRoot, "bash", { command: "echo hi > /tmp/out.txt" }),
    ).toMatchObject({
      blocked: true,
      matchedPath: "/tmp/out.txt",
    });
  });
});
