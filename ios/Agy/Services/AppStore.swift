import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    private static let serverURLKey = "agy_server_url"
    private static let authTokenKey = "agy_auth_token"

    private let secretStore: SecretStoring
    private var service: BridgeServicing
    private var streamTask: Task<Void, Never>?

    var serverURLString: String
    var authToken: String
    var isDemoMode: Bool

    var bridgeOnline: Bool = false
    var healthInfo: BridgeHealth?
    var connectionError: String?

    var conversations: [ConversationSummary] = []
    var selectedConversationID: String?
    var messagesByConversation: [String: [ChatMessage]] = [:]

    var models: [ModelInfo] = [
        ModelInfo(id: "gemini-3.8-flash-medium", displayName: "Gemini 3.8 Flash (Medium)"),
        ModelInfo(id: "gemini-4-hydrogen-high", displayName: "Gemini 4 Hydrogen (High)"),
        ModelInfo(id: "claude-opus-5-5-high", displayName: "Claude Opus 5.5 (High)"),
    ]
    var workspaces: [String] = []

    var selectedModelID: String = "gemini-3.8-flash-medium"
    var selectedEffort: EffortLevel = .medium
    var selectedMode: AgentMode = .auto

    var searchQuery: String = ""
    var isLoadingConversations: Bool = false
    var isLoadingMessages: Bool = false
    var activeStreamingRuns: [String: String] = [:] // conversationId -> runId
    var pendingNewRun: (requestId: String, prompt: String, model: String)?

    var isConfigured: Bool {
        if isDemoMode { return true }
        return BridgeConfiguration.normalizedBaseURL(from: serverURLString) != nil && !authToken.isEmpty
    }

    init(
        secretStore: SecretStoring = KeychainSecretStore(),
        service: BridgeServicing = LiveBridgeService(),
        demoMode: Bool = false
    ) {
        self.secretStore = secretStore
        self.service = demoMode ? DemoBridgeService() : service
        self.isDemoMode = demoMode

        if demoMode {
            self.serverURLString = "https://demo.local"
            self.authToken = "demo-token"
        } else {
            self.serverURLString = secretStore.load(forKey: Self.serverURLKey)
            self.authToken = secretStore.load(forKey: Self.authTokenKey)
        }
    }

    func activeCredentials() -> (baseURL: URL, token: String)? {
        if isDemoMode {
            return (URL(string: "https://demo.local")!, "demo-token")
        }
        guard let url = BridgeConfiguration.normalizedBaseURL(from: serverURLString),
              !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (url, authToken.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func saveSettings(rawURL: String, rawToken: String) async throws -> BridgeHealth {
        guard let normalized = BridgeConfiguration.normalizedBaseURL(from: rawURL) else {
            throw BridgeClientError.serverError(statusCode: 400, message: "请输入有效的 http(s) 服务器地址")
        }
        let cleanedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedToken.isEmpty else {
            throw BridgeClientError.serverError(statusCode: 400, message: "访问密钥不能为空")
        }

        if isDemoMode {
            isDemoMode = false
            service = LiveBridgeService()
        }

        let health = try await service.checkHealth(baseURL: normalized, token: cleanedToken)
        serverURLString = normalized.absoluteString
        authToken = cleanedToken
        secretStore.save(value: serverURLString, forKey: Self.serverURLKey)
        secretStore.save(value: cleanedToken, forKey: Self.authTokenKey)
        healthInfo = health
        bridgeOnline = true
        connectionError = nil

        connectStream()
        await refreshDashboard()
        return health
    }

    func enableDemoMode() async {
        isDemoMode = true
        service = DemoBridgeService()
        serverURLString = "https://demo.local"
        authToken = "demo-token"
        connectionError = nil
        connectStream()
        await refreshDashboard()
    }

    func clearCredentials() {
        streamTask?.cancel()
        streamTask = nil
        isDemoMode = false
        service = LiveBridgeService()
        serverURLString = ""
        authToken = ""
        secretStore.delete(forKey: Self.serverURLKey)
        secretStore.delete(forKey: Self.authTokenKey)
        bridgeOnline = false
        healthInfo = nil
        conversations = []
        messagesByConversation = [:]
        selectedConversationID = nil
    }

    func connectStream() {
        streamTask?.cancel()
        guard let creds = activeCredentials() else {
            bridgeOnline = false
            return
        }

        let currentService = service
        streamTask = Task { [weak self] in
            var delaySeconds = 1
            while !Task.isCancelled {
                do {
                    for try await event in currentService.openStream(baseURL: creds.baseURL, token: creds.token) {
                        guard let self else { return }
                        delaySeconds = 1
                        self.handleStreamEvent(event)
                    }
                } catch {
                    if Task.isCancelled { return }
                    self?.bridgeOnline = false
                }
                try? await Task.sleep(for: .seconds(delaySeconds))
                delaySeconds = min(delaySeconds * 2, 20)
            }
        }
    }

    func refreshDashboard() async {
        guard let creds = activeCredentials() else { return }
        isLoadingConversations = true
        defer { isLoadingConversations = false }

        do {
            async let convTask = service.fetchConversations(baseURL: creds.baseURL, token: creds.token, query: searchQuery)
            async let healthTask = service.checkHealth(baseURL: creds.baseURL, token: creds.token)
            async let modelsTask = service.fetchModels(baseURL: creds.baseURL, token: creds.token)
            async let wsTask = service.fetchWorkspaces(baseURL: creds.baseURL, token: creds.token)

            let (fetchedConvs, health, fetchedModels, fetchedWorkspaces) = try await (convTask, healthTask, modelsTask, wsTask)
            conversations = fetchedConvs
            healthInfo = health
            bridgeOnline = true
            connectionError = nil

            if !fetchedModels.isEmpty {
                models = fetchedModels
                if let def = health.defaultModel, fetchedModels.contains(where: { $0.id == def }) {
                    selectedModelID = def
                } else if !fetchedModels.contains(where: { $0.id == selectedModelID }) {
                    selectedModelID = fetchedModels[0].id
                }
            }
            workspaces = fetchedWorkspaces
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func loadMessages(for conversationId: String) async {
        guard let creds = activeCredentials() else { return }
        isLoadingMessages = true
        defer { isLoadingMessages = false }

        do {
            let envelope = try await service.fetchMessages(baseURL: creds.baseURL, token: creds.token, conversationId: conversationId)
            messagesByConversation[conversationId] = envelope.messages
            if let idx = conversations.firstIndex(where: { $0.id == conversationId }) {
                conversations[idx] = envelope.conversation
            }
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func sendPrompt(
        text: String,
        conversationId: String?,
        workspace: String? = nil,
        model: String? = nil,
        effort: EffortLevel? = nil,
        mode: AgentMode? = nil
    ) async {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let creds = activeCredentials() else { return }

        let requestId = UUID().uuidString
        let chosenModel = model ?? selectedModelID
        let chosenEffort = effort ?? selectedEffort
        let chosenMode = mode ?? selectedMode

        if let cid = conversationId {
            var current = messagesByConversation[cid] ?? []
            current.append(
                ChatMessage(
                    id: "local-user-\(requestId)",
                    stepIndex: (current.last?.stepIndex ?? -1) + 1,
                    role: .user,
                    content: cleaned,
                    thinking: nil,
                    toolCalls: [],
                    model: nil,
                    status: "DONE",
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    error: nil,
                    usage: nil
                )
            )
            current.append(
                ChatMessage(
                    id: "local-stream-\(requestId)",
                    stepIndex: (current.last?.stepIndex ?? 0) + 1,
                    role: .assistant,
                    content: "",
                    thinking: nil,
                    toolCalls: [],
                    model: chosenModel,
                    status: "ACTIVE",
                    createdAt: ISO8601DateFormatter().string(from: Date()),
                    error: nil,
                    usage: nil
                )
            )
            messagesByConversation[cid] = current
            activeStreamingRuns[cid] = requestId
        } else {
            pendingNewRun = (requestId: requestId, prompt: cleaned, model: chosenModel)
        }

        let payload = SendPromptRequest(
            requestId: requestId,
            conversationId: conversationId,
            prompt: cleaned,
            workspace: workspace,
            model: chosenModel,
            effort: chosenEffort,
            mode: chosenMode
        )

        do {
            try await service.sendPrompt(payload, baseURL: creds.baseURL, token: creds.token)
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
            if let cid = conversationId {
                activeStreamingRuns.removeValue(forKey: cid)
            }
        }
    }

    func abortRun(conversationId: String) async {
        guard let creds = activeCredentials() else { return }
        _ = try? await service.abortRun(baseURL: creds.baseURL, token: creds.token, conversationId: conversationId)
    }

    func handleStreamEvent(_ event: BridgeStreamEvent) {
        switch event.type {
        case "bridge.status":
            bridgeOnline = event.online ?? false
            if !bridgeOnline {
                activeStreamingRuns.removeAll()
            }

        case "run.started":
            if let cid = event.conversationId, let runId = event.runId {
                activeStreamingRuns[cid] = runId
            }

        case "run.init":
            guard let cid = event.conversationId, let runId = event.runId else { return }
            activeStreamingRuns[cid] = runId
            if let idx = conversations.firstIndex(where: { $0.id == cid }) {
                conversations[idx].isRunning = true
            } else {
                let placeholder = ConversationSummary(
                    id: cid,
                    title: "新对话",
                    preview: "正在思考...",
                    stepCount: 1,
                    status: "RUNNING",
                    source: "cli",
                    workspacePath: event.cwd ?? "",
                    lastModifiedAt: ISO8601DateFormatter().string(from: Date()),
                    lastUserInputAt: ISO8601DateFormatter().string(from: Date()),
                    isRunning: true
                )
                conversations.insert(placeholder, at: 0)
            }
            if let pending = pendingNewRun {
                let now = ISO8601DateFormatter().string(from: Date())
                messagesByConversation[cid] = [
                    ChatMessage(
                        id: "local-user-\(pending.requestId)",
                        stepIndex: 0,
                        role: .user,
                        content: pending.prompt,
                        thinking: nil,
                        toolCalls: [],
                        model: nil,
                        status: "DONE",
                        createdAt: now,
                        error: nil,
                        usage: nil
                    ),
                    ChatMessage(
                        id: "local-stream-\(pending.requestId)",
                        stepIndex: 1,
                        role: .assistant,
                        content: "",
                        thinking: nil,
                        toolCalls: [],
                        model: pending.model,
                        status: "ACTIVE",
                        createdAt: now,
                        error: nil,
                        usage: nil
                    ),
                ]
                pendingNewRun = nil
                selectedConversationID = cid
            }

        case "run.delta":
            guard let cid = event.conversationId, let delta = event.textDelta else { return }
            var list = messagesByConversation[cid] ?? []
            if let lastIdx = list.indices.last, list[lastIdx].role == .assistant, list[lastIdx].status == "ACTIVE" {
                list[lastIdx].content += delta
            } else {
                list.append(
                    ChatMessage(
                        id: "stream-\(event.runId ?? cid)-\(event.stepIndex ?? list.count)",
                        stepIndex: event.stepIndex ?? list.count,
                        role: .assistant,
                        content: delta,
                        thinking: nil,
                        toolCalls: [],
                        model: selectedModelID,
                        status: "ACTIVE",
                        createdAt: ISO8601DateFormatter().string(from: Date()),
                        error: nil,
                        usage: nil
                    )
                )
            }
            messagesByConversation[cid] = list

        case "run.completed":
            guard let cid = event.conversationId else { return }
            activeStreamingRuns.removeValue(forKey: cid)
            var list = messagesByConversation[cid] ?? []
            if let lastIdx = list.indices.last, list[lastIdx].role == .assistant {
                if list[lastIdx].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let finalResponse = event.response?.trimmingCharacters(in: .newlines),
                   !finalResponse.isEmpty {
                    list[lastIdx].content = finalResponse
                }
                list[lastIdx].status = "DONE"
                list[lastIdx].usage = event.usage ?? list[lastIdx].usage
                messagesByConversation[cid] = list
            }
            if let idx = conversations.firstIndex(where: { $0.id == cid }) {
                conversations[idx].isRunning = false
            }
            Task { [weak self] in
                await self?.loadMessages(for: cid)
                await self?.refreshDashboard()
            }

        case "run.aborted":
            guard let cid = event.conversationId else { return }
            activeStreamingRuns.removeValue(forKey: cid)
            var list = messagesByConversation[cid] ?? []
            if let lastIdx = list.indices.last, list[lastIdx].role == .assistant {
                list[lastIdx].status = "ABORTED"
                if list[lastIdx].content.isEmpty {
                    list[lastIdx].content = "已手动停止生成。"
                }
                messagesByConversation[cid] = list
            }
            if let idx = conversations.firstIndex(where: { $0.id == cid }) {
                conversations[idx].isRunning = false
            }

        case "run.error":
            if let cid = event.conversationId {
                activeStreamingRuns.removeValue(forKey: cid)
                var list = messagesByConversation[cid] ?? []
                if let lastIdx = list.indices.last, list[lastIdx].role == .assistant, list[lastIdx].status == "ACTIVE" {
                    list[lastIdx].status = "ERROR"
                    list[lastIdx].error = event.message ?? "执行出错"
                } else {
                    list.append(
                        ChatMessage(
                            id: "error-\(UUID().uuidString)",
                            stepIndex: (list.last?.stepIndex ?? -1) + 1,
                            role: .assistant,
                            content: "",
                            thinking: nil,
                            toolCalls: [],
                            model: nil,
                            status: "ERROR",
                            createdAt: ISO8601DateFormatter().string(from: Date()),
                            error: event.message ?? "执行出错",
                            usage: nil
                        )
                    )
                }
                messagesByConversation[cid] = list
            } else {
                connectionError = event.message
            }

        default:
            break
        }
    }
}
