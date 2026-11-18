import SwiftUI

struct RootView: View {
    @Bindable var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigationPath: [String] = []
    @State private var showingSettings = false
    @State private var showingNewSession = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ConversationListView(
                store: store,
                showingSettings: $showingSettings,
                showingNewSession: $showingNewSession
            )
            .navigationDestination(for: String.self) { conversationID in
                ChatView(store: store, conversationID: conversationID)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $showingNewSession) {
            NewSessionSheet(store: store)
        }
        .task {
            if store.isConfigured {
                store.connectStream()
                await store.refreshDashboard()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.handleForegroundReturn() }
            }
        }
        .onChange(of: store.selectedConversationID) { _, newID in
            guard let newID else { return }
            if navigationPath.last != newID {
                navigationPath.append(newID)
            }
            store.selectedConversationID = nil
        }
    }
}
