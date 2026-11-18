import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import WebSocket, { WebSocketServer } from "ws";
import { AgyRunner } from "../src/agy-runner.ts";
import { AgyStore } from "../src/agy-store.ts";
import { loadConfig } from "../src/config.ts";
import type { RelayWireMessage, ServerToClientMessage } from "../src/protocol.ts";
import { startRelayClient } from "../src/relay-client.ts";
import { startLocalBridgeServer } from "../src/server.ts";

function createFastMockAgy(dir: string): string {
  const scriptPath = path.join(dir, "mock-agy.mjs");
  fs.writeFileSync(
    scriptPath,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === "--version") { console.log("agy 1.5.10-e2e"); process.exit(0); }
const printFlag = args.find((a) => a.startsWith("--print=")) || "";
const promptText = printFlag.slice("--print=".length);
const cid = "bbbbbbbb-2222-3333-4444-555555555555";
console.log(JSON.stringify({ event: "init", conversation_id: cid, init: { model: "gemini-3.8-flash-medium", cwd: process.cwd() } }));
console.log(JSON.stringify({ event: "step_update", step_update: { conversation_id: cid, step_index: 1, state: "DONE", step_type: "agent_response", text_delta: "OK:" + promptText } }));
console.log(JSON.stringify({ event: "result", result: { conversation_id: cid, status: "SUCCESS", response: "OK:" + promptText } }));
`,
    { mode: 0o755 },
  );
  return scriptPath;
}

test("local HTTP/WS server and outbound relay client handle auth, RPC, and streaming", async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "agy-e2e-test-"));
  const mockBin = createFastMockAgy(tmp);
  const config = {
    ...loadConfig({
      BRIDGE_BIND_HOST: "127.0.0.1",
      BRIDGE_PORT: "0",
      BRIDGE_AUTH_TOKEN: "top-secret-token",
      AGY_BIN: mockBin,
      AGY_DATA_DIR: tmp,
      AGY_DEFAULT_WORKSPACE: tmp,
    }),
  };

  const store = new AgyStore(config.agyDataDir);
  const runner = new AgyRunner({
    agyBin: config.agyBin,
    defaultWorkspace: config.defaultWorkspace,
  });

  const localServer = await startLocalBridgeServer({ config, store, runner });

  // Mock Cloudflare Worker Durable Object relay
  const relayHttp = http.createServer();
  const relayWss = new WebSocketServer({ server: relayHttp });
  await new Promise<void>((resolve) => relayHttp.listen(0, "127.0.0.1", resolve));
  const relayAddr = relayHttp.address();
  const relayPort = typeof relayAddr === "object" && relayAddr ? relayAddr.port : 0;

  let vpsSocket: WebSocket | null = null;
  const receivedFromVps: RelayWireMessage[] = [];
  const helloDone = new Promise<void>((resolve) => {
    relayWss.on("connection", (ws, req) => {
      assert.equal(req.headers.authorization, "Bearer top-secret-token");
      vpsSocket = ws;
      ws.on("message", (buf) => {
        const msg = JSON.parse(buf.toString()) as RelayWireMessage;
        receivedFromVps.push(msg);
        if (msg.kind === "vps_hello") {
          resolve();
        }
      });
    });
  });

  config.relayWsUrl = `ws://127.0.0.1:${relayPort}/v1/relay/vps`;
  config.relayAuthToken = "top-secret-token";
  const relayClient = startRelayClient({ config, store, runner });

  try {
    // 1. Local HTTP auth check
    const unauth = await fetch(`http://127.0.0.1:${localServer.port}/v1/health`);
    assert.equal(unauth.status, 401);

    const healthRes = await fetch(
      `http://127.0.0.1:${localServer.port}/v1/health`,
      { headers: { Authorization: "Bearer top-secret-token" } },
    );
    assert.equal(healthRes.status, 200);
    const healthJson = (await healthRes.json()) as { ok: boolean; agyVersion: string };
    assert.equal(healthJson.ok, true);
    assert.equal(healthJson.agyVersion, "agy 1.5.10-e2e");

    // 2. Local WebSocket streaming test
    const clientWs = new WebSocket(`ws://127.0.0.1:${localServer.port}/v1/ws`, {
      headers: { Authorization: "Bearer top-secret-token" },
    });
    const completedEvent = await new Promise<ServerToClientMessage>((resolve, reject) => {
      clientWs.on("open", () => {
        clientWs.send(JSON.stringify({ type: "chat.send", prompt: "ping-test" }));
      });
      clientWs.on("message", (buf) => {
        const ev = JSON.parse(buf.toString()) as ServerToClientMessage;
        if (ev.type === "run.completed") {
          resolve(ev);
        }
      });
      clientWs.on("error", reject);
    });
    assert.equal(completedEvent.type, "run.completed");
    if (completedEvent.type === "run.completed") {
      assert.equal(completedEvent.response, "OK:ping-test");
    }
    clientWs.close();

    // 3. Relay RPC forwarding test
    await helloDone;
    assert.ok(vpsSocket);
    const rpcReply = await new Promise<RelayWireMessage>((resolve) => {
      const handler = (buf: WebSocket.RawData) => {
        const msg = JSON.parse(buf.toString()) as RelayWireMessage;
        if (msg.kind === "rpc_response" && msg.reqId === "rpc-1") {
          vpsSocket?.off("message", handler);
          resolve(msg);
        }
      };
      vpsSocket?.on("message", handler);
      vpsSocket?.send(
        JSON.stringify({
          kind: "rpc_request",
          reqId: "rpc-1",
          method: "GET",
          path: "/v1/health",
          query: "",
        } satisfies RelayWireMessage),
      );
    });
    assert.equal(rpcReply.kind, "rpc_response");
    if (rpcReply.kind === "rpc_response") {
      assert.equal(rpcReply.status, 200);
      assert.match(rpcReply.body, /agy 1\.5\.10-e2e/);
    }
  } finally {
    relayClient.close();
    await new Promise<void>((resolve) => relayWss.close(() => relayHttp.close(() => resolve())));
    await localServer.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
