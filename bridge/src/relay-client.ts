import WebSocket from "ws";
import type { RelayWireMessage, ServerToClientMessage } from "./protocol.ts";
import { handleApiRequest, type RouterDeps } from "./router.ts";
import { dispatchClientWsMessage } from "./server.ts";

export interface RelayClientHandle {
  close: () => void;
  isConnected: () => boolean;
}

export function startRelayClient(deps: RouterDeps): RelayClientHandle {
  let stopped = false;
  let socket: WebSocket | null = null;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let pingTimer: ReturnType<typeof setInterval> | null = null;
  let backoffMs = 1000;
  let lastActivityAt = Date.now();

  const sendWire = (message: RelayWireMessage) => {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(message));
    }
  };

  const onBridgeEvent = (payload: ServerToClientMessage) => {
    sendWire({ kind: "server_ws", payload });
  };
  deps.runner.on("bridge-event", onBridgeEvent);

  const scheduleReconnect = () => {
    if (stopped || reconnectTimer) {
      return;
    }
    const delay = backoffMs;
    backoffMs = Math.min(backoffMs * 2, 30_000);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, delay);
  };

  const connect = () => {
    if (stopped) {
      return;
    }
    const headers: Record<string, string> = {};
    if (deps.config.relayAuthToken) {
      headers.Authorization = `Bearer ${deps.config.relayAuthToken}`;
    }

    const ws = new WebSocket(deps.config.relayWsUrl, { headers });
    socket = ws;

    ws.on("open", () => {
      backoffMs = 1000;
      lastActivityAt = Date.now();
      console.log("[agy-bridge] relay connected");
      sendWire({
        kind: "vps_hello",
        bridgeVersion: "0.1.0",
        hostname: deps.config.hostname,
      });

      if (pingTimer) {
        clearInterval(pingTimer);
      }
      pingTimer = setInterval(() => {
        if (ws.readyState !== WebSocket.OPEN) {
          return;
        }
        if (Date.now() - lastActivityAt > 50_000) {
          console.warn("[agy-bridge] relay pong watchdog expired; terminating socket to reconnect");
          ws.terminate();
          return;
        }
        ws.send("ping");
      }, 20_000);
    });

    ws.on("message", async (data) => {
      lastActivityAt = Date.now();
      const text = data.toString();
      if (!text || text === "pong" || text === "ping") {
        return;
      }

      let msg: RelayWireMessage;
      try {
        msg = JSON.parse(text) as RelayWireMessage;
      } catch {
        return;
      }

      if (msg.kind === "rpc_request") {
        try {
          const response = await handleApiRequest(
            {
              method: msg.method,
              path: msg.path,
              query: msg.query,
              body: msg.body,
            },
            deps,
          );
          sendWire({
            kind: "rpc_response",
            reqId: msg.reqId,
            status: response.status,
            contentType: response.contentType,
            body: response.body,
          });
        } catch (err) {
          sendWire({
            kind: "rpc_response",
            reqId: msg.reqId,
            status: 500,
            contentType: "application/json; charset=utf-8",
            body: JSON.stringify({
              error: err instanceof Error ? err.message : "Internal RPC failure",
            }),
          });
        }
        return;
      }

      if (msg.kind === "client_ws") {
        dispatchClientWsMessage(
          JSON.stringify(msg.payload),
          deps,
          (replyEvent) => sendWire({ kind: "server_ws", payload: replyEvent }),
        );
      }
    });

    ws.on("close", (code, reason) => {
      console.warn(`[agy-bridge] relay closed (code=${code}, reason=${reason.toString() || "none"})`);
      if (pingTimer) {
        clearInterval(pingTimer);
        pingTimer = null;
      }
      if (socket === ws) {
        socket = null;
      }
      scheduleReconnect();
    });

    ws.on("error", (err) => {
      console.error("[agy-bridge] relay socket error:", err.message);
    });
  };

  connect();

  return {
    isConnected: () => Boolean(socket && socket.readyState === WebSocket.OPEN),
    close: () => {
      stopped = true;
      deps.runner.off("bridge-event", onBridgeEvent);
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
      if (pingTimer) {
        clearInterval(pingTimer);
        pingTimer = null;
      }
      if (socket) {
        socket.close();
        socket = null;
      }
    },
  };
}
