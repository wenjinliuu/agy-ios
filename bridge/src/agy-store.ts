import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import type {
  ChatMessage,
  ConversationSummary,
  HookSummary,
  McpServerSummary,
  ToolCallSummary,
} from "./protocol.ts";

interface SummaryRow {
  conversation_id: string;
  title: string;
  preview: string;
  step_count: number;
  last_modified_time: string;
  workspace_uris: string;
  status: string;
  source: string;
  last_user_input_time: string;
  not_fully_idle: number | boolean;
}

interface TranscriptEntry {
  step_index?: number;
  source?: string;
  type?: string;
  status?: string;
  created_at?: string;
  content?: string;
  thinking?: string;
  error?: unknown;
  model?: string;
  input_tokens?: number;
  output_tokens?: number;
  cache_read_tokens?: number;
  tool_calls?: Array<{ name?: string; args?: unknown }>;
  truncated_fields?: string[];
}

const VALID_CID_RE = /^[a-zA-Z0-9_-]{8,128}$/;

export function isValidConversationId(id: string): boolean {
  return VALID_CID_RE.test(id);
}

/**
 * Unescapes protobuf text-format string literals including octal UTF-8 byte
 * sequences (\345\217\215) produced by some CLI builds.
 */
export function unescapePbtxtString(raw: string): string {
  const bytes: number[] = [];
  for (let i = 0; i < raw.length; i += 1) {
    const ch = raw[i];
    if (ch !== "\\" || i + 1 >= raw.length) {
      for (const b of Buffer.from(ch, "utf8")) {
        bytes.push(b);
      }
      continue;
    }

    const next = raw[i + 1];
    if (/[0-7]/.test(next)) {
      const oct = raw.slice(i + 1, i + 4).match(/^[0-7]{1,3}/)?.[0] || next;
      bytes.push(Number.parseInt(oct, 8) & 0xff);
      i += oct.length;
      continue;
    }

    const singleMap: Record<string, string> = {
      n: "\n",
      r: "\r",
      t: "\t",
      '"': '"',
      "'": "'",
      "\\": "\\",
    };
    const mapped = singleMap[next] ?? next;
    for (const b of Buffer.from(mapped, "utf8")) {
      bytes.push(b);
    }
    i += 1;
  }
  return Buffer.from(bytes).toString("utf8");
}

export function extractPbtxtTitle(pbtxtContent: string): string {
  const match = pbtxtContent.match(/title:\s*"((?:[^"\\]|\\.)*)"/);
  if (!match) {
    return "";
  }
  return unescapePbtxtString(match[1]).trim();
}

