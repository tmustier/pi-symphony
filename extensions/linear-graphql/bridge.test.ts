import { describe, expect, it, vi } from "vitest";

import {
  executeLinearGraphql,
  loadLinearEnvConfig,
  normalizeLinearGraphqlArguments,
} from "./bridge.js";

describe("linear graphql bridge", () => {
  it("loads configuration from the worker environment", () => {
    expect(
      loadLinearEnvConfig({
        PI_SYMPHONY_TRACKER_KIND: "linear",
        PI_SYMPHONY_LINEAR_ENDPOINT: "https://linear.example/graphql",
        PI_SYMPHONY_LINEAR_API_KEY: "secret-token",
      }),
    ).toEqual({
      trackerKind: "linear",
      endpoint: "https://linear.example/graphql",
      apiKey: "secret-token",
    });
  });

  it("normalizes raw query strings and object arguments", () => {
    expect(normalizeLinearGraphqlArguments("query Viewer { viewer { id } }")).toEqual({
      ok: true,
      request: {
        query: "query Viewer { viewer { id } }",
        variables: {},
      },
    });

    expect(
      normalizeLinearGraphqlArguments({
        query: "mutation Update($id: String!) { issue(id: $id) { id } }",
        variables: { id: "issue-1" },
      }),
    ).toEqual({
      ok: true,
      request: {
        query: "mutation Update($id: String!) { issue(id: $id) { id } }",
        variables: { id: "issue-1" },
      },
    });
  });

  it("rejects blank queries, invalid arguments, and invalid variables", () => {
    expect(normalizeLinearGraphqlArguments("   ")).toMatchObject({
      ok: false,
      error: {
        error: { message: "`linear_graphql` requires a non-empty `query` string." },
      },
    });

    expect(normalizeLinearGraphqlArguments(42)).toMatchObject({
      ok: false,
      error: {
        error: {
          message:
            "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`.",
        },
      },
    });

    expect(
      normalizeLinearGraphqlArguments({
        query: "query Viewer { viewer { id } }",
        variables: ["bad"],
      }),
    ).toMatchObject({
      ok: false,
      error: {
        error: { message: "`linear_graphql.variables` must be a JSON object when provided." },
      },
    });
  });

  it("returns a successful response body for successful GraphQL calls", async () => {
    const fetchImpl = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      expect(input).toBe("https://linear.example/graphql");
      expect(init?.headers).toMatchObject({
        authorization: "secret-token",
        "content-type": "application/json",
      });
      expect(JSON.parse(String(init?.body))).toEqual({
        query: "query Viewer { viewer { id } }",
        variables: { includeTeams: false },
      });

      return new Response(JSON.stringify({ data: { viewer: { id: "viewer-1" } } }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });

    const result = await executeLinearGraphql(
      {
        query: "query Viewer { viewer { id } }",
        variables: { includeTeams: false },
      },
      {
        env: {
          PI_SYMPHONY_TRACKER_KIND: "linear",
          PI_SYMPHONY_LINEAR_ENDPOINT: "https://linear.example/graphql",
          PI_SYMPHONY_LINEAR_API_KEY: "secret-token",
        },
        fetchImpl,
      },
    );

    expect(result.success).toBe(true);
    expect(result.output).toContain('"viewer-1"');
  });

  it("marks GraphQL errors as unsuccessful while preserving the payload", async () => {
    const fetchImpl = vi.fn(async () => {
      return new Response(
        JSON.stringify({ errors: [{ message: "boom" }], data: { viewer: null } }),
        {
          status: 200,
          headers: { "content-type": "application/json" },
        },
      );
    });

    const result = await executeLinearGraphql(
      { query: "query Viewer { viewer { id } }" },
      {
        env: {
          PI_SYMPHONY_TRACKER_KIND: "linear",
          PI_SYMPHONY_LINEAR_ENDPOINT: "https://linear.example/graphql",
          PI_SYMPHONY_LINEAR_API_KEY: "secret-token",
        },
        fetchImpl,
      },
    );

    expect(result.success).toBe(false);
    expect(result.output).toContain('"errors"');
    expect(result.output).toContain('"boom"');
  });

  it("formats transport and configuration failures", async () => {
    expect(
      await executeLinearGraphql(
        { query: "query Viewer { viewer { id } }" },
        {
          env: {
            PI_SYMPHONY_TRACKER_KIND: "linear",
            PI_SYMPHONY_LINEAR_ENDPOINT: "https://linear.example/graphql",
          },
        },
      ),
    ).toMatchObject({
      success: false,
      output: expect.stringContaining("Symphony is missing Linear auth"),
    });

    expect(
      await executeLinearGraphql(
        { query: "query Viewer { viewer { id } }" },
        {
          env: {
            PI_SYMPHONY_TRACKER_KIND: "memory",
            PI_SYMPHONY_LINEAR_ENDPOINT: "https://linear.example/graphql",
            PI_SYMPHONY_LINEAR_API_KEY: "secret-token",
          },
        },
      ),
    ).toMatchObject({
      success: false,
      output: expect.stringContaining("does not support the linear_graphql bridge"),
    });

    const non200Fetch = vi.fn(async () => {
      return new Response(JSON.stringify({ errors: [{ message: "bad gateway" }] }), {
        status: 502,
        headers: { "content-type": "application/json" },
      });
    });

    expect(
      await executeLinearGraphql(
        { query: "query Viewer { viewer { id } }" },
        {
          env: {
            PI_SYMPHONY_TRACKER_KIND: "linear",
            PI_SYMPHONY_LINEAR_ENDPOINT: "https://linear.example/graphql",
            PI_SYMPHONY_LINEAR_API_KEY: "secret-token",
          },
          fetchImpl: non200Fetch,
        },
      ),
    ).toMatchObject({
      success: false,
      output: expect.stringContaining("HTTP 502"),
    });
  });
});
