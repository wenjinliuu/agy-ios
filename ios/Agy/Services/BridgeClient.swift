import Foundation

enum BridgeClientError: LocalizedError, Sendable {
    case notConfigured
    case invalidResponse
    case serverError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "请先在设置中填写服务器地址和访问密钥"
        case .invalidResponse:
            return "服务器返回了无法解析的响应"
        case .serverError(let statusCode, let message):
            return "请求失败 (\(statusCode))：\(message)"
        }
    }
}

protocol BridgeServicing: Sendable {
    func checkHealth(baseURL: URL, token: String) async throws -> BridgeHealth
    func fetchModels(baseURL: URL, token: String) async throws -> [ModelInfo]
    func fetchWorkspaces(baseURL: URL, token: String) async throws -> [String]
    func fetchConversations(baseURL: URL, token: String, query: String) async throws -> [ConversationSummary]
    func fetchMessages(baseURL: URL, token: String, conversationId: String) async throws -> MessagesEnvelope
    func abortRun(baseURL: URL, token: String, conversationId: String) async throws -> Bool
    func openStream(baseURL: URL, token: String) -> AsyncThrowingStream<BridgeStreamEvent, Error>
    func sendPrompt(_ payload: SendPromptRequest, baseURL: URL, token: String) async throws
}

actor WebSocketRelayHub {
    private var task: URLSessionWebSocketTask?

    func replaceTask(_ newTask: URLSessionWebSocketTask?) {
        task?.cancel(with: .goingAway, reason: nil)
        task = newTask
    }

    func sendText(_ text: String) async throws {
        guard let task else {
            throw BridgeClientError.notConfigured
        }
        try await task.send(.string(text))
    }

    func currentTask() -> URLSessionWebSocketTask? {
        task
    }
}

final class LiveBridgeService: BridgeServicing, @unchecked Sendable {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let wsHub = WebSocketRelayHub()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    private func authorizedRequest(
        baseURL: URL,
        path: String,
        token: String,
        method: String = "GET",
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let finalURL = components?.url else {
            throw BridgeClientError.notConfigured
        }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeClientError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let msg = Self.extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw BridgeClientError.serverError(statusCode: http.statusCode, message: msg)
        }
        return try decoder.decode(T.self, from: data)
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["error"] as? String else {
            return nil
        }
        return message
    }

    func checkHealth(baseURL: URL, token: String) async throws -> BridgeHealth {
        let req = try authorizedRequest(baseURL: baseURL, path: "/v1/health", token: token)
        return try await perform(req)
    }

    func fetchModels(baseURL: URL, token: String) async throws -> [ModelInfo] {
        let req = try authorizedRequest(baseURL: baseURL, path: "/v1/models", token: token)
        let envelope: ModelsEnvelope = try await perform(req)
        return envelope.models
    }

    func fetchWorkspaces(baseURL: URL, token: String) async throws -> [String] {
        let req = try authorizedRequest(baseURL: baseURL, path: "/v1/workspaces", token: token)
        let envelope: WorkspacesEnvelope = try await perform(req)
        return envelope.workspaces
    }

    func fetchConversations(baseURL: URL, token: String, query: String) async throws -> [ConversationSummary] {
        var items = [URLQueryItem(name: "limit", value: "50")]
        if !query.isEmpty {
            items.append(URLQueryItem(name: "q", value: query))
        }
        let req = try authorizedRequest(
            baseURL: baseURL,
            path: "/v1/conversations",
            token: token,
            queryItems: items
        )
        let envelope: ConversationsEnvelope = try await perform(req)
        return envelope.conversations
    }

    func fetchMessages(baseURL: URL, token: String, conversationId: String) async throws -> MessagesEnvelope {
        let req = try authorizedRequest(
            baseURL: baseURL,
            path: "/v1/conversations/\(conversationId)/messages",
            token: token,
            queryItems: [URLQueryItem(name: "limit", value: "200")]
        )
        return try await perform(req)
    }

    func abortRun(baseURL: URL, token: String, conversationId: String) async throws -> Bool {
        let req = try authorizedRequest(
            baseURL: baseURL,
            path: "/v1/conversations/\(conversationId)/abort",
            token: token,
            method: "POST",
            body: Data("{}".utf8)
        )
        let response: AbortResponse = try await perform(req)
        return response.aborted
    }

    func openStream(baseURL: URL, token: String) -> AsyncThrowingStream<BridgeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let runnerTask = Task {
                guard let wsURL = BridgeConfiguration.webSocketURL(from: baseURL) else {
                    continuation.finish(throwing: BridgeClientError.notConfigured)
                    return
                }
                var request = URLRequest(url: wsURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                let socket = session.webSocketTask(with: request)
                await wsHub.replaceTask(socket)
                socket.resume()

                let pingTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(25))
                        guard !Task.isCancelled else { break }
                        try? await socket.send(.string("ping"))
                    }
                }

                defer {
                    pingTask.cancel()
                    socket.cancel(with: .normalClosure, reason: nil)
                }

                do {
                    while !Task.isCancelled {
                        let msg = try await socket.receive()
                        let data: Data
                        switch msg {
                        case .string(let text):
                            if text == "pong" || text == "ping" || text.isEmpty {
                                continue
                            }
                            data = Data(text.utf8)
                        case .data(let raw):
                            data = raw
                        @unknown default:
                            continue
                        }

                        if let event = try? decoder.decode(BridgeStreamEvent.self, from: data) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { _ in
                runnerTask.cancel()
            }
        }
    }

    func sendPrompt(_ payload: SendPromptRequest, baseURL: URL, token: String) async throws {
        let data = try encoder.encode(payload)
        if let active = await wsHub.currentTask(), active.state == .running,
           let text = String(data: data, encoding: .utf8) {
            try await wsHub.sendText(text)
            return
        }

        // Fallback to REST POST if WebSocket is reconnecting
        let req = try authorizedRequest(
            baseURL: baseURL,
            path: "/v1/conversations/send",
            token: token,
            method: "POST",
            body: data
        )
        struct Accepted: Decodable { let runId: String }
        let _: Accepted = try await perform(req)
    }
}

