import SwiftUI

struct NewSessionSheet: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var workspacePath: String = ""
    @State private var modelID: String = ""
    @State private var effort: EffortLevel = .medium
    @State private var mode: AgentMode = .auto

    var body: some View {
        NavigationStack {
            Form {
                Section("指令内容") {
                    TextField("输入你想让 agy 执行的任务...", text: $prompt, axis: .vertical)
                        .lineLimit(3 ... 8)
                        .accessibilityIdentifier("new-session-prompt")
                }

                Section("工作目录") {
                    TextField("/home/ubuntu/projects/...", text: $workspacePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("new-session-workspace")

                    if !store.workspaces.isEmpty {
                        ForEach(store.workspaces, id: \.self) { dir in
                            Button {
                                workspacePath = dir
                            } label: {
                                HStack {
                                    Text(dir)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if workspacePath == dir {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("模型与参数") {
                    Picker("模型", selection: $modelID) {
                        ForEach(store.models) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    Picker("思考强度", selection: $effort) {
                        ForEach(EffortLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    Picker("执行模式", selection: $mode) {
                        ForEach(AgentMode.allCases) { item in
                            Text(item.label).tag(item)
                        }
                    }
                }
            }
            .navigationTitle("新建对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") {
                        let text = prompt
                        let ws = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                        Task {
                            await store.sendPrompt(
                                text: text,
                                conversationId: nil,
                                workspace: ws.isEmpty ? nil : ws,
                                model: modelID,
                                effort: effort,
                                mode: mode
                            )
                        }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("start-new-session-button")
                }
            }
            .onAppear {
                modelID = store.selectedModelID
                effort = store.selectedEffort
                mode = store.selectedMode
                if workspacePath.isEmpty {
                    workspacePath = store.healthInfo?.defaultWorkspace ?? store.workspaces.first ?? ""
                }
            }
        }
    }
}
