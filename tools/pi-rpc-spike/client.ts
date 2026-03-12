import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { mkdir } from "node:fs/promises";

import { JsonlDecoder } from "./jsonl.js";
import {
  type RpcCommand,
  type RpcEventEnvelope,
  type RpcExtensionUiRequest,
  autoRespondToExtensionUiRequest,
  isRpcEventEnvelope,
  isRpcExtensionUiRequest,
  isRpcResponseEnvelope,
  withCommandId,
} from "./protocol.js";
import { SpikeRunCollector, type SpikeRunSummary } from "./summary.js";

export type FixtureIssue = {
  id: string;
  identifier: string;
  title: string;
  description?: string;
  state?: string;
  labels?: string[];
  url?: string;
};

export type PiRpcClientOptions = {
  cwd: string;
  sessionDir?: string;
  command?: string;
  args?: string[];
  env?: NodeJS.ProcessEnv;
  responseTimeoutMs?: number;
  onEvent?: (event: RpcEventEnvelope) => void;
};

export type RunFixtureOptions = {
  issue: FixtureIssue;
  timeoutMs: number;
  exportHtmlPath?: string;
  model?: { provider: string; modelId: string };
  thinkingLevel?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh";
};

export class PiRpcClient {
  private readonly command: string;
  private readonly args: string[];
  private readonly cwd: string;
  private readonly sessionDir: string;
  private readonly env?: NodeJS.ProcessEnv;
  private readonly responseTimeoutMs: number;
  private readonly onEvent?: (event: RpcEventEnvelope) => void;
  private readonly stdoutDecoder = new JsonlDecoder();
  private readonly stderrDecoder = new JsonlDecoder();
  private readonly pendingResponses = new Map<
    string,
    {
      resolve: (value: unknown) => void;
      reject: (reason?: unknown) => void;
      timeout: NodeJS.Timeout;
    }
  >();

  private child?: ChildProcessWithoutNullStreams;
  private readonly collector = new SpikeRunCollector();
  private agentEndPromise?: Promise<void>;
  private resolveAgentEnd?: () => void;
  private exitPromise?: Promise<void>;
  private resolveExited?: () => void;

  constructor(options: PiRpcClientOptions) {
    this.command = options.command ?? "pi";
    this.cwd = options.cwd;
    this.sessionDir = options.sessionDir ?? `${this.cwd}/tmp/pi-rpc-sessions`;
    this.args = options.args ?? [
      "--mode",
      "rpc",
      "--session-dir",
      this.sessionDir,
      "--no-extensions",
      "--no-themes",
    ];
    this.env = options.env;
    this.responseTimeoutMs = options.responseTimeoutMs ?? 60_000;
    this.onEvent = options.onEvent;
  }

