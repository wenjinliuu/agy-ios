import { authorizeRole, type AuthEnv } from "./auth.ts";
import { BridgeRelayDO } from "./relay-do.ts";

export { BridgeRelayDO };

export interface Env extends AuthEnv {
  RELAY: DurableObjectNamespace<BridgeRelayDO>;
}

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Authorization, Content-Type",
};

function withCors(response: Response): Response {
  if (response.status === 101) {
    return response;
  }
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(CORS_HEADERS)) {
    headers.set(k, v);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return withCors(
        Response.json({
          ok: true,
          service: "agy-relay-worker",
          timestamp: new Date().toISOString(),
        }),
      );
    }

    if (url.pathname === "/v1/relay/vps") {
      if (!(await authorizeRole(request, env, "vps"))) {
        return withCors(Response.json({ error: "Unauthorized" }, { status: 401 }));
      }
      const stub = env.RELAY.get(env.RELAY.idFromName("default"));
      return stub.fetch(request);
    }

    if (url.pathname.startsWith("/v1/")) {
      if (!(await authorizeRole(request, env, "client"))) {
        return withCors(Response.json({ error: "Unauthorized" }, { status: 401 }));
      }
      const stub = env.RELAY.get(env.RELAY.idFromName("default"));
      return withCors(await stub.fetch(request));
    }

    return withCors(Response.json({ error: "Not found" }, { status: 404 }));
  },
};
