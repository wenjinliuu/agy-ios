import SwiftUI

struct ConversationListView: View {
    @Bindable var store: AppStore
    @Binding var showingSettings: Bool
    @Binding var showingNewSession: Bool

    @State private var filterWorkspace: String?
    @State private var onlyRunning: Bool = false
    @State private var renamingConversation: ConversationSummary?
    @State private var renameDraft: String = ""

    private var workspaceNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for conv in store.conversations {
            let name = conv.workspaceDisplayName
            if !seen.contains(name) {
                seen.insert(name)
                result.append(name)
            }
        }
        return result
    }

    private var filteredConversations: [ConversationSummary] {
        store.conversations.filter { conv in
            if onlyRunning && !conv.isRunning && store.activeStreamingRuns[conv.id] == nil {
                return false
            }
            if let ws = filterWorkspace, conv.workspaceDisplayName != ws {
                return false
            }
            return true
        }
    }

    var body: some View {
        List {
            if !store.isConfigured {
                onboardingSection
            } else {
                statusBannerSection
            }

            if !store.conversations.isEmpty {
                filterSection

                Section("对话记录 (\(filteredConversations.count))") {
                    ForEach(filteredConversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ConversationRow(
                                conversation: conversation,
                                isLiveRunning: conversation.isRunning || store.activeStreamingRuns[conversation.id] != nil
                            )
                        }
                        .accessibilityIdentifier("conversation-row-\(conversation.id)")
                        .contextMenu {
                            Button {
                                renameDraft = conversation.title
                                renamingConversation = conversation
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button {
                                UIPasteboard.general.string = conversation.id
                            } label: {
                                Label("复制会话 ID", systemImage: "doc.on.doc")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                renameDraft = conversation.title
                                renamingConversation = conversation
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            } else if store.isConfigured && !store.isLoadingConversations {
                ContentUnavailableView(
                    "暂无对话记录",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("点击右上角发起新指令，或下拉刷新同步 VPS 历史记录。")
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Antigravity")
        .searchable(text: $store.searchQuery, prompt: "搜索标题、内容或工作区")
        .onSubmit(of: .search) {
            Task { await store.refreshDashboard() }
        }
        .onChange(of: store.searchQuery) { _, newValue in
            if newValue.isEmpty && store.isConfigured {
                Task { await store.refreshDashboard() }
            }
        }
        .refreshable {
            await store.refreshDashboard()
        }
        .alert("重命名对话", isPresented: Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        )) {
            TextField("输入新标题", text: $renameDraft)
            Button("取消", role: .cancel) { renamingConversation = nil }
            Button("保存") {
                guard let target = renamingConversation else { return }
                let newTitle = renameDraft
                renamingConversation = nil
                Task { try? await store.renameConversation(id: target.id, title: newTitle) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("设置与控制台")
                .accessibilityIdentifier("open-settings-button")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewSession = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(!store.isConfigured)
                .accessibilityLabel("新建对话")
                .accessibilityIdentifier("new-session-button")
            }
        }
    }

    private var onboardingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("连接到你的 VPS", systemImage: "server.rack")
                    .font(.headline)
                Text("填入 Cloudflare Worker（*.workers.dev）地址和访问密钥，即可直接控制 VPS 上的 agy CLI，并与网页端共享同一套历史记录。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("配置连接") {
                        showingSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding-connect-button")

                    Button("浏览演示") {
                        Task { await store.enableDemoMode() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-demo-button")
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var statusBannerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(store.bridgeOnline ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.isDemoMode ? "演示模式（本地模拟）" : (store.bridgeOnline ? "VPS Bridge 在线" : "正在重连 Bridge..."))
                            .font(.subheadline.weight(.medium))
                        if let health = store.healthInfo {
                            Text("\(health.hostname) · agy \(health.agyVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if store.isLoadingConversations {
                        ProgressView()
                    } else if !store.bridgeOnline {
                        Button("重连") {
                            Task { await store.handleForegroundReturn() }
                        }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                    }
                }

                if let err = store.connectionError, !err.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var filterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: "全部",
                        selected: !onlyRunning && filterWorkspace == nil
                    ) {
                        onlyRunning = false
                        filterWorkspace = nil
                    }

                    FilterChip(
                        title: "进行中",
                        selected: onlyRunning
                    ) {
                        onlyRunning.toggle()
                    }

                    ForEach(workspaceNames, id: \.self) { ws in
                        FilterChip(
                            title: ws,
                            selected: filterWorkspace == ws
                        ) {
                            filterWorkspace = (filterWorkspace == ws) ? nil : ws
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary
    let isLiveRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                if isLiveRunning {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                }
                Text(conversation.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(conversation.stepCount) 步")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !conversation.preview.isEmpty {
                Text(conversation.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Label(conversation.workspaceDisplayName, systemImage: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !conversation.lastModifiedAt.isEmpty {
                    Text(Self.shortTimestamp(conversation.lastModifiedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private static func shortTimestamp(_ raw: String) -> String {
        String(raw.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}
