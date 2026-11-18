import Foundation

struct BridgeHealth: Codable, Sendable, Equatable {
    let ok: Bool
    let bridgeVersion: String
    let hostname: String
    let agyVersion: String
    let activeRuns: Int
    let defaultWorkspace: String?
    let defaultModel: String?
    let timestamp: String
}

struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
}

struct UsageStats: Codable, Hashable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let thinkingTokens: Int?
    let cacheReadTokens: Int?
    let totalTokens: Int?
}

struct ToolCallSummary: Codable, Hashable, Identifiable, Sendable {
    let name: String
    let argsPreview: String

    var id: String { "\(name):\(argsPreview)" }
}

struct ConversationSummary: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let preview: String
    let stepCount: Int
    let status: String
    let source: String
    let workspacePath: String
    let lastModifiedAt: String
    let lastUserInputAt: String
    var isRunning: Bool

    var workspaceDisplayName: String {
        let trimmed = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "~" }
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty ? trimmed : last
    }
}

enum MessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system
}

struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let stepIndex: Int
    let role: MessageRole
    var content: String
    var thinking: String?
    var toolCalls: [ToolCallSummary]
    var model: String?
    var status: String
    let createdAt: String
    var error: String?
    var usage: UsageStats?
}

enum EffortLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        }
    }
}

enum AgentMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto
    case acceptEdits = "accept-edits"
    case plan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "自动执行"
        case .acceptEdits: return "自动改文件"
        case .plan: return "只读规划"
        }
    }
}

struct SendPromptRequest: Codable, Sendable {
    let type: String
    let requestId: String
    let conversationId: String?
    let prompt: String
    let workspace: String?
    let model: String?
    let effort: EffortLevel?
    let mode: AgentMode?
    let dangerouslySkipPermissions: Bool

    init(
        requestId: String,
        conversationId: String?,
        prompt: String,
        workspace: String?,
        model: String?,
        effort: EffortLevel?,
        mode: AgentMode?,
        dangerouslySkipPermissions: Bool = true
    ) {
        self.type = "chat.send"
        self.requestId = requestId
        self.conversationId = conversationId
        self.prompt = prompt
        self.workspace = workspace
        self.model = model
        self.effort = effort
        self.mode = mode
        self.dangerouslySkipPermissions = dangerouslySkipPermissions
    }
}

struct BridgeStreamEvent: Decodable, Sendable {
    let type: String
    let online: Bool?
    let connectedAt: String?
    let requestId: String?
    let runId: String?
    let conversationId: String?
    let model: String?
    let cwd: String?
    let stepIndex: Int?
    let textDelta: String?
    let stepType: String?
    let state: String?
    let status: String?
    let response: String?
    let durationSeconds: Double?
    let message: String?
    let usage: UsageStats?
}

struct ConversationsEnvelope: Decodable, Sendable {
    let conversations: [ConversationSummary]
}

struct MessagesEnvelope: Decodable, Sendable {
    let conversation: ConversationSummary
    let messages: [ChatMessage]
}

struct ModelsEnvelope: Decodable, Sendable {
    let models: [ModelInfo]
}

struct WorkspacesEnvelope: Decodable, Sendable {
    let workspaces: [String]
}

struct AbortResponse: Decodable, Sendable {
    let aborted: Bool
    let conversationId: String
}

enum BridgeConfiguration {
    static func normalizedBaseURL(from rawInput: String) -> URL? {
        var cleaned = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if !cleaned.contains("://") {
            let lower = cleaned.lowercased()
            let isLocal = lower.hasPrefix("localhost")
                || lower.hasPrefix("127.0.0.1")
                || lower.hasPrefix("192.168.")
                || lower.hasPrefix("10.")
            cleaned = (isLocal ? "http://" : "https://") + cleaned
        }

        while cleaned.hasSuffix("/") {
            cleaned.removeLast()
        }
        if cleaned.lowercased().hasSuffix("/v1") {
            cleaned = String(cleaned.dropLast(3))
        }

        guard let url = URL(string: cleaned),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            return nil
        }
        return url
    }

    static func webSocketURL(from baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = "/v1/ws"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum MarkdownSegment: Equatable, Identifiable, Sendable {
    case prose(id: Int, text: String)
    case codeBlock(id: Int, language: String?, code: String)

    var id: Int {
        switch self {
        case .prose(let id, _): return id
        case .codeBlock(let id, _, _): return id
        }
    }

    static func parse(_ markdown: String) -> [MarkdownSegment] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var segments: [MarkdownSegment] = []
        var buffer: [String] = []
        var inCode = false
        var codeLang: String?
        var nextID = 0

        func flushProse() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                segments.append(.prose(id: nextID, text: text))
                nextID += 1
            }
            buffer.removeAll()
        }

        func flushCode() {
            let code = buffer.joined(separator: "\n")
            segments.append(.codeBlock(id: nextID, language: codeLang, code: code))
            nextID += 1
            buffer.removeAll()
            codeLang = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushProse()
                    inCode = true
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                }
            } else {
                buffer.append(line)
            }
        }

        if inCode {
            flushCode()
        } else {
            flushProse()
        }

        return segments
    }
}
