export const LINEAR_GRAPHQL_PARAMETERS = {
  type: "object",
  additionalProperties: false,
  required: ["query"],
  properties: {
    query: {
      type: "string",
      description: "GraphQL query or mutation document to execute against Linear.",
    },
    variables: {
      type: ["object", "null"],
      description: "Optional GraphQL variables object.",
      additionalProperties: true,
    },
  },
} as const;

export interface LinearEnvConfig {
  trackerKind: string;
  endpoint: string;
  apiKey: string | null;
}

export interface LinearGraphqlRequest {
  query: string;
  variables: Record<string, unknown>;
}

export interface LinearGraphqlToolResponse {
  success: boolean;
  output: string;
  details: Record<string, unknown>;
}

export type FetchLike = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export function loadLinearEnvConfig(env: NodeJS.ProcessEnv = process.env): LinearEnvConfig {
  return {
    trackerKind: env.PI_SYMPHONY_TRACKER_KIND ?? "linear",
    endpoint: env.PI_SYMPHONY_LINEAR_ENDPOINT ?? "https://api.linear.app/graphql",
    apiKey: env.PI_SYMPHONY_LINEAR_API_KEY ?? null,
  };
}

export function normalizeLinearGraphqlArguments(
  argumentsValue: unknown,
): { ok: true; request: LinearGraphqlRequest } | { ok: false; error: Record<string, unknown> } {
  if (typeof argumentsValue === "string") {
    const query = argumentsValue.trim();
    if (query.length === 0) {
      return { ok: false, error: toolErrorPayload("missing_query") };
    }

    return { ok: true, request: { query, variables: {} } };
  }

  if (
    typeof argumentsValue !== "object" ||
    argumentsValue === null ||
    Array.isArray(argumentsValue)
  ) {
    return { ok: false, error: toolErrorPayload("invalid_arguments") };
  }

  const argumentsRecord = argumentsValue as Record<string, unknown>;
  const queryValue = typeof argumentsRecord.query === "string" ? argumentsRecord.query : null;

  if (queryValue === null || queryValue.trim().length === 0) {
    return { ok: false, error: toolErrorPayload("missing_query") };
  }

  const rawVariables = argumentsRecord.variables ?? {};

  if (typeof rawVariables !== "object" || Array.isArray(rawVariables)) {
    return { ok: false, error: toolErrorPayload("invalid_variables") };
  }

  return {
    ok: true,
    request: {
      query: queryValue.trim(),
      variables: rawVariables as Record<string, unknown>,
    },
  };
}

export async function executeLinearGraphql(
  argumentsValue: unknown,
  options: {
    env?: NodeJS.ProcessEnv;
    fetchImpl?: FetchLike;
  } = {},
): Promise<LinearGraphqlToolResponse> {
  const normalized = normalizeLinearGraphqlArguments(argumentsValue);
  if (!normalized.ok) {
    return failureResponse(normalized.error);
  }

  const config = loadLinearEnvConfig(options.env);

  if (config.trackerKind !== "linear") {
    return failureResponse(toolErrorPayload("unsupported_tracker_kind", config.trackerKind));
  }

  if (config.apiKey === null || config.apiKey.trim().length === 0) {
    return failureResponse(toolErrorPayload("missing_linear_api_token"));
  }

  const fetchImpl = options.fetchImpl ?? fetch;

  try {
    const response = await fetchImpl(config.endpoint, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: config.apiKey,
      },
      body: JSON.stringify({
        query: normalized.request.query,
        variables: normalized.request.variables,
      }),
    });

    const text = await response.text();
    const payload = decodeJsonObject(text);

    if (!response.ok) {
      return failureResponse(
        toolErrorPayload("linear_api_status", response.status, payload ?? text),
      );
    }

    if (payload === null) {
      return failureResponse(toolErrorPayload("linear_api_request", "invalid_json_response"));
    }

    if (Array.isArray(payload.errors) && payload.errors.length > 0) {
      return successResponse(false, payload);
    }

    return successResponse(true, payload);
  } catch (error) {
    return failureResponse(toolErrorPayload("linear_api_request", describeError(error)));
  }
}

function successResponse(
  success: boolean,
  payload: Record<string, unknown>,
): LinearGraphqlToolResponse {
  return {
    success,
    output: encodePayload(payload),
    details: {
      success,
      payload,
    },
  };
}

function failureResponse(payload: Record<string, unknown>): LinearGraphqlToolResponse {
  return {
    success: false,
    output: encodePayload(payload),
    details: {
      success: false,
      payload,
    },
  };
}

function toolErrorPayload(kind: "missing_query"): Record<string, unknown>;
function toolErrorPayload(kind: "invalid_arguments"): Record<string, unknown>;
function toolErrorPayload(kind: "invalid_variables"): Record<string, unknown>;
function toolErrorPayload(kind: "missing_linear_api_token"): Record<string, unknown>;
function toolErrorPayload(
  kind: "unsupported_tracker_kind",
  trackerKind: string,
): Record<string, unknown>;
function toolErrorPayload(
  kind: "linear_api_status",
  status: number,
  payload: Record<string, unknown> | string | null,
): Record<string, unknown>;
function toolErrorPayload(kind: "linear_api_request", reason: string): Record<string, unknown>;
function toolErrorPayload(
  kind:
    | "missing_query"
    | "invalid_arguments"
    | "invalid_variables"
    | "missing_linear_api_token"
    | "unsupported_tracker_kind"
    | "linear_api_status"
    | "linear_api_request",
  detail?: number | string | Record<string, unknown> | null,
  payload?: Record<string, unknown> | string | null,
): Record<string, unknown> {
  switch (kind) {
    case "missing_query":
      return {
        error: {
          message: "`linear_graphql` requires a non-empty `query` string.",
        },
      };
    case "invalid_arguments":
      return {
        error: {
          message:
            "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`.",
        },
      };
    case "invalid_variables":
      return {
        error: {
          message: "`linear_graphql.variables` must be a JSON object when provided.",
        },
      };
    case "missing_linear_api_token":
      return {
        error: {
          message:
            "Symphony is missing Linear auth. Set `tracker.api_key` in `WORKFLOW.md` so the Pi worker can receive `PI_SYMPHONY_LINEAR_API_KEY`.",
        },
      };
    case "unsupported_tracker_kind":
      return {
        error: {
          message: `Tracker kind ${JSON.stringify(detail)} does not support the linear_graphql bridge.`,
        },
      };
    case "linear_api_status":
      return {
        error: {
          message: `Linear GraphQL request failed with HTTP ${detail}.`,
          status: detail,
          payload: payload ?? null,
        },
      };
    case "linear_api_request":
      return {
        error: {
          message: "Linear GraphQL request failed before receiving a successful response.",
          reason: detail,
        },
      };
  }
}

function encodePayload(payload: Record<string, unknown>): string {
  return JSON.stringify(payload, null, 2);
}

function decodeJsonObject(text: string): Record<string, unknown> | null {
  try {
    const payload = JSON.parse(text) as unknown;
    return typeof payload === "object" && payload !== null && !Array.isArray(payload)
      ? (payload as Record<string, unknown>)
      : null;
  } catch {
    return null;
  }
}

function describeError(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return String(error);
}
