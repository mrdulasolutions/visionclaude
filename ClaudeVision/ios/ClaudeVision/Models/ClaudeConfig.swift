import Foundation

struct ClaudeConfig: Codable {
    var gatewayHost: String = "Davids-MacBook-Air.local"
    var gatewayPort: Int = 18790
    var videoFrameInterval: TimeInterval = 1.0
    var videoJPEGQuality: Double = 0.85
    var speechPauseThreshold: TimeInterval = 1.0
    var elevenLabsAPIKey: String = ""
    var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel (default)
    var channelToken: String = ""
    var wakeWordEnabled: Bool = true      // only send speech addressed with "hey claude"
    var onDemandCamera: Bool = true       // stream video only when a question needs vision
    var cameraIdleTimeout: TimeInterval = 30  // seconds before an on-demand stream shuts off
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

    // Decode each field with a fallback so configs saved by older builds (missing
    // newer keys) don't fail wholesale — a failed decode wipes all user settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClaudeConfig()
        gatewayHost = (try? c.decode(String.self, forKey: .gatewayHost)) ?? d.gatewayHost
        gatewayPort = (try? c.decode(Int.self, forKey: .gatewayPort)) ?? d.gatewayPort
        videoFrameInterval = (try? c.decode(TimeInterval.self, forKey: .videoFrameInterval)) ?? d.videoFrameInterval
        videoJPEGQuality = (try? c.decode(Double.self, forKey: .videoJPEGQuality)) ?? d.videoJPEGQuality
        speechPauseThreshold = (try? c.decode(TimeInterval.self, forKey: .speechPauseThreshold)) ?? d.speechPauseThreshold
        elevenLabsAPIKey = (try? c.decode(String.self, forKey: .elevenLabsAPIKey)) ?? d.elevenLabsAPIKey
        elevenLabsVoiceId = (try? c.decode(String.self, forKey: .elevenLabsVoiceId)) ?? d.elevenLabsVoiceId
        channelToken = (try? c.decode(String.self, forKey: .channelToken)) ?? d.channelToken
        wakeWordEnabled = (try? c.decode(Bool.self, forKey: .wakeWordEnabled)) ?? d.wakeWordEnabled
        onDemandCamera = (try? c.decode(Bool.self, forKey: .onDemandCamera)) ?? d.onDemandCamera
        cameraIdleTimeout = (try? c.decode(TimeInterval.self, forKey: .cameraIdleTimeout)) ?? d.cameraIdleTimeout
        plantNetAPIKey = (try? c.decode(String.self, forKey: .plantNetAPIKey)) ?? d.plantNetAPIKey
        foodAvoidUPF = (try? c.decode(Bool.self, forKey: .foodAvoidUPF)) ?? d.foodAvoidUPF
        foodWatchSalt = (try? c.decode(Bool.self, forKey: .foodWatchSalt)) ?? d.foodWatchSalt
        foodWatchSaturatedFat = (try? c.decode(Bool.self, forKey: .foodWatchSaturatedFat)) ?? d.foodWatchSaturatedFat
        googlePlacesAPIKey = (try? c.decode(String.self, forKey: .googlePlacesAPIKey)) ?? d.googlePlacesAPIKey
        tripAdvisorAPIKey = (try? c.decode(String.self, forKey: .tripAdvisorAPIKey)) ?? d.tripAdvisorAPIKey
        dvlaAPIKey = (try? c.decode(String.self, forKey: .dvlaAPIKey)) ?? d.dvlaAPIKey
    }

    private enum CodingKeys: String, CodingKey {
        case gatewayHost, gatewayPort, videoFrameInterval, videoJPEGQuality
        case speechPauseThreshold, elevenLabsAPIKey, elevenLabsVoiceId, channelToken
        case wakeWordEnabled, onDemandCamera, cameraIdleTimeout
        case plantNetAPIKey, foodAvoidUPF, foodWatchSalt, foodWatchSaturatedFat
        case googlePlacesAPIKey, tripAdvisorAPIKey, dvlaAPIKey
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
              var config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) else {
            return ClaudeConfig()
        }
        // One-time migration (2026-07): default pause threshold dropped 1.5 → 1.0
        // for snappier answers. Configs saved under the old default carry 1.5
        // forward, so nudge them once; after that the user's slider choice wins.
        let migrationKey = "ClaudeConfig.pauseThreshold1sMigration"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            if config.speechPauseThreshold == 1.5 {
                config.speechPauseThreshold = 1.0
                config.save()
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
        return config
    }
}
