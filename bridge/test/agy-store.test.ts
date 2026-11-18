import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import {
  AgyStore,
  extractPbtxtTitle,
  extractUserPromptText,
  isValidConversationId,
  parsePrimaryWorkspace,
} from "../src/agy-store.ts";

function makeTempDataDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agy-store-test-"));
  fs.mkdirSync(path.join(dir, "annotations"), { recursive: true });
  return dir;
}

test("unescapes pbtxt octal UTF-8 and extracts clean user prompt", () => {
  const title = extractPbtxtTitle(
    'title:"\\345\\217\\215\\351\\207\\215\\345\\212\\233 iOS"  last_user_view_time:{seconds:1}',
  );
  assert.equal(title, "反重力 iOS");

  const prompt = extractUserPromptText(
    "<USER_REQUEST>\n帮我看下接口\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nignored\n</ADDITIONAL_METADATA>",
  );
  assert.equal(prompt, "帮我看下接口");

  assert.equal(
    parsePrimaryWorkspace('["file:///home/ubuntu/projects/demo"]'),
    "/home/ubuntu/projects/demo",
  );
  assert.equal(isValidConversationId("../etc/passwd"), false);
  assert.equal(isValidConversationId("c692fd56-1073-4159-ba3a-400bd8953213"), true);
});

test("AgyStore reads SQLite summaries, pbtxt titles, and hydrates truncated transcripts", () => {
  const dataDir = makeTempDataDir();
  const cid = "11111111-2222-3333-4444-555555555555";
  const dbPath = path.join(dataDir, "conversation_summaries.db");

  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE conversation_summaries (
      conversation_id TEXT PRIMARY KEY,
      title TEXT NOT NULL DEFAULT "",
      preview TEXT NOT NULL DEFAULT "",
      step_count INTEGER NOT NULL DEFAULT 0,
      last_modified_time DATETIME NOT NULL,
      workspace_uris TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT "",
      source TEXT NOT NULL DEFAULT "",
      last_user_input_time DATETIME NOT NULL,
      not_fully_idle NUMERIC NOT NULL DEFAULT false
    );
  `);
  db.prepare(
    `INSERT INTO conversation_summaries
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(
    cid,
    "Old DB Title",
    "Preview fallback",
    3,
    "2026-11-18 03:30:00+00:00",
    '["file:///tmp/demo-ws"]',
    "CASCADE_RUN_STATUS_IDLE",
    "cli",
    "2026-11-18 03:29:00+00:00",
    0,
  );
  db.close();

  fs.writeFileSync(
    path.join(dataDir, "annotations", `${cid}.pbtxt`),
    'title:"中文标题覆盖"  last_user_view_time:{seconds:100}',
  );

  const logsDir = path.join(dataDir, "brain", cid, ".system_generated", "logs");
  fs.mkdirSync(logsDir, { recursive: true });
  fs.writeFileSync(
    path.join(logsDir, "transcript.jsonl"),
    [
      JSON.stringify({
        step_index: 0,
        source: "USER_EXPLICIT",
        type: "USER_INPUT",
        status: "DONE",
        created_at: "2026-11-18T03:29:00Z",
        content: "<USER_REQUEST>\nHello Agy\n</USER_REQUEST>",
        truncated_fields: ["content"],
      }),
      JSON.stringify({
        step_index: 1,
        source: "SYSTEM",
        type: "SYSTEM_MESSAGE",
        status: "DONE",
        created_at: "2026-11-18T03:29:01Z",
        content: "Internal notice",
      }),
      JSON.stringify({
        step_index: 2,
        source: "MODEL",
        type: "PLANNER_RESPONSE",
        status: "DONE",
        created_at: "2026-11-18T03:29:05Z",
        thinking: "Checking files first",
        tool_calls: [{ name: "view_file", args: { Path: "/tmp/a.txt" } }],
        content: "Done reading.",
        model: "gemini-3.8-flash-medium",
        input_tokens: 100,
        output_tokens: 12,
      }),
    ].join("\n") + "\n",
  );
  fs.writeFileSync(
    path.join(logsDir, "transcript_full.jsonl"),
    JSON.stringify({
      step_index: 0,
      source: "USER_EXPLICIT",
      type: "USER_INPUT",
      status: "DONE",
      created_at: "2026-11-18T03:29:00Z",
      content: "<USER_REQUEST>\nFull untruncated prompt\n</USER_REQUEST>",
    }) + "\n",
  );

  try {
    const store = new AgyStore(dataDir);
    const list = store.listConversations({ activeIds: new Set([cid]) });
    assert.equal(list.length, 1);
    assert.equal(list[0].title, "中文标题覆盖");
    assert.equal(list[0].workspacePath, "/tmp/demo-ws");
    assert.equal(list[0].isRunning, true);

    const messages = store.getMessages(cid);
    assert.equal(messages.length, 2);
    assert.equal(messages[0].role, "user");
    assert.equal(messages[0].content, "Full untruncated prompt");
    assert.equal(messages[1].role, "assistant");
    assert.equal(messages[1].thinking, "Checking files first");
    assert.equal(messages[1].toolCalls[0].name, "view_file");
    assert.equal(messages[1].content, "Done reading.");

    const renamed = store.renameConversationTitle(cid, "手动改名后的标题");
    assert.equal(renamed?.title, "手动改名后的标题");

    const cfgDir = path.join(dataDir, "cfg");
    fs.mkdirSync(cfgDir, { recursive: true });
    fs.writeFileSync(
      path.join(cfgDir, "mcp_config.json"),
      JSON.stringify({
        mcpServers: {
          github: {
            serverUrl: "https://api.githubcopilot.com/mcp/",
            headers: { Authorization: "Bearer super-secret-do-not-expose" },
          },
        },
      }),
    );
    fs.writeFileSync(
      path.join(cfgDir, "hooks.json"),
      JSON.stringify({ "auto-zh-title": { Stop: [] } }),
    );
    const overview = store.readSafeConfigOverview(cfgDir);
    assert.equal(overview.mcpServers.length, 1);
    assert.equal(overview.mcpServers[0].name, "github");
    assert.equal(overview.hooks[0].name, "auto-zh-title");
    assert.equal(JSON.stringify(overview).includes("super-secret"), false);
  } finally {
    fs.rmSync(dataDir, { recursive: true, force: true });
  }
});
