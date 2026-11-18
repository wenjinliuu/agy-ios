import crypto from "node:crypto";
import os from "node:os";
import path from "node:path";

export interface BridgeConfig {
  bindHost: string;
  port: number;
  authToken: string;
  relayWsUrl: string;
  relayAuthToken: string;
  agyBin: string;
  agyDataDir: string;
  defaultWorkspace: string;
  defaultModel: string;
  hostname: string;
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BridgeConfig {
  const home = os.homedir();
  const authToken = (env.BRIDGE_AUTH_TOKEN || "").trim();
  const relayAuthToken = (env.RELAY_AUTH_TOKEN || authToken).trim();

  const parsedPort = Number.parseInt(env.BRIDGE_PORT ?? "8787", 10);

  return {
    bindHost: (env.BRIDGE_BIND_HOST || "127.0.0.1").trim(),
    port: Number.isFinite(parsedPort) && parsedPort >= 0 ? parsedPort : 8787,
    authToken,
    relayWsUrl: (env.RELAY_WS_URL || "").trim(),
    relayAuthToken,
    agyBin: (env.AGY_BIN || path.join(home, ".local/bin/agy")).trim(),
    agyDataDir: (
      env.AGY_DATA_DIR || path.join(home, ".gemini/antigravity-cli")
    ).trim(),
    defaultWorkspace: (env.AGY_DEFAULT_WORKSPACE || home).trim(),
    defaultModel: (env.AGY_DEFAULT_MODEL || "").trim(),
    hostname: os.hostname(),
  };
}

export function constantTimeTokenEqual(a: string, b: string): boolean {
  if (!a || !b) {
    return false;
  }
  const digestA = crypto.createHash("sha256").update(a).digest();
  const digestB = crypto.createHash("sha256").update(b).digest();
  return crypto.timingSafeEqual(digestA, digestB);
}

export function extractBearerToken(headerValue: string | undefined): string {
  if (!headerValue) {
    return "";
  }
  const match = headerValue.match(/^\s*Bearer\s+(.+?)\s*$/i);
  return match ? match[1] : "";
}
