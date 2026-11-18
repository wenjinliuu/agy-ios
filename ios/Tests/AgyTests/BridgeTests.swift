import XCTest
@testable import Agy

private final class IdleMockBridgeService: BridgeServicing, @unchecked Sendable {
    func checkHealth(baseURL: URL, token: String) async throws -> BridgeHealth {
        BridgeHealth(
            ok: true,
            bridgeVersion: "0.1.0",
            hostname: "mock",
            agyVersion: "1.5.10",
            activeRuns: 0,
            defaultWorkspace: "/tmp",
            defaultModel: "gemini-3.8-flash-medium",
            timestamp: "2026-11-18T00:00:00Z"
        )
    }

    func fetchModels(baseURL: URL, token: String) async throws -> [ModelInfo] { [] }
    func fetchWorkspaces(baseURL: URL, token: String) async throws -> [String] { [] }
    func fetchConfigOverview(baseURL: URL, token: String) async throws -> ConfigOverview {
        ConfigOverview(
            agyVersion: "1.5.10",
            bridgeVersion: "0.1.0",
            hostname: "mock",
            defaultWorkspace: "/tmp",
            defaultModel: "gemini-3.8-flash-medium",
            activeConversationIds: [],
            mcpServers: [],
            hooks: [],
            skills: []
        )
    }
    func toggleMcpServer(baseURL: URL, token: String, name: String, enabled: Bool) async throws -> Bool { enabled }
    func fetchConversations(baseURL: URL, token: String, query: String) async throws -> [ConversationSummary] { [] }
    func fetchMessages(baseURL: URL, token: String, conversationId: String) async throws -> MessagesEnvelope {
        throw BridgeClientError.notConfigured
    }
    func renameConversation(baseURL: URL, token: String, conversationId: String, title: String) async throws -> ConversationSummary {
        throw BridgeClientError.notConfigured
    }
    func abortRun(baseURL: URL, token: String, conversationId: String) async throws -> Bool { true }
    func openStream(baseURL: URL, token: String) -> AsyncThrowingStream<BridgeStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendPrompt(_ payload: SendPromptRequest, baseURL: URL, token: String) async throws {}
}

final class BridgeTests: XCTestCase {
    func testNormalizedBaseURLAndWebSocketURL() {
        let bareWorker = BridgeConfiguration.normalizedBaseURL(from: "agy-bridge.demo.workers.dev/")
        XCTAssertEqual(bareWorker?.absoluteString, "https://agy-bridge.demo.workers.dev")
        XCTAssertEqual(
            bareWorker.flatMap(BridgeConfiguration.webSocketURL)?.absoluteString,
            "wss://agy-bridge.demo.workers.dev/v1/ws"
        )

        let withV1 = BridgeConfiguration.normalizedBaseURL(from: "https://agy.example.workers.dev/v1/")
        XCTAssertEqual(withV1?.absoluteString, "https://agy.example.workers.dev")

        let local = BridgeConfiguration.normalizedBaseURL(from: "127.0.0.1:8787")
        XCTAssertEqual(local?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertEqual(
            local.flatMap(BridgeConfiguration.webSocketURL)?.absoluteString,
            "ws://127.0.0.1:8787/v1/ws"
        )

        XCTAssertNil(BridgeConfiguration.normalizedBaseURL(from: "   "))
        XCTAssertNil(BridgeConfiguration.normalizedBaseURL(from: "ftp://invalid.host"))
    }

    func testMarkdownSegmentAndToolSummaryHelpers() {
        let input = """
        检查状态：

        ```bash
        npm run check
        ```

        全部通过
        """
        let segments = MarkdownSegment.parse(input)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0], .prose(id: 0, text: "检查状态："))
        XCTAssertEqual(segments[1], .codeBlock(id: 1, language: "bash", code: "npm run check"))
        XCTAssertEqual(segments[2], .prose(id: 2, text: "全部通过"))

        let call = ToolCallSummary(name: "run_command", argsPreview: #"{"CommandLine":"git status"}"#)
        XCTAssertEqual(call.readableSummary, "git status")

        let model = ModelInfo(id: "gemini-3.8-flash-medium", displayName: "Gemini 3.8 Flash (Medium)")
        XCTAssertEqual(model.compactName, "3.8 Flash M")
    }

