import { DurableObject } from "cloudflare:workers";
import type { RelayWireMessage } from "./protocol.ts";

interface PendingRpc {
  resolve: (response: Response) => void;
  timer: ReturnType<typeof setTimeout>;
}

const RPC_TIMEOUT_MS = 25_000;
const WS_OPEN = 1;
const decoder = new TextDecoder();

export class BridgeRelayDO extends DurableObject {
  private pendingRpc = new Map<string, PendingRpc>();
  private vpsConnectedAt: string | null = null;

  constructor(ctx: DurableObjectState, env: Record<string, unknown>) {
    super(ctx, env);
    // Keepalive "ping" -> "pong" stays handled at edge without waking the DO.
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair("ping", "pong"),
    );
  }

  private getOpenVpsSocket(): WebSocket | null {
    for (const ws of this.ctx.getWebSockets("vps")) {
      if (ws.readyState === WS_OPEN) {
        return ws;
      }
    }
    return null;
  }

  private broadcastToClients(payload: unknown): void {
    const serialized = JSON.stringify(payload);
    for (const client of this.ctx.getWebSockets("client")) {
      if (client.readyState !== WS_OPEN) {
        continue;
      }
      try {
        client.send(serialized);
      } catch {
        // Closed socket cleanup happens in webSocketClose/webSocketError.
      }
    }
  }

  private rejectAllPending(reason: string): void {
    for (const [reqId, entry] of this.pendingRpc.entries()) {
      clearTimeout(entry.timer);
      entry.resolve(
        Response.json(
          { error: reason, code: "VPS_OFFLINE" },
          { status: 503 },
        ),
      );
      this.pendingRpc.delete(reqId);
    }
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const upgrade = request.headers.get("Upgrade")?.toLowerCase();

    if (url.pathname === "/v1/relay/vps" && upgrade === "websocket") {
      for (const existing of this.ctx.getWebSockets("vps")) {
        try {
          existing.close(1000, "Replaced by newer VPS bridge connection");
        } catch {
          // Ignore already closing socket.
        }
      }

      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.ctx.acceptWebSocket(server, ["vps"]);
      this.vpsConnectedAt = new Date().toISOString();
      this.broadcastToClients({
        type: "bridge.status",
        online: true,
        connectedAt: this.vpsConnectedAt,
      });

      return new Response(null, { status: 101, webSocket: client });
    }

    if (url.pathname === "/v1/ws" && upgrade === "websocket") {
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.ctx.acceptWebSocket(server, ["client"]);

      const online = this.getOpenVpsSocket() !== null;
      server.send(
        JSON.stringify({
          type: "bridge.status",
          online,
          connectedAt: this.vpsConnectedAt ?? undefined,
        }),
      );

      return new Response(null, { status: 101, webSocket: client });
    }

    // Worker-local diagnostic summary of bridge connection status
    if (url.pathname === "/v1/relay/status" && request.method === "GET") {
      return Response.json({
        workerOk: true,
        bridgeOnline: this.getOpenVpsSocket() !== null,
        clientConnections: this.ctx.getWebSockets("client").length,
        connectedAt: this.vpsConnectedAt,
      });
    }

    const vpsSocket = this.getOpenVpsSocket();
    if (!vpsSocket) {
      return Response.json(
        { error: "VPS bridge is offline", code: "VPS_OFFLINE" },
        { status: 503 },
      );
    }

    const bodyText =
      request.method === "GET" || request.method === "HEAD"
        ? undefined
        : await request.text();

    const reqId = crypto.randomUUID();
    const rpcMessage: RelayWireMessage = {
      kind: "rpc_request",
      reqId,
      method: request.method,
      path: url.pathname,
      query: url.search,
      body: bodyText,
    };

    return new Promise<Response>((resolve) => {
      const timer = setTimeout(() => {
        this.pendingRpc.delete(reqId);
        resolve(
          Response.json(
            { error: "Timed out waiting for VPS bridge", code: "VPS_TIMEOUT" },
            { status: 504 },
          ),
        );
      }, RPC_TIMEOUT_MS);

      this.pendingRpc.set(reqId, { resolve, timer });

      try {
        vpsSocket.send(JSON.stringify(rpcMessage));
      } catch {
        clearTimeout(timer);
        this.pendingRpc.delete(reqId);
        resolve(
          Response.json(
            { error: "Failed to forward request to VPS bridge", code: "VPS_SEND_ERROR" },
            { status: 502 },
          ),
        );
      }
    });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const text = typeof message === "string" ? message : decoder.decode(message);
    if (!text || text === "ping" || text === "pong") {
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      return;
    }

    const isVps = this.ctx.getTags(ws).includes("vps");

    if (isVps) {
      const msg = parsed as Partial<RelayWireMessage>;
      if (msg.kind === "rpc_response" && typeof msg.reqId === "string") {
        const pending = this.pendingRpc.get(msg.reqId);
        if (!pending) {
          return;
        }
        clearTimeout(pending.timer);
        this.pendingRpc.delete(msg.reqId);
        pending.resolve(
          new Response(typeof msg.body === "string" ? msg.body : "", {
            status: typeof msg.status === "number" ? msg.status : 500,
            headers: {
              "Content-Type": msg.contentType || "application/json; charset=utf-8",
              "Cache-Control": "no-store",
            },
          }),
        );
        return;
      }

      if (msg.kind === "server_ws" && msg.payload !== undefined) {
        this.broadcastToClients(msg.payload);
        return;
      }

      if (msg.kind === "vps_hello") {
        this.vpsConnectedAt = new Date().toISOString();
        this.broadcastToClients({
          type: "bridge.status",
          online: true,
          connectedAt: this.vpsConnectedAt,
        });
      }
      return;
    }

    // Message came from an authenticated iOS/API WebSocket client
    const vpsSocket = this.getOpenVpsSocket();
    if (!vpsSocket) {
      ws.send(JSON.stringify({ type: "bridge.status", online: false }));
      ws.send(
        JSON.stringify({
          type: "run.error",
          message: "VPS bridge is offline",
        }),
      );
      return;
    }

    try {
      const envelope: RelayWireMessage = {
        kind: "client_ws",
        payload: parsed,
      };
      vpsSocket.send(JSON.stringify(envelope));
    } catch {
      ws.send(JSON.stringify({ type: "bridge.status", online: false }));
    }
  }

  async webSocketClose(ws: WebSocket): Promise<void> {
    if (this.ctx.getTags(ws).includes("vps") && !this.getOpenVpsSocket()) {
      this.vpsConnectedAt = null;
      this.rejectAllPending("VPS bridge disconnected");
      this.broadcastToClients({ type: "bridge.status", online: false });
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    await this.webSocketClose(ws);
  }
}
