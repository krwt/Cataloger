import SwiftUI

@main
struct CatalogerApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    /// Guards against refreshing on the very first `.active` transition,
    /// which arrives at launch alongside `bootstrap()` — without this every
    /// cold launch would fire two concurrent full fetches.
    @State private var hasBootstrapped = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .task {
                    await store.bootstrap()
                    hasBootstrapped = true
                }
                // Nothing consumes the CloudKit silent pushes yet, so
                // returning to the app is the practical moment to pick up
                // another device's changes. Cheap, no entitlements needed.
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active, hasBootstrapped else { return }
                    Task { await store.refreshOnForeground() }
                }
        }
    }
}
