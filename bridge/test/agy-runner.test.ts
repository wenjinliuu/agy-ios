import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { AgyRunner, parseAgyModelsOutput } from "../src/agy-runner.ts";
import type { ServerToClientMessage } from "../src/protocol.ts";

function createMockAgyScript(dir: string): string {
  const scriptPath = path.join(dir, "mock-agy.mjs");
  fs.writeFileSync(
    scriptPath,
    `#!/usr/bin/env node
const args = process.argv.slice(2);
if (args[0] === "--version") {
  console.log("agy 1.5.10-mock");
  process.exit(0);
}
if (args[0] === "models") {
  console.log("\\r⠋ Fetching available models...\\ngemini-3.8-flash-medium          Gemini 3.8 Flash (Medium)\\nclaude-opus-5-5-high            Claude Opus 5.5 (High)");
  process.exit(0);
}
const printFlag = args.find((a) => a.startsWith("--print=")) || "";
const promptText = printFlag.slice("--print=".length);
if (promptText === "HANG") {
  process.on("SIGTERM", () => process.exit(0));
  console.log(JSON.stringify({ event: "init", conversation_id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", init: { model: "gemini-3.8-flash-medium", cwd: process.cwd() } }));
  setInterval(() => {}, 1000);
} else {
  const cid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
  console.log(JSON.stringify({ event: "init", conversation_id: cid, init: { model: "gemini-3.8-flash-medium", cwd: process.cwd() } }));
  console.log(JSON.stringify({ event: "step_update", step_update: { conversation_id: cid, step_index: 1, state: "ACTIVE", step_type: "agent_response", text_delta: "Echo:" } }));
  console.log(JSON.stringify({ event: "step_update", step_update: { conversation_id: cid, step_index: 1, state: "DONE", step_type: "agent_response", text_delta: promptText } }));
  console.log(JSON.stringify({ event: "result", result: { conversation_id: cid, status: "SUCCESS", response: "Echo:" + promptText, duration_seconds: 0.2 } }));
}
`,
    { mode: 0o755 },
  );
  return scriptPath;
}

test("parseAgyModelsOutput strips spinner noise and parses both tab and space delimited model IDs", () => {
  const parsed = parseAgyModelsOutput(
    "\r\x1b[32m⠋ Fetching available models...\x1b[0m\r\n" +
      "gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n" +
      "claude-sonnet-5-5-high         Claude Sonnet 5.5 (High)\n",
  );
  assert.deepEqual(parsed, [
    { id: "gemini-3.8-flash-low", displayName: "Gemini 3.8 Flash (Low)" },
    { id: "claude-sonnet-5-5-high", displayName: "Claude Sonnet 5.5 (High)" },
  ]);
});

test("AgyRunner streams deltas, handles leading dashes in prompts, and supports abort", async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "agy-runner-test-"));
  const mockBin = createMockAgyScript(tmp);
  const runner = new AgyRunner({ agyBin: mockBin, defaultWorkspace: tmp });

  try {
    assert.equal(await runner.getVersion(), "agy 1.5.10-mock");
    const models = await runner.listModels();
    assert.equal(models.length, 2);

    const events: ServerToClientMessage[] = [];
    runner.on("bridge-event", (ev: ServerToClientMessage) => events.push(ev));

    const completed = new Promise<void>((resolve) => {
      const handler = (ev: ServerToClientMessage) => {
        if (ev.type === "run.completed") {
          runner.off("bridge-event", handler);
          resolve();
        }
      };
      runner.on("bridge-event", handler);
    });

    runner.startRun({ prompt: "-leading dash prompt", requestId: "req-1" });
    await completed;

    const deltas = events
      .filter((e): e is Extract<ServerToClientMessage, { type: "run.delta" }> => e.type === "run.delta")
      .map((e) => e.textDelta)
      .join("");
    assert.equal(deltas, "Echo:-leading dash prompt");

    // Abort flow
    const abortedDone = new Promise<void>((resolve) => {
      const handler = (ev: ServerToClientMessage) => {
        if (ev.type === "run.aborted") {
          runner.off("bridge-event", handler);
          resolve();
        }
      };
      runner.on("bridge-event", handler);
    });
    const initDone = new Promise<string>((resolve) => {
      const handler = (ev: ServerToClientMessage) => {
        if (ev.type === "run.init") {
          runner.off("bridge-event", handler);
          resolve(ev.conversationId);
        }
      };
      runner.on("bridge-event", handler);
    });

    runner.startRun({ prompt: "HANG", requestId: "req-hang" });
    const activeCid = await initDone;
    assert.equal(runner.abortConversation(activeCid), true);
    await abortedDone;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
});
