import type { AgyRunner } from "./agy-runner.ts";
import { AgyStore, isValidConversationId } from "./agy-store.ts";
import type { BridgeConfig } from "./config.ts";
import type { SendPromptPayload } from "./protocol.ts";

export interface ApiRequestInput {
  method: string;
  path: string;
  query?: string;
  body?: string;
}

export interface ApiResponseOutput {
  status: number;
  contentType: string;
  body: string;
}

export interface RouterDeps {
  config: BridgeConfig;
  store: AgyStore;
  runner: AgyRunner;
}

function json(status: number, data: unknown): ApiResponseOutput {
  return {
    status,
    contentType: "application/json; charset=utf-8",
    body: JSON.stringify(data),
  };
}

export async function handleApiRequest(
  req: ApiRequestInput,
  deps: RouterDeps,
): Promise<ApiResponseOutput> {
  const url = new URL(
    `${req.path}${req.query || ""}`,
    "http://bridge.local",
  );
  const pathname = url.pathname;
  const method = req.method.toUpperCase();

  if (method === "GET" && pathname === "/v1/health") {
    const agyVersion = await deps.runner.getVersion();
    return json(200, {
      ok: true,
      bridgeVersion: "0.1.0",
      hostname: deps.config.hostname,
      agyVersion,
      activeRuns: deps.runner.getActiveRunCount(),
      defaultWorkspace: deps.config.defaultWorkspace,
      defaultModel: deps.config.defaultModel || null,
      timestamp: new Date().toISOString(),
    });
  }

  if (method === "GET" && pathname === "/v1/config/overview") {
    const agyVersion = await deps.runner.getVersion();
    const overview = deps.store.readSafeConfigOverview();
    return json(200, {
      agyVersion,
      bridgeVersion: "0.1.0",
      hostname: deps.config.hostname,
      defaultWorkspace: deps.config.defaultWorkspace,
      defaultModel: deps.config.defaultModel || null,
      activeConversationIds: [...deps.runner.getActiveConversationIds()],
      ...overview,
    });
  }

  const toggleMcpMatch = pathname.match(/^\/v1\/config\/mcp\/([^/]+)\/toggle$/);
  if (method === "POST" && toggleMcpMatch) {
    const name = decodeURIComponent(toggleMcpMatch[1]);
    let body: { enabled?: boolean };
    try {
      body = JSON.parse(req.body || "{}") as { enabled?: boolean };
    } catch {
      return json(400, { error: "Invalid JSON body" });
    }
    if (typeof body.enabled !== "boolean") {
      return json(400, { error: "enabled boolean is required" });
    }
    try {
      await deps.runner.toggleMcpServer(name, body.enabled);
      return json(200, { ok: true, name, enabled: body.enabled });
    } catch (err) {
      return json(400, {
        error: err instanceof Error ? err.message : "Failed to toggle MCP server",
      });
    }
  }

  if (method === "GET" && pathname === "/v1/models") {
    try {
      const refresh = url.searchParams.get("refresh") === "1";
      const models = await deps.runner.listModels(refresh);
      return json(200, { models });
    } catch (err) {
      return json(502, {
        error: err instanceof Error ? err.message : "Failed to list models",
      });
    }
  }

  if (method === "GET" && pathname === "/v1/workspaces") {
    const workspaces = deps.store.listKnownWorkspaces(
      deps.config.defaultWorkspace,
    );
    return json(200, { workspaces });
  }

  if (method === "GET" && pathname === "/v1/conversations") {
    const limit = Number.parseInt(url.searchParams.get("limit") || "50", 10);
    const query = url.searchParams.get("q") || "";
    const conversations = deps.store.listConversations({
      limit: Number.isFinite(limit) ? limit : 50,
      query,
      activeIds: deps.runner.getActiveConversationIds(),
    });
    return json(200, { conversations });
  }

  const messagesMatch = pathname.match(/^\/v1\/conversations\/([^/]+)\/messages$/);
  if (method === "GET" && messagesMatch) {
    const cid = decodeURIComponent(messagesMatch[1]);
    if (!isValidConversationId(cid)) {
      return json(400, { error: "Invalid conversation ID" });
    }
    const conversation = deps.store.getConversationSummary(
      cid,
      deps.runner.getActiveConversationIds(),
    );
    if (!conversation) {
      return json(404, { error: "Conversation not found" });
    }
    const limit = Number.parseInt(url.searchParams.get("limit") || "200", 10);
    const includeSystem = url.searchParams.get("includeSystem") === "1";
    const messages = deps.store.getMessages(cid, {
      limit: Number.isFinite(limit) ? limit : 200,
      includeSystem,
    });
    return json(200, { conversation, messages });
  }

  const abortMatch = pathname.match(/^\/v1\/conversations\/([^/]+)\/abort$/);
  if (method === "POST" && abortMatch) {
    const cid = decodeURIComponent(abortMatch[1]);
    if (!isValidConversationId(cid)) {
      return json(400, { error: "Invalid conversation ID" });
    }
    const aborted = deps.runner.abortConversation(cid);
    return json(200, { aborted, conversationId: cid });
  }

  const titleMatch = pathname.match(/^\/v1\/conversations\/([^/]+)\/title$/);
  if (method === "POST" && titleMatch) {
    const cid = decodeURIComponent(titleMatch[1]);
    if (!isValidConversationId(cid)) {
      return json(400, { error: "Invalid conversation ID" });
    }
    let body: { title?: string };
    try {
      body = JSON.parse(req.body || "{}") as { title?: string };
    } catch {
      return json(400, { error: "Invalid JSON body" });
    }
    try {
      const updated = deps.store.renameConversationTitle(cid, body.title || "");
      if (!updated) {
        return json(404, { error: "Conversation not found" });
      }
      return json(200, { conversation: updated });
    } catch (err) {
      return json(400, {
        error: err instanceof Error ? err.message : "Failed to update title",
      });
    }
  }

  if (method === "POST" && pathname === "/v1/conversations/send") {
    let payload: SendPromptPayload;
    try {
      payload = JSON.parse(req.body || "{}") as SendPromptPayload;
    } catch {
      return json(400, { error: "Invalid JSON body" });
    }
    if (!payload.prompt || !payload.prompt.trim()) {
      return json(400, { error: "prompt is required" });
    }
    if (payload.conversationId && !isValidConversationId(payload.conversationId)) {
      return json(400, { error: "Invalid conversationId" });
    }
    try {
      const started = deps.runner.startRun(payload);
      return json(202, started);
    } catch (err) {
      const status = (err as { statusCode?: number }).statusCode || 400;
      return json(status, {
        error: err instanceof Error ? err.message : "Failed to start run",
      });
    }
  }

  return json(404, { error: "Not found" });
}