export function parsePrimaryWorkspace(workspaceUrisRaw: string): string {
  if (!workspaceUrisRaw) {
    return "";
  }
  try {
    const parsed = JSON.parse(workspaceUrisRaw);
    if (Array.isArray(parsed) && typeof parsed[0] === "string") {
      return parsed[0].replace(/^file:\/\//, "");
    }
  } catch {
    // Fallback for plain URI strings.
  }
  return workspaceUrisRaw.replace(/^file:\/\//, "");
}

export function extractUserPromptText(rawContent: string): string {
  if (!rawContent) {
    return "";
  }
  const match = rawContent.match(/<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/);
  if (match) {
    return match[1].trim();
  }
  // Remove trailing system-injected blocks if USER_REQUEST tags are absent.
  return rawContent
    .replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/g, "")
    .replace(/<USER_SETTINGS_CHANGE>[\s\S]*?<\/USER_SETTINGS_CHANGE>/g, "")
    .replace(/<CONTEXT_SUMMARY>[\s\S]*?<\/CONTEXT_SUMMARY>/g, "[上下文已自动压缩]")
    .trim();
}

function summarizeToolCalls(
  toolCalls: Array<{ name?: string; args?: unknown }> | undefined,
): ToolCallSummary[] {
  if (!Array.isArray(toolCalls)) {
    return [];
  }
  return toolCalls.map((call) => {
    const name = call.name || "unknown_tool";
    let argsPreview = "";
    if (call.args && typeof call.args === "object") {
      const serialized = JSON.stringify(call.args);
      argsPreview =
        serialized.length > 200 ? `${serialized.slice(0, 197)}...` : serialized;
    }
    return { name, argsPreview };
  });
}

function formatErrorValue(errorVal: unknown): string | undefined {
  if (!errorVal) {
    return undefined;
  }
  if (typeof errorVal === "string") {
    return errorVal;
  }
  try {
    return JSON.stringify(errorVal);
  } catch {
    return String(errorVal);
  }
}

export class AgyStore {
  private readonly dataDir: string;

  constructor(dataDir: string) {
    this.dataDir = dataDir;
  }

  private get dbPath(): string {
    return path.join(this.dataDir, "conversation_summaries.db");
  }

  private readAnnotationTitle(conversationId: string): string {
    const pbtxtPath = path.join(this.dataDir, "annotations", `${conversationId}.pbtxt`);
    if (!fs.existsSync(pbtxtPath)) {
      return "";
    }
    try {
      return extractPbtxtTitle(fs.readFileSync(pbtxtPath, "utf8"));
    } catch {
      return "";
    }
  }

  private readFirstUserPreview(conversationId: string): string {
    const logPath = path.join(
      this.dataDir,
      "brain",
      conversationId,
      ".system_generated",
      "logs",
      "transcript.jsonl",
    );
    if (!fs.existsSync(logPath)) {
      return "";
    }
    try {
      const content = fs.readFileSync(logPath, "utf8");
      for (const line of content.split("\n")) {
        if (!line.trim()) {
          continue;
        }
        const entry = JSON.parse(line) as TranscriptEntry;
        if (entry.type === "USER_INPUT" && typeof entry.content === "string") {
          const clean = extractUserPromptText(entry.content).replace(/\s+/g, " ");
          return clean.length > 60 ? `${clean.slice(0, 57)}...` : clean;
        }
      }
    } catch {
      // Best-effort fallback only.
    }
    return "";
  }

  private openReadOnlyDb(): DatabaseSync | null {
    if (!fs.existsSync(this.dbPath)) {
      return null;
    }
    return new DatabaseSync(this.dbPath, { readOnly: true });
  }

  listConversations(options: {
    limit?: number;
    query?: string;
    activeIds?: ReadonlySet<string>;
  } = {}): ConversationSummary[] {
    const db = this.openReadOnlyDb();
    if (!db) {
      return [];
    }

    const limit = Math.max(1, Math.min(options.limit ?? 50, 200));
    const search = (options.query || "").trim().toLowerCase();

    try {
      const rows = db
        .prepare(
          `SELECT conversation_id, title, preview, step_count, last_modified_time,
                  workspace_uris, status, source, last_user_input_time, not_fully_idle
           FROM conversation_summaries
           ORDER BY COALESCE(NULLIF(last_modified_time, ''), last_user_input_time) DESC
           LIMIT ?`,
        )
        .all(search ? 200 : limit) as unknown as SummaryRow[];

      const summaries: ConversationSummary[] = [];
      for (const row of rows) {
        const annotationTitle = this.readAnnotationTitle(row.conversation_id);
        const workspacePath = parsePrimaryWorkspace(row.workspace_uris);
        const fallbackPreview =
          row.preview.trim() || this.readFirstUserPreview(row.conversation_id);
        const title =
          annotationTitle ||
          row.title.trim() ||
          fallbackPreview ||
          "未命名对话";

        const item: ConversationSummary = {
          id: row.conversation_id,
          title,
          preview: fallbackPreview,
          stepCount: Number(row.step_count) || 0,
          status: row.status || "",
          source: row.source || "",
          workspacePath,
          lastModifiedAt: row.last_modified_time || "",
          lastUserInputAt: row.last_user_input_time || "",
          isRunning:
            Boolean(options.activeIds?.has(row.conversation_id)) ||
            Boolean(row.not_fully_idle),
        };

        if (search) {
          const hay = `${item.title}\n${item.preview}\n${item.workspacePath}\n${item.id}`.toLowerCase();
          if (!hay.includes(search)) {
            continue;
          }
        }
        summaries.push(item);
        if (summaries.length >= limit) {
          break;
        }
      }
      return summaries;
    } finally {
      db.close();
    }
  }

  getConversationSummary(
    conversationId: string,
    activeIds?: ReadonlySet<string>,
  ): ConversationSummary | null {
    if (!isValidConversationId(conversationId)) {
      return null;
    }
    const db = this.openReadOnlyDb();
    if (!db) {
      return null;
    }
    try {
      const row = db
        .prepare(
          `SELECT conversation_id, title, preview, step_count, last_modified_time,
                  workspace_uris, status, source, last_user_input_time, not_fully_idle
           FROM conversation_summaries
           WHERE conversation_id = ?`,
        )
        .get(conversationId) as unknown as SummaryRow | undefined;
      if (!row) {
        return null;
      }
      const annotationTitle = this.readAnnotationTitle(row.conversation_id);
      const fallbackPreview =
        row.preview.trim() || this.readFirstUserPreview(row.conversation_id);
      return {
        id: row.conversation_id,
        title: annotationTitle || row.title.trim() || fallbackPreview || "未命名对话",
        preview: fallbackPreview,
        stepCount: Number(row.step_count) || 0,
        status: row.status || "",
        source: row.source || "",
        workspacePath: parsePrimaryWorkspace(row.workspace_uris),
        lastModifiedAt: row.last_modified_time || "",
        lastUserInputAt: row.last_user_input_time || "",
        isRunning:
          Boolean(activeIds?.has(row.conversation_id)) ||
          Boolean(row.not_fully_idle),
      };
    } finally {
      db.close();
    }
  }

  getMessages(
    conversationId: string,
    options: { limit?: number; includeSystem?: boolean } = {},
  ): ChatMessage[] {
    if (!isValidConversationId(conversationId)) {
      return [];
    }
    const logsDir = path.join(
      this.dataDir,
      "brain",
      conversationId,
      ".system_generated",
      "logs",
    );
    const compactPath = path.join(logsDir, "transcript.jsonl");
    const fullPath = path.join(logsDir, "transcript_full.jsonl");

    if (!fs.existsSync(compactPath)) {
      return [];
    }

    const compactEntries = this.readJsonl(compactPath);
    const needsFullHydration = compactEntries.some(
      (e) => Array.isArray(e.truncated_fields) && e.truncated_fields.length > 0,
    );

    const fullByStep = new Map<number, TranscriptEntry>();
    if (needsFullHydration && fs.existsSync(fullPath)) {
      for (const fullEntry of this.readJsonl(fullPath)) {
        if (typeof fullEntry.step_index === "number") {
          fullByStep.set(fullEntry.step_index, fullEntry);
        }
      }
    }

    const includeSystem = Boolean(options.includeSystem);
    const messages: ChatMessage[] = [];

    for (const raw of compactEntries) {
      const stepIndex = typeof raw.step_index === "number" ? raw.step_index : messages.length;
      const hydrated = fullByStep.get(stepIndex) ?? raw;

      if (hydrated.type === "SYSTEM_MESSAGE" && !includeSystem) {
        continue;
      }

      if (hydrated.type === "USER_INPUT") {
        const cleanText = extractUserPromptText(hydrated.content || "");
        if (!cleanText) {
          continue;
        }
        messages.push({
          id: `${conversationId}:${stepIndex}`,
          stepIndex,
          role: "user",
          content: cleanText,
          toolCalls: [],
          status: hydrated.status || "DONE",
          createdAt: hydrated.created_at || "",
        });
        continue;
      }

      if (hydrated.source === "MODEL") {
        const toolCalls = summarizeToolCalls(hydrated.tool_calls);
        const thinking =
          typeof hydrated.thinking === "string" && hydrated.thinking.trim()
            ? hydrated.thinking.trim()
            : undefined;
        const content = (hydrated.content || "").trim();
        const error = formatErrorValue(hydrated.error);

        // Skip empty intermediate rows with no user-visible data
        if (!content && !thinking && toolCalls.length === 0 && !error) {
          continue;
        }

        messages.push({
          id: `${conversationId}:${stepIndex}`,
          stepIndex,
          role: "assistant",
          content,
          thinking,
          toolCalls,
          model: hydrated.model,
          status: hydrated.status || "DONE",
          createdAt: hydrated.created_at || "",
          error,
          usage:
            hydrated.input_tokens !== undefined || hydrated.output_tokens !== undefined
              ? {
                  inputTokens: hydrated.input_tokens,
                  outputTokens: hydrated.output_tokens,
                  cacheReadTokens: hydrated.cache_read_tokens,
                }
              : undefined,
        });
        continue;
      }

      if (includeSystem && hydrated.content) {
        messages.push({
          id: `${conversationId}:${stepIndex}`,
          stepIndex,
          role: "system",
          content: hydrated.content,
          toolCalls: [],
          status: hydrated.status || "DONE",
          createdAt: hydrated.created_at || "",
        });
      }
    }

    const limit = Math.max(1, Math.min(options.limit ?? 200, 1000));
    return messages.length > limit ? messages.slice(-limit) : messages;
  }

  listKnownWorkspaces(defaultWorkspace: string): string[] {
    const db = this.openReadOnlyDb();
    const result = new Set<string>();
    if (defaultWorkspace && fs.existsSync(defaultWorkspace)) {
      result.add(defaultWorkspace);
    }
    if (db) {
      try {
        const rows = db
          .prepare(
            `SELECT DISTINCT workspace_uris FROM conversation_summaries
             WHERE workspace_uris != ''
             ORDER BY last_modified_time DESC
             LIMIT 30`,
          )
          .all() as unknown as Array<{ workspace_uris: string }>;
        for (const row of rows) {
          const parsed = parsePrimaryWorkspace(row.workspace_uris);
          if (parsed && fs.existsSync(parsed)) {
            result.add(parsed);
          }
        }
      } finally {
        db.close();
      }
    }
    return [...result];
  }

  renameConversationTitle(
    conversationId: string,
    rawTitle: string,
  ): ConversationSummary | null {
    if (!isValidConversationId(conversationId)) {
      return null;
    }
    const cleanTitle = rawTitle.replace(/[\r\n]+/g, " ").trim();
    if (!cleanTitle) {
      throw new Error("Title cannot be empty");
    }

    const escaped = cleanTitle
      .replace(/\\/g, "\\\\")
      .replace(/"/g, '\\"');
    const annotationsDir = path.join(this.dataDir, "annotations");
    fs.mkdirSync(annotationsDir, { recursive: true });
    const pbtxtPath = path.join(annotationsDir, `${conversationId}.pbtxt`);

    if (fs.existsSync(pbtxtPath)) {
      const existing = fs.readFileSync(pbtxtPath, "utf8");
      if (/title:\s*"(?:[^"\\]|\\.)*"/.test(existing)) {
        fs.writeFileSync(
          pbtxtPath,
          existing.replace(/title:\s*"(?:[^"\\]|\\.)*"/, `title:"${escaped}"`),
        );
      } else {
        fs.writeFileSync(pbtxtPath, `title:"${escaped}"  ${existing}`);
      }
    } else {
      const nowSec = Math.floor(Date.now() / 1000);
      fs.writeFileSync(
        pbtxtPath,
        `title:"${escaped}"  last_user_view_time:{seconds:${nowSec}  nanos:0}\n`,
      );
    }

    if (fs.existsSync(this.dbPath)) {
      const rwDb = new DatabaseSync(this.dbPath);
      try {
        rwDb
          .prepare(
            "UPDATE conversation_summaries SET title = ? WHERE conversation_id = ?",
          )
          .run(cleanTitle, conversationId);
      } finally {
        rwDb.close();
      }
    }

    return this.getConversationSummary(conversationId);
  }

  readSafeConfigOverview(configDir = path.join(os.homedir(), ".gemini", "config")): {
    mcpServers: McpServerSummary[];
    hooks: HookSummary[];
    skills: string[];
  } {
    const mcpServers: McpServerSummary[] = [];
    const mcpPath = path.join(configDir, "mcp_config.json");
    if (fs.existsSync(mcpPath)) {
      try {
        const parsed = JSON.parse(fs.readFileSync(mcpPath, "utf8")) as {
          mcpServers?: Record<
            string,
            {
              disabled?: boolean;
              serverUrl?: string;
              url?: string;
              command?: string;
              type?: string;
            }
          >;
        };
        for (const [name, entry] of Object.entries(parsed.mcpServers || {})) {
          const rawUrl = entry.serverUrl || entry.url;
          let target = "";
          if (rawUrl) {
            try {
              const u = new URL(rawUrl);
              target = `${u.origin}${u.pathname}`;
            } catch {
              target = "http-endpoint";
            }
          } else if (entry.command) {
            target = path.basename(entry.command);
          }
          mcpServers.push({
            name,
            transport: rawUrl ? "http" : entry.type || "stdio",
            enabled: entry.disabled !== true,
            target,
          });
        }
      } catch {
        // Ignore malformed config rather than failing the endpoint.
      }
    }

    const hooks: HookSummary[] = [];
    const hooksPath = path.join(configDir, "hooks.json");
    if (fs.existsSync(hooksPath)) {
      try {
        const parsed = JSON.parse(fs.readFileSync(hooksPath, "utf8")) as Record<
          string,
          unknown
        >;
        for (const [name, value] of Object.entries(parsed)) {
          if (value && typeof value === "object") {
            hooks.push({
              name,
              event: Object.keys(value as Record<string, unknown>).join(", "),
              enabled: true,
            });
          }
        }
      } catch {
        // Ignore malformed hooks.json.
      }
    }

    const skillNames = new Set<string>();
    for (const dir of [
      path.join(this.dataDir, "builtin", "skills"),
      path.join(path.dirname(this.dataDir), "skills"),
    ]) {
      if (!fs.existsSync(dir)) {
        continue;
      }
      try {
        for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
          if (item.isDirectory()) {
            skillNames.add(item.name);
          }
        }
      } catch {
        // Ignore unreadable skills directories.
      }
    }

    return {
      mcpServers: mcpServers.sort((a, b) => a.name.localeCompare(b.name)),
      hooks: hooks.sort((a, b) => a.name.localeCompare(b.name)),
      skills: [...skillNames].sort(),
    };
  }

  private readJsonl(filePath: string): TranscriptEntry[] {
    try {
      const content = fs.readFileSync(filePath, "utf8");
      const entries: TranscriptEntry[] = [];
      for (const line of content.split("\n")) {
        if (!line.trim()) {
          continue;
        }
        try {
          entries.push(JSON.parse(line) as TranscriptEntry);
        } catch {
          // Tolerate a partially flushed final line while agy is actively writing.
        }
      }
      return entries;
    } catch {
      return [];
    }
  }
}
