import SwiftUI

@main
struct AgyApp: App {
    @State private var store: AppStore

    init() {
        let isDemo = ProcessInfo.processInfo.arguments.contains("--demo-data")
        _store = State(initialValue: AppStore(demoMode: isDemo))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
