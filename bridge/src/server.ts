import http from "node:http";
import { WebSocketServer, type WebSocket } from "ws";
import {
  constantTimeTokenEqual,
  extractBearerToken,
  type BridgeConfig,
} from "./config.ts";
import type {
  ClientToServerMessage,
  ServerToClientMessage,
} from "./protocol.ts";
import { handleApiRequest, type RouterDeps } from "./router.ts";

function isAuthorized(
  headerValue: string | undefined,
  config: BridgeConfig,
): boolean {
  if (!config.authToken) {
    return false;
  }
  const provided = extractBearerToken(headerValue);
  return constantTimeTokenEqual(provided, config.authToken);
}

function readHttpBody(req: http.IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    req.on("data", (chunk: Buffer) => {
      total += chunk.length;
      if (total > 2 * 1024 * 1024) {
        reject(new Error("Request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

export function dispatchClientWsMessage(
  rawText: string,
  deps: RouterDeps,
  reply: (msg: ServerToClientMessage) => void,
): void {
  if (!rawText || rawText === "ping") {
    return;
  }
  let parsed: ClientToServerMessage;
  try {
    parsed = JSON.parse(rawText) as ClientToServerMessage;
  } catch {
    reply({ type: "run.error", message: "Malformed JSON message" });
    return;
  }

  if (parsed.type === "chat.send") {
    try {
      deps.runner.startRun(parsed);
    } catch (err) {
      reply({
        type: "run.error",
        requestId: parsed.requestId,
        conversationId: parsed.conversationId,
        message: err instanceof Error ? err.message : "Failed to start run",
      });
    }
    return;
  }

  if (parsed.type === "chat.abort") {
    deps.runner.abortConversation(parsed.conversationId);
  }
}

export interface LocalBridgeServer {
  port: number;
  close: () => Promise<void>;
}

export async function startLocalBridgeServer(
  deps: RouterDeps,
): Promise<LocalBridgeServer> {
  const clients = new Set<WebSocket>();
  const wss = new WebSocketServer({ noServer: true });

  const broadcast = (event: ServerToClientMessage) => {
    const serialized = JSON.stringify(event);
    for (const client of clients) {
      if (client.readyState === client.OPEN) {
        client.send(serialized);
      }
    }
  };
  deps.runner.on("bridge-event", broadcast);

  const server = http.createServer(async (req, res) => {
    const reqUrl = new URL(req.url || "/", "http://bridge.local");

    if (reqUrl.pathname === "/healthz") {
      res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ ok: true, service: "agy-bridge" }));
      return;
    }

    if (!isAuthorized(req.headers.authorization, deps.config)) {
      res.writeHead(401, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ error: "Unauthorized" }));
      return;
    }

    try {
      const body =
        req.method === "GET" || req.method === "HEAD"
          ? undefined
          : await readHttpBody(req);
      const response = await handleApiRequest(
        {
          method: req.method || "GET",
          path: reqUrl.pathname,
          query: reqUrl.search,
          body,
        },
        deps,
      );
      res.writeHead(response.status, {
        "Content-Type": response.contentType,
        "Cache-Control": "no-store",
      });
      res.end(response.body);
    } catch (err) {
      res.writeHead(500, { "Content-Type": "application/json; charset=utf-8" });
      res.end(
        JSON.stringify({
          error: err instanceof Error ? err.message : "Internal error",
        }),
      );
    }
  });

  server.on("upgrade", (req, socket, head) => {
    const reqUrl = new URL(req.url || "/", "http://bridge.local");
    if (reqUrl.pathname !== "/v1/ws") {
      socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
      socket.destroy();
      return;
    }
    if (!isAuthorized(req.headers.authorization, deps.config)) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      clients.add(ws);
      ws.send(
        JSON.stringify({
          type: "bridge.status",
          online: true,
          connectedAt: new Date().toISOString(),
        } satisfies ServerToClientMessage),
      );

      ws.on("message", (data) => {
        const text = data.toString();
        if (text === "ping") {
          ws.send("pong");
          return;
        }
        dispatchClientWsMessage(text, deps, (replyEvent) => {
          if (ws.readyState === ws.OPEN) {
            ws.send(JSON.stringify(replyEvent));
          }
        });
      });

      ws.on("close", () => {
        clients.delete(ws);
      });
    });
  });

  await new Promise<void>((resolve) => {
    server.listen(deps.config.port, deps.config.bindHost, resolve);
  });

  const address = server.address();
  const actualPort =
    address && typeof address === "object" ? address.port : deps.config.port;

  return {
    port: actualPort,
    close: async () => {
      deps.runner.off("bridge-event", broadcast);
      for (const client of clients) {
        client.close();
      }
      await new Promise<void>((resolve, reject) => {
        wss.close(() => {
          server.close((err) => (err ? reject(err) : resolve()));
        });
      });
    },
  };
}
