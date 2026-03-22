import Foundation

struct ClaudeConfig: Codable {
    var gatewayHost: String = "MR-DULA-SOLUTIONS.local"
    var gatewayPort: Int = 18790
    var videoFrameInterval: TimeInterval = 1.0
    var videoJPEGQuality: Double = 0.85
    var speechPauseThreshold: TimeInterval = 1.5
    var elevenLabsAPIKey: String = ""
    var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel (default)

    var baseURL: URL {
        URL(string: "http://\(gatewayHost):\(gatewayPort)")!
    }

    var chatURL: URL { baseURL.appendingPathComponent("chat") }
    var healthURL: URL { baseURL.appendingPathComponent("health") }
    var toolsURL: URL { baseURL.appendingPathComponent("tools") }

    // MARK: - Persistence

    private static let storageKey = "ClaudeConfig"

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    static func load() -> ClaudeConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else {
            return ClaudeConfig()
        }
        return config
    }
}
