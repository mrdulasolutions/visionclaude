import Foundation

struct ClaudeConfig {
    var gatewayHost: String = "MR-DULA-SOLUTIONS.local"
    var gatewayPort: Int = 18790
    var videoFrameInterval: TimeInterval = 1.0
    var videoJPEGQuality: CGFloat = 0.5
    var speechPauseThreshold: TimeInterval = 1.5
    var elevenLabsAPIKey: String = "" // ElevenLabs TTS API key
    var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel (default)

    var baseURL: URL {
        URL(string: "http://\(gatewayHost):\(gatewayPort)")!
    }

    var chatURL: URL { baseURL.appendingPathComponent("chat") }
    var healthURL: URL { baseURL.appendingPathComponent("health") }
    var toolsURL: URL { baseURL.appendingPathComponent("tools") }
}
