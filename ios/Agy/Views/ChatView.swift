import SwiftUI

struct ChatView: View {
    @Bindable var store: AppStore
    let conversationID: String

    @State private var draftPrompt: String = ""
    @FocusState private var composerFocused: Bool

    private var conversation: ConversationSummary? {
        store.conversations.first { $0.id == conversationID }
    }

    private var messages: [ChatMessage] {
        store.messagesByConversation[conversationID] ?? []
    }

    private var isStreaming: Bool {
        store.activeStreamingRuns[conversationID] != nil || (conversation?.isRunning ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.isLoadingMessages && messages.isEmpty {
                            ProgressView("正在载入对话...")
                                .frame(maxWidth: .infinity, minHeight: 160)
                        } else if messages.isEmpty {
                            ContentUnavailableView(
                                "暂无消息内容",
                                systemImage: "text.bubble",
                                description: Text("在下方输入指令，继续在这个会话中执行任务。")
                            )
                        } else {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastID = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()
            composerBar
        }
        .navigationTitle(conversation?.title ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("模型", selection: $store.selectedModelID) {
                        ForEach(store.models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    Picker("思考强度", selection: $store.selectedEffort) {
                        ForEach(EffortLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    Picker("执行模式", selection: $store.selectedMode) {
                        ForEach(AgentMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("调整模型与参数")
                .accessibilityIdentifier("chat-options-menu")
            }
        }
        .task(id: conversationID) {
            await store.loadMessages(for: conversationID)
        }
        .refreshable {
            await store.loadMessages(for: conversationID)
        }
    }

    private var composerBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(store.selectedModelID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(store.selectedEffort.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let ws = conversation?.workspaceDisplayName {
                    Label(ws, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("给 agy 发消息...", text: $draftPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .focused($composerFocused)
                    .accessibilityIdentifier("chat-prompt-input")

                if isStreaming {
                    Button {
                        Task { await store.abortRun(conversationId: conversationID) }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("停止执行")
                    .accessibilityIdentifier("chat-abort-button")
                } else {
                    Button {
                        let text = draftPrompt
                        draftPrompt = ""
                        composerFocused = false
                        Task {
                            await store.sendPrompt(
                                text: text,
                                conversationId: conversationID,
                                workspace: conversation?.workspacePath
                            )
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送指令")
                    .accessibilityIdentifier("chat-send-button")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    @State private var showThinking = false
    @State private var showTools = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            if message.role == .user {
                HStack {
                    Spacer(minLength: 44)
                    Text(message.content)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if let thinking = message.thinking, !thinking.isEmpty {
                        DisclosureGroup("思考过程", isExpanded: $showThinking) {
                            Text(thinking)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                        .font(.caption.weight(.medium))
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("thinking-disclosure-\(message.stepIndex)")
                    }

                    if !message.toolCalls.isEmpty {
                        DisclosureGroup("调用工具 (\(message.toolCalls.count))", isExpanded: $showTools) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(message.toolCalls) { call in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(call.name)
                                            .font(.caption.monospaced().weight(.semibold))
                                        if !call.argsPreview.isEmpty {
                                            Text(call.argsPreview)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(3)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 4)
                        }
                        .font(.caption.weight(.medium))
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if !message.content.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(MarkdownSegment.parse(message.content)) { segment in
                                switch segment {
                                case .prose(_, let text):
                                    proseText(text)
                                        .textSelection(.enabled)
                                case .codeBlock(_, let language, let code):
                                    CodeBlockCard(language: language, code: code)
                                }
                            }
                        }
                    } else if message.status == "ACTIVE" {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在生成...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = message.error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func proseText(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.body)
        } else {
            Text(text)
                .font(.body)
        }
    }
}

private struct CodeBlockCard: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "已复制" : "复制") {
                    UIPasteboard.general.string = code
                    copied = true
                }
                .font(.caption2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
