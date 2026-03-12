import { StringDecoder } from "node:string_decoder";

export class JsonlDecoder {
  private readonly decoder = new StringDecoder("utf8");
  private buffer = "";

  push(chunk: Buffer | string): string[] {
    this.buffer += typeof chunk === "string" ? chunk : this.decoder.write(chunk);
    return this.drainLines(false);
  }

  end(): string[] {
    this.buffer += this.decoder.end();
    return this.drainLines(true);
  }

  private drainLines(flushRemainder: boolean): string[] {
    const lines: string[] = [];

    while (true) {
      const newlineIndex = this.buffer.indexOf("\n");
      if (newlineIndex === -1) {
        break;
      }

      let line = this.buffer.slice(0, newlineIndex);
      this.buffer = this.buffer.slice(newlineIndex + 1);

      if (line.endsWith("\r")) {
        line = line.slice(0, -1);
      }

      lines.push(line);
    }

    if (flushRemainder && this.buffer.length > 0) {
      let line = this.buffer;
      this.buffer = "";

      if (line.endsWith("\r")) {
        line = line.slice(0, -1);
      }

      lines.push(line);
    }

    return lines;
  }
}
