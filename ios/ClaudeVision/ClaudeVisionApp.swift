import SwiftUI
import MWDATCore

@main
struct ClaudeVisionApp: App {
    init() {
        // Initialize Meta Wearables DAT SDK
        do {
            try Wearables.configure()
        } catch {
            print("[ClaudeVision] DAT SDK configuration failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Handle Meta AI app callback after registration
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
        }
    }
}
