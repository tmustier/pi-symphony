import type {
  ExtensionApiLike,
  ExtensionContextLike,
  ToolBlockResult,
  ToolCallEventLike,
} from "../shared/pi-types.js";
import { evaluateToolCall } from "./policy.js";

export default function workspaceGuard(pi: ExtensionApiLike): void {
  const workspaceRoot = process.cwd();

  pi.on("tool_call", async (rawEvent, rawContext) => {
    const event = rawEvent as ToolCallEventLike;
    const ctx = rawContext as ExtensionContextLike;

    const decision = evaluateToolCall(workspaceRoot, event.toolName, event.input);

    if (decision === null || !decision.blocked || !decision.reason) {
      return undefined;
    }

    if (ctx.hasUI && ctx.ui) {
      ctx.ui.notify(`workspace-guard blocked ${event.toolName}: ${decision.reason}`, "warning");
    }

    const result: ToolBlockResult = {
      block: true,
      reason: decision.reason,
    };

    return result;
  });
}
