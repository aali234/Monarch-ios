import SwiftUI
import SwiftData
import BackgroundTasks

@main struct MonarchApp: App {
    private let container: ModelContainer?
    private let startupError: String?
    init() {
        do {
            let store: ModelContainer
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                UserDefaults.standard.set(false, forKey: "faceIDEnabled")
                store = try ModelContainer(for: AppPersistence.schema, configurations: [ModelConfiguration(schema: AppPersistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
            } else { store = try AppPersistence.makeContainer() }
            try AppPersistence.seed(store.mainContext)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--screenshot-testing") {
                try ScreenshotFixtures.install(store.mainContext)
            }
            #endif
            container = store; startupError = nil
        } catch { container = nil; startupError = error.localizedDescription }
    }
    var body: some Scene {
        let sharedContainer = container
        return WindowGroup {
            if let container {
                AppHost(container: container).modelContainer(container)
            } else {
                ContentUnavailableView("Your ledger could not open", systemImage: "lock.doc", description: Text(startupError ?? "Unlock your device and reopen the app. Your data has not been reset."))
            }
        }
        .backgroundTask(.appRefresh(ReceiptSharedConfig.refreshTaskID)) {
            await ReceiptInbox.scheduleBackgroundRefresh()
            if let sharedContainer {
                let state = await AppState(container: sharedContainer)
                await state.receipts.foreground()
                await ShipmentTrackingService.refresh(app: state)
            }
        }
    }
}

private struct AppHost: View {
    @Environment(\.scenePhase) private var phase
    @State private var app: AppState
    init(container: ModelContainer) { _app = State(initialValue: AppState(container: container)) }
    var body: some View {
        RootView()
            .environment(app)
            .background(PrivacyShield(app: app, obscured: app.isObscured, locked: app.isLocked).frame(width: 0, height: 0))
            .tint(Palette.forest)
            .preferredColorScheme(.light)
            .onChange(of: phase) { _, value in
                switch value {
                case .background: app.background(); ReceiptInbox.scheduleBackgroundRefresh()
                case .inactive: app.isObscured = true
                case .active:
                    app.active()
                    if !app.isLocked { Task { await app.receipts.foreground(); await ShipmentTrackingService.refresh(app: app) } }
                @unknown default: break
                }
            }
            .task {
                if !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    do { try app.recoverPendingConnection() } catch { app.report(error) }
                }
                if app.isLocked { await app.unlock() }
                if !app.isLocked { await app.receipts.foreground(); await ShipmentTrackingService.refresh(app: app) }
            }
    }
}
