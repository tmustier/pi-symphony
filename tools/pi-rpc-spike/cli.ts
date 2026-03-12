import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

import { type FixtureIssue, PiRpcClient } from "./client.js";

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const fixturePath = args.fixture ?? path.join(process.cwd(), "examples/fixture-issue.json");
  const timeoutMs = Number.parseInt(args.timeoutMs ?? "45000", 10);
  const outputPath = args.output ?? path.join(process.cwd(), "tmp/pi-rpc-spike-summary.json");
  const exportHtmlPath =
    args.exportHtml ?? path.join(process.cwd(), "tmp/pi-rpc-spike-session.html");

  const issue = JSON.parse(await readFile(fixturePath, "utf8")) as FixtureIssue;
  const sessionDir = path.join(
    process.cwd(),
    "tmp/pi-rpc-sessions",
    `${sanitize(issue.identifier)}-${Date.now()}`,
  );

  await mkdir(path.dirname(outputPath), { recursive: true });
  await mkdir(path.dirname(exportHtmlPath), { recursive: true });
  await mkdir(sessionDir, { recursive: true });

  const client = new PiRpcClient({
    cwd: process.cwd(),
    sessionDir,
  });

  await client.start();
  const summary = await client.runFixture({
    issue,
    timeoutMs,
    exportHtmlPath,
  });

  await writeFile(outputPath, `${JSON.stringify(summary, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
}

function sanitize(value: string): string {
  return value.replace(/[^A-Za-z0-9._-]/g, "_");
}

function parseArgs(argv: string[]): Record<string, string> {
  const args: Record<string, string> = {};

  for (let index = 0; index < argv.length; index += 1) {
    const current = argv[index];
    if (!current?.startsWith("--")) {
      continue;
    }

    const key = current.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      args[key] = "true";
      continue;
    }

    args[key] = next;
    index += 1;
  }

  return args;
}

main().catch((error) => {
  const message = error instanceof Error ? (error.stack ?? error.message) : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
