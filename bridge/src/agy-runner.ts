import { execFile, spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import readline from "node:readline";
import type {
  ModelInfo,
  SendPromptPayload,
  ServerToClientMessage,
  UsageStats,
} from "./protocol.ts";

interface ActiveRun {
  runId: string;
  conversationId?: string;
  child: ChildProcess;
  aborted: boolean;
}

interface RawStreamLine {
  event?: string;
  conversation_id?: string;
  init?: { model?: string; cwd?: string };
  step_update?: {
    conversation_id?: string;
    step_index?: number;
    state?: string;
    step_type?: string;
    text_delta?: string;
    thinking_delta?: string;
    error?: unknown;
    usage?: {
      input_tokens?: number;
      output_tokens?: number;
      thinking_tokens?: number;
      cache_read_tokens?: number;
      total_tokens?: number;
    };
  };
  result?: {
    conversation_id?: string;
    status?: string;
    response?: string;
    duration_seconds?: number;
    error?: unknown;
    usage?: {
      input_tokens?: number;
      output_tokens?: number;
      thinking_tokens?: number;
      cache_read_tokens?: number;
      total_tokens?: number;
    };
  };
}

export type SpawnFn = typeof spawn;

const ANSI_ESCAPE_RE = /\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07]*\x07/g;

export function parseAgyModelsOutput(rawOutput: string): ModelInfo[] {
  const cleaned = rawOutput
    .replace(ANSI_ESCAPE_RE, "")
    .replace(/\r/g, "\n");
  const models: ModelInfo[] = [];
  const seen = new Set<string>();

  for (const rawLine of cleaned.split("\n")) {
    const line = rawLine.trim();
    if (!line || line.includes("Fetching available models")) {
      continue;
    }
    const match = line.match(/^([a-z0-9][a-z0-9._-]+)(?:\t|\s{2,})(.+)$/);
    if (!match) {
      continue;
    }
    const [, id, displayName] = match;
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);
    models.push({ id, displayName: displayName.trim() });
  }
  return models;
}

function mapUsage(raw: {
  input_tokens?: number;
  output_tokens?: number;
  thinking_tokens?: number;
  cache_read_tokens?: number;
  total_tokens?: number;
} | undefined): UsageStats | undefined {
  if (!raw) {
    return undefined;
  }
  return {
    inputTokens: raw.input_tokens,
    outputTokens: raw.output_tokens,
    thinkingTokens: raw.thinking_tokens,
    cacheReadTokens: raw.cache_read_tokens,
    totalTokens: raw.total_tokens,
  };
}

export class AgyRunner extends EventEmitter {
  private readonly agyBin: string;
  private readonly defaultWorkspace: string;
  private readonly defaultModel: string;
  private readonly spawnImpl: SpawnFn;

  private activeRuns = new Map<string, ActiveRun>();
  private activeByConversation = new Map<string, string>();
  private cachedModels: { items: ModelInfo[]; expiresAt: number } | null = null;
  private cachedVersion: string | null = null;

  constructor(options: {
    agyBin: string;
    defaultWorkspace: string;
    defaultModel?: string;
    spawnImpl?: SpawnFn;
  }) {
    super();
    this.agyBin = options.agyBin;
    this.defaultWorkspace = options.defaultWorkspace;
    this.defaultModel = options.defaultModel || "";
    this.spawnImpl = options.spawnImpl ?? spawn;
  }

  getActiveConversationIds(): Set<string> {
    return new Set(this.activeByConversation.keys());
  }

  getActiveRunCount(): number {
    return this.activeRuns.size;
  }

  private emitBridgeEvent(event: ServerToClientMessage): void {
    this.emit("bridge-event", event);
  }

  async getVersion(): Promise<string> {
    if (this.cachedVersion) {
      return this.cachedVersion;
    }
    return new Promise((resolve) => {
      execFile(this.agyBin, ["--version"], { timeout: 3000 }, (err, stdout) => {
        if (err) {
          resolve("unknown");
          return;
        }
        const version = stdout.trim().split("\n")[0] || "unknown";
        this.cachedVersion = version;
        resolve(version);
      });
    });
  }

  async listModels(forceRefresh = false): Promise<ModelInfo[]> {
    if (
      !forceRefresh &&
      this.cachedModels &&
      this.cachedModels.expiresAt > Date.now()
    ) {
      return this.cachedModels.items;
    }
    return new Promise((resolve, reject) => {
      execFile(
        this.agyBin,
        ["models"],
        { timeout: 15_000, maxBuffer: 1024 * 1024 },
        (err, stdout, stderr) => {
          const parsed = parseAgyModelsOutput(`${stdout}\n${stderr}`);
          if (err && parsed.length === 0) {
            reject(new Error(stderr.trim() || err.message));
            return;
          }
          this.cachedModels = {
            items: parsed,
            expiresAt: Date.now() + 5 * 60_000,
          };
          resolve(parsed);
        },
      );
    });
  }

