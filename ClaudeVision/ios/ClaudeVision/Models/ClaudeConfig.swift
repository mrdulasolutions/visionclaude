import Foundation

struct ClaudeConfig: Codable {
    var gatewayHost: String = "Davids-MacBook-Pro-3.local"
    var gatewayPort: Int = 18790
    var videoFrameInterval: TimeInterval = 1.0
    var videoJPEGQuality: Double = 0.85
    var speechPauseThreshold: TimeInterval = 1.5
    var elevenLabsAPIKey: String = ""
    var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel (default)
    var channelToken: String = ""
    var plantNetAPIKey: String = ""

    // Food mode health profile
    var foodAvoidUPF: Bool = false
    var foodWatchSalt: Bool = false
    var foodWatchSaturatedFat: Bool = false

    // Trip mode
    var googlePlacesAPIKey: String = ""
    var tripAdvisorAPIKey: String = ""

    // Vehicle mode
    var dvlaAPIKey: String = ""

    init() {}

    // Tolerant decoding so configs saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ClaudeConfig()
        gatewayHost = try c.decodeIfPresent(String.self, forKey: .gatewayHost) ?? defaults.gatewayHost
        gatewayPort = try c.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? defaults.gatewayPort
        videoFrameInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .videoFrameInterval) ?? defaults.videoFrameInterval
        videoJPEGQuality = try c.decodeIfPresent(Double.self, forKey: .videoJPEGQuality) ?? defaults.videoJPEGQuality
        speechPauseThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .speechPauseThreshold) ?? defaults.speechPauseThreshold
        elevenLabsAPIKey = try c.decodeIfPresent(String.self, forKey: .elevenLabsAPIKey) ?? defaults.elevenLabsAPIKey
        elevenLabsVoiceId = try c.decodeIfPresent(String.self, forKey: .elevenLabsVoiceId) ?? defaults.elevenLabsVoiceId
        channelToken = try c.decodeIfPresent(String.self, forKey: .channelToken) ?? defaults.channelToken
        plantNetAPIKey = try c.decodeIfPresent(String.self, forKey: .plantNetAPIKey) ?? defaults.plantNetAPIKey
        foodAvoidUPF = try c.decodeIfPresent(Bool.self, forKey: .foodAvoidUPF) ?? defaults.foodAvoidUPF
        foodWatchSalt = try c.decodeIfPresent(Bool.self, forKey: .foodWatchSalt) ?? defaults.foodWatchSalt
        foodWatchSaturatedFat = try c.decodeIfPresent(Bool.self, forKey: .foodWatchSaturatedFat) ?? defaults.foodWatchSaturatedFat
        googlePlacesAPIKey = try c.decodeIfPresent(String.self, forKey: .googlePlacesAPIKey) ?? defaults.googlePlacesAPIKey
        tripAdvisorAPIKey = try c.decodeIfPresent(String.self, forKey: .tripAdvisorAPIKey) ?? defaults.tripAdvisorAPIKey
        dvlaAPIKey = try c.decodeIfPresent(String.self, forKey: .dvlaAPIKey) ?? defaults.dvlaAPIKey
    }

    var baseURL: URL {
        URL(string: "http://\(gatewayHost):\(gatewayPort)")!
    }

    var wsURL: URL {
        var comps = URLComponents()
        comps.scheme = "ws"
        comps.host = gatewayHost
        comps.port = gatewayPort
        comps.path = "/ws"
        if !channelToken.isEmpty {
            comps.queryItems = [URLQueryItem(name: "token", value: channelToken)]
        }
        return comps.url!
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
