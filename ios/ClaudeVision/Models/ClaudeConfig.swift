import Foundation

struct ClaudeConfig {
    var gatewayHost: String = "MR-DULA-SOLUTIONS.local"
    var gatewayPort: Int = 18790
    var videoFrameInterval: TimeInterval = 1.0 // seconds between frame captures
    var videoJPEGQuality: CGFloat = 0.5
    var speechPauseThreshold: TimeInterval = 1.5 // seconds of silence before sending

    var baseURL: URL {
        URL(string: "http://\(gatewayHost):\(gatewayPort)")!
    }

    var chatURL: URL { baseURL.appendingPathComponent("chat") }
    var healthURL: URL { baseURL.appendingPathComponent("health") }
    var toolsURL: URL { baseURL.appendingPathComponent("tools") }
}
