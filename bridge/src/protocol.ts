export interface UsageStats {
  inputTokens?: number;
  outputTokens?: number;
  thinkingTokens?: number;
  cacheReadTokens?: number;
  totalTokens?: number;
}

export interface ToolCallSummary {
  name: string;
  argsPreview: string;
}

export interface ConversationSummary {
  id: string;
  title: string;
  preview: string;
  stepCount: number;
  status: string;
  source: string;
  workspacePath: string;
  lastModifiedAt: string;
  lastUserInputAt: string;
  isRunning: boolean;
}

export interface ChatMessage {
  id: string;
  stepIndex: number;
  role: "user" | "assistant" | "system";
  content: string;
  thinking?: string;
  toolCalls: ToolCallSummary[];
  model?: string;
  status: string;
  createdAt: string;
  error?: string;
  usage?: UsageStats;
}

export interface ModelInfo {
  id: string;
  displayName: string;
}

export interface McpServerSummary {
  name: string;
  transport: string;
  enabled: boolean;
  target: string;
}

export interface HookSummary {
  event: string;
  name: string;
  enabled: boolean;
}

export interface ConfigOverview {
  agyVersion: string;
  bridgeVersion: string;
  hostname: string;
  defaultWorkspace: string;
  defaultModel: string | null;
  activeConversationIds: string[];
  mcpServers: McpServerSummary[];
  hooks: HookSummary[];
  skills: string[];
}

export type EffortLevel = "low" | "medium" | "high" | "xhigh" | "max";
export type AgentMode = "accept-edits" | "auto" | "plan";

export interface SendPromptPayload {
  requestId?: string;
  conversationId?: string;
  prompt: string;
  workspace?: string;
  model?: string;
  effort?: EffortLevel;
  mode?: AgentMode;
  dangerouslySkipPermissions?: boolean;
}

export type ClientToServerMessage =
  | ({ type: "chat.send" } & SendPromptPayload)
  | { type: "chat.abort"; conversationId: string };

export type ServerToClientMessage =
  | { type: "bridge.status"; online: boolean; connectedAt?: string }
  | {
      type: "run.started";
      requestId?: string;
      runId: string;
      conversationId?: string;
    }
  | {
      type: "run.init";
      runId: string;
      conversationId: string;
      model: string;
      cwd: string;
    }
  | {
      type: "run.delta";
      runId: string;
      conversationId: string;
      stepIndex: number;
      textDelta: string;
    }
  | {
      type: "run.step";
      runId: string;
      conversationId: string;
      stepIndex: number;
      stepType: string;
      state: string;
      toolName?: string;
      toolParameters?: string;
      toolOutputPreview?: string;
      durationSeconds?: number;
      usage?: UsageStats;
    }
  | {
      type: "run.completed";
      runId: string;
      conversationId: string;
      status: string;
      response: string;
      durationSeconds?: number;
      usage?: UsageStats;
    }
  | {
      type: "run.error";
      runId?: string;
      conversationId?: string;
      requestId?: string;
      message: string;
    }
  | {
      type: "run.aborted";
      runId: string;
      conversationId: string;
    };

export type RelayWireMessage =
  | {
      kind: "rpc_request";
      reqId: string;
      method: string;
      path: string;
      query: string;
      body?: string;
    }
  | {
      kind: "rpc_response";
      reqId: string;
      status: number;
      contentType?: string;
      body: string;
    }
  | { kind: "client_ws"; payload: ClientToServerMessage }
  | { kind: "server_ws"; payload: ServerToClientMessage }
  | { kind: "vps_hello"; bridgeVersion: string; hostname: string };
