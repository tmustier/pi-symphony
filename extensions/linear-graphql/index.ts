import type { ExtensionApiLike, ToolExecutionResult } from "../shared/pi-types.js";
import { LINEAR_GRAPHQL_PARAMETERS, executeLinearGraphql } from "./bridge.js";

export default function linearGraphqlExtension(pi: ExtensionApiLike): void {
  pi.registerTool?.({
    name: "linear_graphql",
    label: "Linear GraphQL",
    description:
      "Execute a raw GraphQL query or mutation against Linear using pi-symphony worker auth.",
    promptSnippet: "Run Linear GraphQL queries and mutations using configured worker auth.",
    promptGuidelines: [
      "Use this tool when the task requires reading or mutating tracker state in Linear.",
      "Prefer targeted queries and mutations instead of large exploratory payloads.",
    ],
    parameters: LINEAR_GRAPHQL_PARAMETERS,
    async execute(_toolCallId, params): Promise<ToolExecutionResult> {
      const result = await executeLinearGraphql(params);

      return {
        content: [{ type: "text", text: result.output }],
        details: result.details,
        isError: !result.success,
      };
    },
  });
}
