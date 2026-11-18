import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var rawURL: String = ""
    @State private var rawToken: String = ""
    @State private var isTesting: Bool = false
    @State private var statusMessage: String?
    @State private var isError: Bool = false
    @State private var mcpBusyName: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("默认运行偏好") {
                    Picker("默认模型", selection: $store.selectedModelID) {
                        ForEach(store.models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }

                    Picker("默认思考强度", selection: $store.selectedEffort) {
                        ForEach(EffortLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }

                    Picker("默认执行模式", selection: $store.selectedMode) {
                        ForEach(AgentMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    Toggle("自动批准工具调用", isOn: $store.autoSkipPermissions)
                }

                if let overview = store.configOverview {
                    Section {
                        if overview.mcpServers.isEmpty {
                            Text("未检测到 MCP 服务器")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(overview.mcpServers) { mcp in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mcp.name)
                                            .font(.body.weight(.medium))
                                        Text("\(mcp.transport) · \(mcp.target)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if mcpBusyName == mcp.name {
                                        ProgressView()
                                    } else {
                                        Toggle("", isOn: Binding(
                                            get: { mcp.enabled },
                                            set: { newValue in
                                                Task {
                                                    mcpBusyName = mcp.name
                                                    defer { mcpBusyName = nil }
                                                    try? await store.toggleMcpServer(name: mcp.name, enabled: newValue)
                                                }
                                            }
                                        ))
                                        .labelsHidden()
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("VPS MCP 服务器")
                            Spacer()
                            Button("刷新") {
                                Task { await store.refreshConfigOverview() }
                            }
                            .font(.caption)
                        }
                    }

                    if !overview.hooks.isEmpty {
                        Section("生命周期 Hooks") {
                            ForEach(overview.hooks) { hook in
                                HStack {
                                    Text(hook.name)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(hook.event)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !overview.skills.isEmpty {
                        Section("已装技能 (Skills)") {
                            Text(overview.skills.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !overview.activeConversationIds.isEmpty {
                        Section("运行中会话") {
                            ForEach(overview.activeConversationIds, id: \.self) { cid in
                                HStack {
                                    Text(cid)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                    Spacer()
                                    Button("停止", role: .destructive) {
                                        Task {
                                            await store.abortRun(conversationId: cid)
                                            await store.refreshConfigOverview()
                                        }
                                    }
                                    .font(.caption)
                                }
                            }
                        }
                    }
                }

                Section("服务器连接") {
                    TextField("https://agy-bridge.your-subdomain.workers.dev", text: $rawURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings-url-input")

                    SecureField("访问密钥（Bearer Token）", text: $rawToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings-token-input")

                    Button {
                        Task { await verifyAndSave() }
                    } label: {
                        HStack {
                            Text(isTesting ? "正在验证连接..." : "测试并保存")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                    .accessibilityIdentifier("settings-save-button")
                } footer: {
                    Text("支持 Cloudflare Worker（*.workers.dev）或局域网调试地址；密钥保存在本机钥匙串。")
                }

                if let statusMessage {
                    Section("连接结果") {
                        Text(statusMessage)
                            .font(.subheadline)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }

                if store.isConfigured {
                    Section {
                        Button("清除连接配置", role: .destructive) {
                            store.clearCredentials()
                            rawURL = ""
                            rawToken = ""
                            statusMessage = nil
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("设置与控制台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                rawURL = store.isDemoMode ? "" : store.serverURLString
                rawToken = store.isDemoMode ? "" : store.authToken
            }
            .task {
                if store.isConfigured {
                    await store.refreshConfigOverview()
                }
            }
        }
    }

    private func verifyAndSave() async {
        isTesting = true
        defer { isTesting = false }

        do {
            let health = try await store.saveSettings(rawURL: rawURL, rawToken: rawToken)
            isError = false
            statusMessage = "已连接 \(health.hostname)（agy \(health.agyVersion)）"
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }
}