final class DemoBridgeService: BridgeServicing, @unchecked Sendable {
    private let demoConversationID = "demo-1111-2222-3333-444444444444"
    private let lock = NSLock()
    private var eventContinuation: AsyncStream<BridgeStreamEvent>.Continuation?

    func checkHealth(baseURL: URL, token: String) async throws -> BridgeHealth {
        BridgeHealth(
            ok: true,
            bridgeVersion: "0.1.0-demo",
            hostname: "vps-demo",
            agyVersion: "1.5.10",
            activeRuns: 0,
            defaultWorkspace: "/home/ubuntu/projects/agy-ios",
            defaultModel: "gemini-3.8-flash-medium",
            timestamp: "2026-11-18T03:30:00Z"
        )
    }

    func fetchModels(baseURL: URL, token: String) async throws -> [ModelInfo] {
        [
            ModelInfo(id: "gemini-3.8-flash-medium", displayName: "Gemini 3.8 Flash (Medium)"),
            ModelInfo(id: "gemini-4-hydrogen-high", displayName: "Gemini 4 Hydrogen (High)"),
            ModelInfo(id: "claude-opus-5-5-high", displayName: "Claude Opus 5.5 (High)"),
        ]
    }

    func fetchWorkspaces(baseURL: URL, token: String) async throws -> [String] {
        ["/home/ubuntu/projects/agy-ios", "/home/ubuntu/projects/agy-vps-kit"]
    }

