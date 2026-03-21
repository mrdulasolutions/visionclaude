import SwiftUI
import MWDATCore

@main
struct ClaudeVisionApp: App {
    init() {
        do {
            try Wearables.configure()
            print("[App] DAT SDK configured")
        } catch {
            print("[App] DAT SDK configuration failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Handle Meta AI callback after registration/permission
                    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
                    else {
                        return // Not a DAT SDK callback
                    }

                    print("[App] Received DAT SDK callback: \(url)")
                    Task {
                        do {
                            _ = try await Wearables.shared.handleUrl(url)
                            print("[App] DAT SDK URL handled successfully")
                        } catch {
                            print("[App] DAT SDK URL error: \(error)")
                        }
                    }
                }
        }
    }
}
