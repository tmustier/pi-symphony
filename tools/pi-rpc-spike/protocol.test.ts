import { describe, expect, it } from "vitest";

import {
  autoRespondToExtensionUiRequest,
  isRpcEventEnvelope,
  isRpcExtensionUiRequest,
  isRpcResponseEnvelope,
} from "./protocol.js";

describe("protocol helpers", () => {
  it("detects response envelopes", () => {
    expect(isRpcResponseEnvelope({ type: "response", command: "get_state", success: true })).toBe(
      true,
    );
    expect(isRpcResponseEnvelope({ type: "response", command: "get_state" })).toBe(false);
    expect(isRpcResponseEnvelope({ type: "agent_end" })).toBe(false);
  });

  it("detects extension UI requests", () => {
    expect(
      isRpcExtensionUiRequest({ type: "extension_ui_request", id: "1", method: "confirm" }),
    ).toBe(true);
    expect(isRpcExtensionUiRequest({ type: "extension_ui_request", method: "confirm" })).toBe(
      false,
    );
  });

  it("auto-cancels blocking dialog requests but ignores fire-and-forget requests", () => {
    expect(
      autoRespondToExtensionUiRequest({
        type: "extension_ui_request",
        id: "1",
        method: "confirm",
      }),
    ).toEqual({
      type: "extension_ui_response",
      id: "1",
      cancelled: true,
    });

    expect(
      autoRespondToExtensionUiRequest({
        type: "extension_ui_request",
        id: "2",
        method: "notify",
      }),
    ).toBeNull();
  });

  it("treats non-response protocol objects as events", () => {
    expect(isRpcEventEnvelope({ type: "agent_end" })).toBe(true);
    expect(isRpcEventEnvelope({ type: "response", command: "get_state", success: true })).toBe(
      false,
    );
  });
});
