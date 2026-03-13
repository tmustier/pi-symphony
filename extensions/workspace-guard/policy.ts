import path from "node:path";

export interface GuardDecision {
  blocked: boolean;
  reason?: string;
  matchedPath?: string;
}

const PATH_TOKEN_PATTERN =
  /(^|[\s\t\n\r'"=<>])(\/[^\s\t\n\r'";&|]+|~\/[^\s\t\n\r'";&|]+|\.\.?(?:\/[^\s\t\n\r'";&|]*)?)/g;

export function evaluateToolCall(
  workspaceRoot: string,
  toolName: string,
  input: Record<string, unknown>,
): GuardDecision | null {
  if (toolName === "read" || toolName === "write" || toolName === "edit") {
    const targetPath = typeof input.path === "string" ? input.path : null;
    if (targetPath === null) {
      return null;
    }

    return evaluatePathAccess(workspaceRoot, targetPath);
  }

  if (toolName === "bash") {
    const command = typeof input.command === "string" ? input.command : null;
    if (command === null) {
      return null;
    }

    return evaluateBashCommand(workspaceRoot, command);
  }

  return null;
}

export function evaluatePathAccess(workspaceRoot: string, candidatePath: string): GuardDecision {
  const normalizedRoot = path.resolve(workspaceRoot);
  const normalizedCandidate = resolveCandidatePath(normalizedRoot, candidatePath);

  if (normalizedCandidate === null) {
    return {
      blocked: true,
      reason: `Path "${candidatePath}" is not allowed outside workspace ${normalizedRoot}`,
      matchedPath: candidatePath,
    };
  }

  if (!isWithinWorkspace(normalizedRoot, normalizedCandidate)) {
    return {
      blocked: true,
      reason: `Path "${candidatePath}" escapes workspace ${normalizedRoot}`,
      matchedPath: candidatePath,
    };
  }

  return { blocked: false, matchedPath: candidatePath };
}

export function evaluateBashCommand(workspaceRoot: string, command: string): GuardDecision {
  const suspiciousTokens = extractPathTokens(command);

  for (const token of suspiciousTokens) {
    const decision = evaluatePathAccess(workspaceRoot, token);
    if (decision.blocked) {
      return {
        blocked: true,
        reason: `Command references path outside workspace: ${token}`,
        matchedPath: token,
      };
    }
  }

  return { blocked: false };
}

export function extractPathTokens(command: string): string[] {
  const tokens = new Set<string>();

  for (const match of command.matchAll(PATH_TOKEN_PATTERN)) {
    const rawToken = match[2];
    const cleanedToken = rawToken.replace(/[),:;]+$/, "");

    if (cleanedToken.length > 0) {
      tokens.add(cleanedToken);
    }
  }

  return [...tokens];
}

function resolveCandidatePath(workspaceRoot: string, candidatePath: string): string | null {
  const trimmedPath = candidatePath.trim();

  if (trimmedPath === "" || trimmedPath.includes("\u0000")) {
    return null;
  }

  if (trimmedPath === ".." || trimmedPath.startsWith("../") || trimmedPath.includes("/../")) {
    return path.resolve(workspaceRoot, trimmedPath);
  }

  if (trimmedPath === "." || trimmedPath.startsWith("./")) {
    return path.resolve(workspaceRoot, trimmedPath);
  }

  if (trimmedPath.startsWith("~/")) {
    return path.resolve(homeDirectory(), trimmedPath.slice(2));
  }

  if (path.isAbsolute(trimmedPath)) {
    return path.resolve(trimmedPath);
  }

  return path.resolve(workspaceRoot, trimmedPath);
}

function homeDirectory(): string {
  return process.env.HOME ?? path.resolve("/");
}

function isWithinWorkspace(workspaceRoot: string, candidatePath: string): boolean {
  const relative = path.relative(workspaceRoot, candidatePath);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}