    func fetchConversations(baseURL: URL, token: String, query: String) async throws -> [ConversationSummary] {
        let all = [
            ConversationSummary(
                id: demoConversationID,
                title: "Agy 原生 iOS 客户端联调",
                preview: "已接通 Cloudflare Worker DO 中继与 stream-json 输出",
                stepCount: 4,
                status: "CASCADE_RUN_STATUS_IDLE",
                source: "cli",
                workspacePath: "/home/ubuntu/projects/agy-ios",
                lastModifiedAt: "2026-11-18T03:30:00Z",
                lastUserInputAt: "2026-11-18T03:29:00Z",
                isRunning: false
            ),
            ConversationSummary(
                id: "demo-2222-3333-4444-555555555555",
                title: "反重力 VPS 部署与中文标题钩子",
                preview: "auto-zh-title Stop Hook 验证通过",
                stepCount: 8,
                status: "CASCADE_RUN_STATUS_IDLE",
                source: "cli",
                workspacePath: "/home/ubuntu/projects/agy-vps-kit",
                lastModifiedAt: "2026-11-18T02:10:00Z",
                lastUserInputAt: "2026-11-18T02:08:00Z",
                isRunning: false
            ),
        ]
        guard !query.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.preview.localizedCaseInsensitiveContains(query) }
    }

    func fetchMessages(baseURL: URL, token: String, conversationId: String) async throws -> MessagesEnvelope {
        let convs = try await fetchConversations(baseURL: baseURL, token: token, query: "")
        let conv = convs.first { $0.id == conversationId } ?? convs[0]
        let msgs = [
            ChatMessage(
                id: "\(conversationId):0",
                stepIndex: 0,
                role: .user,
                content: "帮我检查 Bridge 接口状态，并总结接下来怎么在 TestFlight 测试。",
                thinking: nil,
                toolCalls: [],
                model: nil,
                status: "DONE",
                createdAt: "2026-11-18T03:29:00Z",
                error: nil,
                usage: nil
            ),
            ChatMessage(
                id: "\(conversationId):1",
                stepIndex: 1,
                role: .assistant,
                content: "Bridge 与 Worker 中继已就绪。\n\n```bash\ncd bridge && npm run check\n```\n\n接下来可以在设置页填入 `*.workers.dev` 地址并测试连接。",
                thinking: "先读取 bridge 与 worker 的检查结果，再整理客户端验证步骤。",
                toolCalls: [
                    ToolCallSummary(name: "run_command", argsPreview: "{\"CommandLine\":\"npm run check\"}"),
                ],
                model: "gemini-3.8-flash-medium",
                status: "DONE",
                createdAt: "2026-11-18T03:30:00Z",
                error: nil,
                usage: UsageStats(inputTokens: 420, outputTokens: 86, thinkingTokens: 24, cacheReadTokens: 0, totalTokens: 530)
            ),
        ]
        return MessagesEnvelope(conversation: conv, messages: msgs)
    }

    func abortRun(baseURL: URL, token: String, conversationId: String) async throws -> Bool {
        true
    }

    func openStream(baseURL: URL, token: String) -> AsyncThrowingStream<BridgeStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let stream = AsyncStream<BridgeStreamEvent> { inner in
                lock.withLock { self.eventContinuation = inner }
                inner.yield(
                    BridgeStreamEvent(
                        type: "bridge.status",
                        online: true,
                        connectedAt: "2026-11-18T03:30:00Z",
                        requestId: nil,
                        runId: nil,
                        conversationId: nil,
                        model: nil,
                        cwd: nil,
                        stepIndex: nil,
                        textDelta: nil,
                        stepType: nil,
                        state: nil,
                        status: nil,
                        response: nil,
                        durationSeconds: nil,
                        message: nil,
                        usage: nil
                    )
                )
            }
            let forwardTask = Task {
                for await ev in stream {
                    continuation.yield(ev)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                forwardTask.cancel()
            }
        }
    }

    func sendPrompt(_ payload: SendPromptRequest, baseURL: URL, token: String) async throws {
        let cid = payload.conversationId ?? demoConversationID
        let runId = "demo-run-\(UUID().uuidString.prefix(8))"
        let continuation = lock.withLock { self.eventContinuation }
        continuation?.yield(
            BridgeStreamEvent(
                type: "run.init",
                online: nil,
                connectedAt: nil,
                requestId: payload.requestId,
                runId: runId,
                conversationId: cid,
                model: payload.model ?? "gemini-3.8-flash-medium",
                cwd: payload.workspace ?? "/home/ubuntu/projects/agy-ios",
                stepIndex: nil,
                textDelta: nil,
                stepType: nil,
                state: nil,
                status: nil,
                response: nil,
                durationSeconds: nil,
                message: nil,
                usage: nil
            )
        )
        continuation?.yield(
            BridgeStreamEvent(
                type: "run.delta",
                online: nil,
                connectedAt: nil,
                requestId: payload.requestId,
                runId: runId,
                conversationId: cid,
                model: nil,
                cwd: nil,
                stepIndex: 99,
                textDelta: "演示模式已收到指令：「\(payload.prompt)」",
                stepType: nil,
                state: nil,
                status: nil,
                response: nil,
                durationSeconds: nil,
                message: nil,
                usage: nil
            )
        )
        continuation?.yield(
            BridgeStreamEvent(
                type: "run.completed",
                online: nil,
                connectedAt: nil,
                requestId: payload.requestId,
                runId: runId,
                conversationId: cid,
                model: nil,
                cwd: nil,
                stepIndex: nil,
                textDelta: nil,
                stepType: nil,
                state: nil,
                status: "SUCCESS",
                response: "演示模式已收到指令：「\(payload.prompt)」",
                durationSeconds: 0.4,
                message: nil,
                usage: nil
            )
        )
    }
}
