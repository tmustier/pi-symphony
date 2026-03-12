import { describe, expect, it } from "vitest";

import { JsonlDecoder } from "./jsonl.js";

describe("JsonlDecoder", () => {
  it("buffers partial chunks until a newline arrives", () => {
    const decoder = new JsonlDecoder();

    expect(decoder.push(Buffer.from('{"type":"one"}'))).toEqual([]);
    expect(decoder.push(Buffer.from('\n{"type":"two"}\n'))).toEqual([
      '{"type":"one"}',
      '{"type":"two"}',
    ]);
  });

  it("normalizes CRLF line endings", () => {
    const decoder = new JsonlDecoder();

    expect(decoder.push(Buffer.from('{"type":"one"}\r\n'))).toEqual(['{"type":"one"}']);
  });

  it("flushes any remaining buffered content on end", () => {
    const decoder = new JsonlDecoder();

    decoder.push(Buffer.from('{"type":"tail"}'));
    expect(decoder.end()).toEqual(['{"type":"tail"}']);
  });
});
