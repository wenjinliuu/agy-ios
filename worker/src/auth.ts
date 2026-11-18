const encoder = new TextEncoder();

export interface AuthEnv {
  AUTH_TOKEN?: string;
  CLIENT_AUTH_TOKEN?: string;
  VPS_AUTH_TOKEN?: string;
}

/**
 * Compares two strings via SHA-256 digest equality so token length and prefix
 * timing cannot leak over network responses.
 */
export async function constantTimeTokenEqual(a: string, b: string): Promise<boolean> {
  if (!a || !b) {
    return false;
  }
  const [hashA, hashB] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(a)),
    crypto.subtle.digest("SHA-256", encoder.encode(b)),
  ]);
  const bytesA = new Uint8Array(hashA);
  const bytesB = new Uint8Array(hashB);
  let diff = 0;
  for (let i = 0; i < bytesA.length; i += 1) {
    diff |= bytesA[i] ^ bytesB[i];
  }
  return diff === 0;
}

export function extractBearerToken(authorizationHeader: string | null): string {
  if (!authorizationHeader) {
    return "";
  }
  const match = authorizationHeader.match(/^\s*Bearer\s+(.+?)\s*$/i);
  return match ? match[1] : "";
}

export async function authorizeRole(
  request: Request,
  env: AuthEnv,
  role: "client" | "vps",
): Promise<boolean> {
  const expected =
    role === "vps"
      ? (env.VPS_AUTH_TOKEN || env.AUTH_TOKEN || "").trim()
      : (env.CLIENT_AUTH_TOKEN || env.AUTH_TOKEN || "").trim();

  if (!expected) {
    return false;
  }
  const provided = extractBearerToken(request.headers.get("Authorization"));
  return constantTimeTokenEqual(provided, expected);
}