    func testDecodeBridgeStreamEvents() throws {
        let stepJSON = #"{"type":"run.step","runId":"r1","conversationId":"c1","stepIndex":2,"stepType":"tool","state":"ACTIVE","toolName":"run_command","toolParameters":"{\"CommandLine\":\"ls\"}"}"#
        let decoded = try JSONDecoder().decode(BridgeStreamEvent.self, from: Data(stepJSON.utf8))
        XCTAssertEqual(decoded.type, "run.step")
        XCTAssertEqual(decoded.toolName, "run_command")
    }

    @MainActor
    func testAppStoreDemoAndStreamingStateTransitions() async throws {
        let demoStore = AppStore(secretStore: InMemorySecretStore(), service: DemoBridgeService(), demoMode: false)
        XCTAssertFalse(demoStore.isConfigured)
        await demoStore.enableDemoMode()
        XCTAssertTrue(demoStore.isConfigured)
        XCTAssertEqual(demoStore.conversations.count, 2)

        let store = AppStore(
            secretStore: InMemorySecretStore(initial: [
                "agy_server_url": "https://mock.local",
                "agy_auth_token": "mock-token",
            ]),
            service: IdleMockBridgeService(),
            demoMode: false
        )

        await store.sendPrompt(text: "列出目录", conversationId: nil)
        XCTAssertNotNil(store.pendingNewRun)

        store.handleStreamEvent(
            BridgeStreamEvent(
                type: "run.init",
                online: nil,
                connectedAt: nil,
                requestId: store.pendingNewRun?.requestId,
                runId: "run-new",
                conversationId: "conv-new",
                model: "gemini-3.8-flash-medium",
                cwd: "/home/ubuntu/projects/agy-ios",
                stepIndex: nil,
                textDelta: nil,
                stepType: nil,
                state: nil,
                toolName: nil,
                toolParameters: nil,
                toolOutputPreview: nil,
                status: nil,
                response: nil,
                durationSeconds: nil,
                message: nil,
                usage: nil
            )
        )
        XCTAssertEqual(store.selectedConversationID, "conv-new")
        XCTAssertEqual(store.messagesByConversation["conv-new"]?.count, 2)

        store.handleStreamEvent(
            BridgeStreamEvent(
                type: "run.step",
                online: nil,
                connectedAt: nil,
                requestId: nil,
                runId: "run-new",
                conversationId: "conv-new",
                model: nil,
                cwd: nil,
                stepIndex: 2,
                textDelta: nil,
                stepType: "tool",
                state: "ACTIVE",
                toolName: "run_command",
                toolParameters: #"{"CommandLine":"ls"}"#,
                toolOutputPreview: nil,
                status: nil,
                response: nil,
                durationSeconds: nil,
                message: nil,
                usage: nil
            )
        )
        XCTAssertEqual(store.liveStepByConversation["conv-new"]?.toolName, "run_command")

        store.handleStreamEvent(
            BridgeStreamEvent(
                type: "run.delta",
                online: nil,
                connectedAt: nil,
                requestId: nil,
                runId: "run-new",
                conversationId: "conv-new",
                model: nil,
                cwd: nil,
                stepIndex: 1,
                textDelta: "已执行完成",
                stepType: nil,
                state: nil,
                toolName: nil,
                toolParameters: nil,
                toolOutputPreview: nil,
                status: nil,
                response: nil,
                durationSeconds: nil,
                message: nil,
                usage: nil
            )
        )
        XCTAssertEqual(store.messagesByConversation["conv-new"]?.last?.content, "已执行完成")

        store.handleStreamEvent(
            BridgeStreamEvent(
                type: "run.aborted",
                online: nil,
                connectedAt: nil,
                requestId: nil,
                runId: "run-new",
                conversationId: "conv-new",
                model: nil,
                cwd: nil,
                stepIndex: nil,
                textDelta: nil,
                stepType: nil,
                state: nil,
                toolName: nil,
                toolParameters: nil,
                toolOutputPreview: nil,
                status: nil,
                response: nil,
                durationSeconds: nil,
                message: nil,
                usage: nil
            )
        )
        XCTAssertEqual(store.messagesByConversation["conv-new"]?.last?.status, "ABORTED")
        XCTAssertNil(store.activeStreamingRuns["conv-new"])
        XCTAssertNil(store.liveStepByConversation["conv-new"])
    }
}