  async start(): Promise<void> {
    if (this.child) {
      throw new Error("Pi RPC client already started");
    }

    await mkdir(this.sessionDir, { recursive: true });

    this.exitPromise = new Promise<void>((resolve) => {
      this.resolveExited = resolve;
    });

    this.child = spawn(this.command, this.args, {
      cwd: this.cwd,
      env: {
        ...process.env,
        ...this.env,
      },
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.child.stdout.on("data", (chunk) => {
      for (const line of this.stdoutDecoder.push(chunk)) {
        this.handleStdoutLine(line);
      }
    });

    this.child.stdout.on("end", () => {
      for (const line of this.stdoutDecoder.end()) {
        this.handleStdoutLine(line);
      }
    });

    this.child.stderr.on("data", (chunk) => {
      for (const line of this.stderrDecoder.push(chunk)) {
        if (line.length > 0) {
          this.collector.recordStderr(line);
        }
      }
    });

    this.child.stderr.on("end", () => {
      for (const line of this.stderrDecoder.end()) {
        if (line.length > 0) {
          this.collector.recordStderr(line);
        }
      }
    });

    this.child.on("error", (error) => {
      this.resolveExited?.();
      this.rejectAllPending(error);
    });

    this.child.on("exit", (_code, signal) => {
      this.resolveExited?.();
      const reason = new Error(`Pi RPC process exited unexpectedly${signal ? ` (${signal})` : ""}`);
      this.rejectAllPending(reason);
    });

    await this.request({ type: "get_state" });
  }

  async runFixture(options: RunFixtureOptions): Promise<SpikeRunSummary> {
    const { issue, timeoutMs, exportHtmlPath, model, thinkingLevel } = options;
    const sessionName = `${issue.identifier}: ${issue.title}`;

    this.collector.setIssueContext(issue.identifier, this.cwd);
    this.collector.setSessionName(sessionName);

    try {
      await this.request({ type: "set_session_name", name: sessionName });
      await this.request({ type: "set_auto_retry", enabled: false });
      await this.request({ type: "set_auto_compaction", enabled: false });

      if (model) {
        await this.request({
          type: "set_model",
          provider: model.provider,
          modelId: model.modelId,
        });
      }

      if (thinkingLevel) {
        await this.request({ type: "set_thinking_level", level: thinkingLevel });
      }

      this.agentEndPromise = new Promise<void>((resolve) => {
        this.resolveAgentEnd = resolve;
      });

      await this.request({
        type: "prompt",
        message: renderFixturePrompt(issue),
      });

      const timedOut = await this.waitForAgentEnd(timeoutMs);
      if (timedOut) {
        this.collector.markTimedOut();
        this.collector.markAborted();
        return this.collector.finalize();
      }

      await this.request({ type: "get_last_assistant_text" });
      await this.request({ type: "get_session_stats" });

      if (exportHtmlPath) {
        await this.request({ type: "export_html", outputPath: exportHtmlPath });
      }

      return this.collector.finalize();
    } finally {
      await this.stop();
    }
  }

  async stop(graceMs = 2_000): Promise<void> {
    if (!this.child) {
      return;
    }

    const child = this.child;
    const exitPromise = this.exitPromise ?? Promise.resolve();

    if (!child.stdin.destroyed) {
      child.stdin.end();
    }

    if (!child.killed) {
      child.kill("SIGTERM");
    }

    const exitedAfterTerm = await waitFor(exitPromise, graceMs);
    if (!exitedAfterTerm) {
      child.kill("SIGKILL");
      await waitFor(exitPromise, 1_000);
    }

    this.child = undefined;
  }

  private async waitForAgentEnd(timeoutMs: number): Promise<boolean> {
    if (!this.agentEndPromise) {
      throw new Error("agent end promise was not initialized");
    }

    const timedOut = await Promise.race([
      this.agentEndPromise.then(() => false),
      new Promise<boolean>((resolve) => {
        const timeout = setTimeout(() => {
          void this.request({ type: "abort" }).catch(() => undefined);
          resolve(true);
        }, timeoutMs);

        this.agentEndPromise?.finally(() => {
          clearTimeout(timeout);
        });
      }),
    ]);

    return timedOut;
  }

  private async request(command: RpcCommand): Promise<unknown> {
    if (!this.child) {
      throw new Error("Pi RPC client is not running");
    }

    const withId = withCommandId(command);

    const result = await new Promise<unknown>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingResponses.delete(withId.id);
        reject(new Error(`Timed out waiting for response to ${withId.type}`));
      }, this.responseTimeoutMs);

      this.pendingResponses.set(withId.id, { resolve, reject, timeout });
      this.child?.stdin.write(`${JSON.stringify(withId)}\n`);
    });

    return result;
  }

  private handleStdoutLine(line: string): void {
    if (line.trim().length === 0) {
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      this.collector.recordStderr(`Non-JSON stdout line: ${line}`);
      this.rejectAllPending(error);
      return;
    }

    if (isRpcResponseEnvelope(parsed)) {
      this.collector.recordResponse(parsed);
      if (!parsed.id) {
        return;
      }

      const pending = this.pendingResponses.get(parsed.id);
      if (!pending) {
        return;
      }

      clearTimeout(pending.timeout);
      this.pendingResponses.delete(parsed.id);

      if (!parsed.success) {
        pending.reject(new Error(parsed.error ?? `RPC command ${parsed.command} failed`));
        return;
      }

      pending.resolve(parsed.data);
      return;
    }

    if (isRpcExtensionUiRequest(parsed)) {
      this.collector.recordExtensionUiRequest(parsed);
      const autoResponse = autoRespondToExtensionUiRequest(parsed);
      if (autoResponse && this.child) {
        this.child.stdin.write(`${JSON.stringify(autoResponse)}\n`);
      }
      return;
    }

    if (isRpcEventEnvelope(parsed)) {
      this.collector.recordEvent(parsed);
      this.onEvent?.(parsed);
      if (parsed.type === "agent_end") {
        this.resolveAgentEnd?.();
      }
      return;
    }

    this.collector.recordStderr(`Unknown protocol message: ${JSON.stringify(parsed)}`);
  }

  private rejectAllPending(reason: unknown): void {
    for (const [id, pending] of this.pendingResponses.entries()) {
      clearTimeout(pending.timeout);
      pending.reject(reason);
      this.pendingResponses.delete(id);
    }
  }
}

function waitFor(promise: Promise<void>, timeoutMs: number): Promise<boolean> {
  return Promise.race([
    promise.then(() => true),
    new Promise<boolean>((resolve) => {
      setTimeout(() => resolve(false), timeoutMs);
    }),
  ]);
}

export function renderFixturePrompt(issue: FixtureIssue): string {
  const labels = issue.labels?.length ? issue.labels.join(", ") : "none";
  const description = issue.description?.trim() || "No description provided.";

  return [
    `You are working on fixture issue ${issue.identifier}.`,
    "",
    `Title: ${issue.title}`,
    `State: ${issue.state ?? "Unknown"}`,
    `Labels: ${labels}`,
    `URL: ${issue.url ?? "n/a"}`,
    "",
    "Description:",
    description,
    "",
    "Instructions:",
    "- This is a Pi RPC spike for unattended worker execution.",
    "- Do not ask the user questions.",
    "- Do not use tools unless they are absolutely required.",
    "- Respond with exactly one line in the format: SPIKE_OK <issue identifier>.",
  ].join("\n");
}
