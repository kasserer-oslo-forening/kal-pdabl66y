import SwiftUI
import EventKit

@main
struct GjorelisteApp: App {
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if store.loggedIn { MainView() } else { LoginView() }
            }
            .environmentObject(store)
            .task { if store.loggedIn { await store.load() } }
            .onChange(of: phase) { _, p in
                if p == .active, store.loggedIn { Task { await store.load() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
                store.scheduleSync()
            }
        }
    }
}
