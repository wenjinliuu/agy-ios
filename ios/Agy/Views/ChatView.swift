import SwiftUI

struct ChatView: View {
    @Bindable var store: AppStore
    let conversationID: String

    @State private var draftPrompt: String = ""
    @State private var showingRenameAlert: Bool = false
    @State private var renameDraft: String = ""
    @FocusState private var composerFocused: Bool

    private var conversation: ConversationSummary? {
        store.conversations.first { $0.id == conversationID }
    }

    private var messages: [ChatMessage] {
        store.messagesByConversation[conversationID] ?? []
    }

    private var messagesError: String? {
        store.messagesErrorByConversation[conversationID]
    }

    private var liveStep: LiveStepStatus? {
        store.liveStepByConversation[conversationID]
    }

    private var isStreaming: Bool {
        store.activeStreamingRuns[conversationID] != nil || (conversation?.isRunning ?? false)
    }

    private var selectedModelCompactName: String {
        store.models.first(where: { $0.id == store.selectedModelID })?.compactName ?? store.selectedModelID
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorText = messagesError, !errorText.isEmpty {
                errorBanner(text: errorText)
            } else if !store.bridgeOnline && !store.isDemoMode {
                offlineBanner
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.isLoadingMessages && messages.isEmpty {
                            ProgressView("正在载入对话记录...")
                                .frame(maxWidth: .infinity, minHeight: 180)
                        } else if messages.isEmpty {
                            ContentUnavailableView(
                                messagesError == nil ? "暂无消息内容" : "对话加载失败",
                                systemImage: messagesError == nil ? "text.bubble" : "wifi.exclamationmark",
                                description: Text(messagesError ?? "在下方输入指令，继续在这个会话中执行任务。")
                            )
                        } else {
                            ForEach(messages) { message in
                                MessageBubble(
                                    message: message,
                                    liveStep: (message.status == "ACTIVE" && message.role == .assistant) ? liveStep : nil
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: messages.last?.content) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()
            composerDock
        }
        .navigationTitle(conversation?.title ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    renameDraft = conversation?.title ?? ""
                    showingRenameAlert = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("重命名对话")

                Button {
                    Task { await store.loadMessages(for: conversationID) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新消息")
            }
        }
        .alert("重命名对话", isPresented: $showingRenameAlert) {
            TextField("输入新标题", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let text = renameDraft
                Task { try? await store.renameConversation(id: conversationID, title: text) }
            }
        }
        .onAppear {
            store.activeViewingConversationID = conversationID
        }
        .onDisappear {
            if store.activeViewingConversationID == conversationID {
                store.activeViewingConversationID = nil
            }
        }
        .task(id: conversationID) {
            await store.loadMessages(for: conversationID)
        }
        .refreshable {
            await store.loadMessages(for: conversationID)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastID = messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private func errorBanner(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                Task {
                    await store.handleForegroundReturn()
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(.orange)
            Text("实时通道重连中，消息可能延迟到达")
                .font(.caption)
                .foregroundStyle(.orange)
            Spacer()
            Button("重连") {
                store.connectStream()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.08))
    }

    private var composerDock: some View {
        VStack(spacing: 8) {
            // Controls right inside the bottom composer dock (matching official Web UI)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(store.models) { model in
                            Button {
                                store.selectedModelID = model.id
                            } label: {
                                if model.id == store.selectedModelID {
                                    Label(model.displayName, systemImage: "checkmark")
                                } else {
                                    Text(model.displayName)
                                }
                            }
                        }
                    } label: {
                        ComposerChip(icon: "cpu", text: selectedModelCompactName)
                    }
                    .accessibilityLabel("选择模型")
                    .accessibilityIdentifier("composer-model-picker")

                    Menu {
                        ForEach(EffortLevel.allCases) { level in
                            Button {
                                store.selectedEffort = level
                            } label: {
                                if level == store.selectedEffort {
                                    Label(level.label, systemImage: "checkmark")
                                } else {
                                    Text(level.label)
                                }
                            }
                        }
                    } label: {
                        ComposerChip(icon: "brain.head.profile", text: store.selectedEffort.label)
                    }
                    .accessibilityLabel("调整思考强度")

                    Menu {
                        ForEach(AgentMode.allCases) { mode in
                            Button {
                                store.selectedMode = mode
                            } label: {
                                if mode == store.selectedMode {
                                    Label(mode.label, systemImage: "checkmark")
                                } else {
                                    Text(mode.label)
                                }
                            }
                        }
                    } label: {
                        ComposerChip(icon: "shield.lefthalf.filled", text: store.selectedMode.label)
                    }
                    .accessibilityLabel("切换执行模式")

                    Button {
                        store.autoSkipPermissions.toggle()
                    } label: {
                        ComposerChip(
                            icon: store.autoSkipPermissions ? "bolt.fill" : "hand.raised",
                            text: store.autoSkipPermissions ? "自动授权" : "保守确认",
                            highlighted: store.autoSkipPermissions
                        )
                    }
                    .buttonStyle(.plain)

                    if let ws = conversation?.workspaceDisplayName {
                        ComposerChip(icon: "folder", text: ws)
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button("继续完成当前任务") { appendQuickPrompt("请继续完成上面的任务") }
                    Button("检查 git status 与改动") { appendQuickPrompt("帮我看一下当前仓库的 git status 和改动") }
                    Button("解释问题并给出修复方案") { appendQuickPrompt("请分析刚才报错的根因并给出具体修改方案") }
                    Button("总结当前进展") { appendQuickPrompt("用中文简要总结目前的进度和下一步建议") }
                } label: {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 40)
                }
                .accessibilityLabel("常用快捷指令")

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

    private func appendQuickPrompt(_ preset: String) {
        if draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftPrompt = preset
        } else {
            draftPrompt += "\n" + preset
        }
        composerFocused = true
    }
}

private struct ComposerChip: View {
    let icon: String
    let text: String
    var highlighted: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            highlighted ? Color.accentColor.opacity(0.16) : Color(.secondarySystemFill),
            in: Capsule()
        )
        .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let liveStep: LiveStepStatus?
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
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("复制内容", systemImage: "doc.on.doc")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if message.model != nil || message.usage?.compactLabel != nil {
                        HStack(spacing: 6) {
                            if let model = message.model, !model.isEmpty {
                                Text(model)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let tok = message.usage?.compactLabel {
                                Text(tok)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

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
                        DisclosureGroup("工具调用 (\(message.toolCalls.count))", isExpanded: $showTools) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(message.toolCalls) { call in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Label(call.name, systemImage: "wrench.and.screwdriver")
                                            .font(.caption.monospaced().weight(.semibold))
                                        if !call.readableSummary.isEmpty {
                                            Text(call.readableSummary)
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

                    if let liveStep, message.status == "ACTIVE" {
                        liveExecutionBadge(liveStep)
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
                    } else if message.status == "ACTIVE" && liveStep == nil {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在连接模型思考...")
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
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground).opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
                .contextMenu {
                    if !message.content.isEmpty {
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("复制回复全文", systemImage: "doc.on.doc")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func liveExecutionBadge(_ step: LiveStepStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.toolName != nil ? "正在执行 \(step.toolName!)" : "步骤 \(step.stepIndex) · \(step.stepType)")
                    .font(.caption.weight(.medium))
                if let params = step.toolParameters, !params.isEmpty {
                    Text(params)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
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
