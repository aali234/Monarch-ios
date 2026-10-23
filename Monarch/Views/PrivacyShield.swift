import SwiftUI
import UIKit

/// A separate window also covers Quick Look, the scanner, and presented sheets.
struct PrivacyShield: UIViewControllerRepresentable {
    let app: AppState
    let obscured: Bool
    let locked: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard obscured || locked else { coordinator.window?.isHidden = true; return }
            guard let scene = controller.view.window?.windowScene else { return }
            if coordinator.window == nil {
                let window = UIWindow(windowScene: scene)
                window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
                window.backgroundColor = UIColor(Palette.background)
                coordinator.window = window
            }
            coordinator.window?.rootViewController = UIHostingController(rootView: LockCover(app: app, obscured: obscured, locked: locked))
            // Do not steal the key window from Face ID or an OAuth browser session.
            coordinator.window?.isHidden = false
        }
    }
    final class Coordinator { var window: UIWindow? }
    private struct LockCover: View {
        let app: AppState
        let obscured: Bool
        let locked: Bool
        var body: some View {
            ZStack {
                Palette.background.ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "leaf.fill").font(.system(size: 44)).foregroundStyle(Palette.forest)
                    Text("A little peace of mind.").font(.system(.title2, design: .serif))
                    if locked && !obscured {
                        Button("Unlock your finances") { Task { await app.unlock() } }.buttonStyle(PrimaryButtonStyle()).padding(.horizontal, 40).disabled(app.isAuthenticating)
                        if let message = app.lockMessage { Text(message).font(.caption).foregroundStyle(Palette.secondary).multilineTextAlignment(.center).padding(.horizontal, 40) }
                    }
                }
            }
        }
    }
}
