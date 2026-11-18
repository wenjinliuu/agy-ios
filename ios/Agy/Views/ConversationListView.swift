import SwiftUI

struct ConversationListView: View {
    @Bindable var store: AppStore
    @Binding var showingSettings: Bool
    @Binding var showingNewSession: Bool

    var body: some View {
        List {
            if !store.isConfigured {
                onboardingSection
            } else {
                statusBannerSection
            }

            if !store.conversations.isEmpty {
                Section("最近对话") {
                    ForEach(store.conversations) { conversation in
                        NavigationLink(value: conversation.id) {
                            ConversationRow(conversation: conversation)
                        }
                        .accessibilityIdentifier("conversation-row-\(conversation.id)")
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("服务器设置")
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
            HStack(spacing: 10) {
                Circle()
                    .fill(store.bridgeOnline ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isDemoMode ? "演示模式（本地模拟）" : (store.bridgeOnline ? "VPS Bridge 在线" : "等待 Bridge 重连"))
                        .font(.subheadline.weight(.medium))
                    if let health = store.healthInfo {
                        Text("\(health.hostname) · agy \(health.agyVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let err = store.connectionError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if store.isLoadingConversations {
                    ProgressView()
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                if conversation.isRunning {
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
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private static func shortTimestamp(_ raw: String) -> String {
        String(raw.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}