  startRun(payload: SendPromptPayload): { runId: string; conversationId?: string } {
    const prompt = payload.prompt?.trim();
    if (!prompt) {
      throw new Error("Prompt cannot be empty");
    }

    if (
      payload.conversationId &&
      this.activeByConversation.has(payload.conversationId)
    ) {
      const err = new Error(
        `Conversation ${payload.conversationId} already has an active run`,
      );
      (err as Error & { statusCode?: number }).statusCode = 409;
      throw err;
    }

    const requestedWorkspace = payload.workspace?.trim();
    const cwd =
      requestedWorkspace && fs.existsSync(requestedWorkspace)
        ? requestedWorkspace
        : this.defaultWorkspace;

    const model = payload.model?.trim() || this.defaultModel;
    const args: string[] = ["--output-format", "stream-json"];

    if (payload.conversationId) {
      args.push("--conversation", payload.conversationId);
    }
    if (model) {
      args.push("--model", model);
    }
    if (payload.effort) {
      args.push("--effort", payload.effort);
    }
    if (payload.mode) {
      args.push("--mode", payload.mode);
    }
    if (payload.dangerouslySkipPermissions ?? true) {
      args.push("--dangerously-skip-permissions");
    }
    // Always bind prompt via --print= so prompts starting with '-' never get treated as flags.
    args.push(`--print=${prompt}`);

    const runId = crypto.randomUUID();
    const child = this.spawnImpl(this.agyBin, args, {
      cwd,
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    const activeRun: ActiveRun = {
      runId,
      conversationId: payload.conversationId,
      child,
      aborted: false,
    };
    this.activeRuns.set(runId, activeRun);
    if (payload.conversationId) {
      this.activeByConversation.set(payload.conversationId, runId);
    }

    this.emitBridgeEvent({
      type: "run.started",
      requestId: payload.requestId,
      runId,
      conversationId: payload.conversationId,
    });

    const stderrChunks: string[] = [];
    child.stderr?.on("data", (chunk: Buffer | string) => {
      stderrChunks.push(chunk.toString());
    });

    let completedEmitted = false;

    if (child.stdout) {
      const rl = readline.createInterface({ input: child.stdout });
      rl.on("line", (line) => {
        if (!line.trim()) {
          return;
        }
        let parsed: RawStreamLine;
        try {
          parsed = JSON.parse(line) as RawStreamLine;
        } catch {
          return;
        }

        const cid =
          parsed.conversation_id ||
          parsed.step_update?.conversation_id ||
          parsed.result?.conversation_id ||
          activeRun.conversationId;

        if (cid && activeRun.conversationId !== cid) {
          activeRun.conversationId = cid;
          this.activeByConversation.set(cid, runId);
        }

        if (parsed.event === "init" && parsed.init && cid) {
          this.emitBridgeEvent({
            type: "run.init",
            runId,
            conversationId: cid,
            model: parsed.init.model || model || "default",
            cwd: parsed.init.cwd || cwd,
          });
          return;
        }

        if (parsed.event === "step_update" && parsed.step_update && cid) {
          const update = parsed.step_update;
          if (typeof update.text_delta === "string" && update.text_delta.length > 0) {
            this.emitBridgeEvent({
              type: "run.delta",
              runId,
              conversationId: cid,
              stepIndex: update.step_index ?? 0,
              textDelta: update.text_delta,
            });
          }
          if (update.state || update.step_type) {
            this.emitBridgeEvent({
              type: "run.step",
              runId,
              conversationId: cid,
              stepIndex: update.step_index ?? 0,
              stepType: update.step_type || "unknown",
              state: update.state || "ACTIVE",
              usage: mapUsage(update.usage),
            });
          }
          return;
        }

        if (parsed.event === "result" && parsed.result && cid) {
          completedEmitted = true;
          this.emitBridgeEvent({
            type: "run.completed",
            runId,
            conversationId: cid,
            status: parsed.result.status || "SUCCESS",
            response: parsed.result.response || "",
            durationSeconds: parsed.result.duration_seconds,
            usage: mapUsage(parsed.result.usage),
          });
        }
      });
    }

    child.on("error", (err) => {
      this.cleanupRun(runId);
      this.emitBridgeEvent({
        type: "run.error",
        runId,
        conversationId: activeRun.conversationId,
        requestId: payload.requestId,
        message: `Failed to spawn agy: ${err.message}`,
      });
    });

    child.on("close", (code, signal) => {
      const cid = activeRun.conversationId;
      const wasAborted = activeRun.aborted;
      this.cleanupRun(runId);

      if (wasAborted && cid) {
        this.emitBridgeEvent({
          type: "run.aborted",
          runId,
          conversationId: cid,
        });
        return;
      }

      if (!completedEmitted && code !== 0) {
        const stderrText = stderrChunks.join("").trim();
        this.emitBridgeEvent({
          type: "run.error",
          runId,
          conversationId: cid,
          requestId: payload.requestId,
          message:
            stderrText ||
            `agy exited abnormally (code=${code ?? "null"}, signal=${signal ?? "none"})`,
        });
      }
    });

    return { runId, conversationId: payload.conversationId };
  }

  abortConversation(conversationId: string): boolean {
    const runId = this.activeByConversation.get(conversationId);
    if (!runId) {
      return false;
    }
    const active = this.activeRuns.get(runId);
    if (!active) {
      return false;
    }
    active.aborted = true;
    active.child.kill("SIGTERM");
    const forceTimer = setTimeout(() => {
      if (this.activeRuns.has(runId)) {
        active.child.kill("SIGKILL");
      }
    }, 3000);
    forceTimer.unref();
    return true;
  }

  private cleanupRun(runId: string): void {
    const active = this.activeRuns.get(runId);
    if (!active) {
      return;
    }
    this.activeRuns.delete(runId);
    if (
      active.conversationId &&
      this.activeByConversation.get(active.conversationId) === runId
    ) {
      this.activeByConversation.delete(active.conversationId);
    }
  }
}
