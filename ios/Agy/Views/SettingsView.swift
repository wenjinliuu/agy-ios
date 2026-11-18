import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var rawURL: String = ""
    @State private var rawToken: String = ""
    @State private var isTesting: Bool = false
    @State private var statusMessage: String?
    @State private var isError: Bool = false

    var body: some View {
        NavigationStack {
            Form {
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
                }

                Section {
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
                    Text("地址支持填写 Cloudflare Worker（*.workers.dev）或局域网调试地址；凭证加密保存在本机钥匙串。")
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
            .navigationTitle("服务器设置")
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
