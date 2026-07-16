import XCTest
@testable import ClaudeVision

/// Config decoding must be tolerant: a failed decode silently wipes every
/// user setting, so configs written by older builds have to keep loading as
/// new fields (mode API keys, health profile) are added.
final class ClaudeConfigTests: XCTestCase {

    private let storageKey = "ClaudeConfig"
    private let migrationKey = "ClaudeConfig.pauseThreshold1sMigration"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: migrationKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: migrationKey)
        super.tearDown()
    }

    // MARK: - Tolerant decoding

    func testConfigFromOlderBuildDecodesWithDefaultsForNewFields() throws {
        // A config saved before the extension modes existed
        let legacy = """
        {"gatewayHost":"my-mac.local","gatewayPort":9999,"elevenLabsAPIKey":"el-key"}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ClaudeConfig.self, from: legacy)

        XCTAssertEqual(config.gatewayHost, "my-mac.local")
        XCTAssertEqual(config.gatewayPort, 9999)
        XCTAssertEqual(config.elevenLabsAPIKey, "el-key")
        // New fields fall back to defaults instead of failing the whole decode
        XCTAssertEqual(config.plantNetAPIKey, "")
        XCTAssertEqual(config.googlePlacesAPIKey, "")
        XCTAssertEqual(config.tripAdvisorAPIKey, "")
        XCTAssertFalse(config.foodAvoidUPF)
        XCTAssertTrue(config.wakeWordEnabled)
        XCTAssertTrue(config.onDemandCamera)
        XCTAssertEqual(config.cameraIdleTimeout, 30)
    }

    func testCorruptFieldFallsBackWithoutWipingTheRest() throws {
        let corrupt = """
        {"gatewayHost":"my-mac.local","gatewayPort":"not-a-number"}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ClaudeConfig.self, from: corrupt)
        XCTAssertEqual(config.gatewayHost, "my-mac.local", "good fields survive a bad sibling")
        XCTAssertEqual(config.gatewayPort, 18790, "bad field falls back to default")
    }

    func testExtensionFieldsRoundTrip() throws {
        var config = ClaudeConfig()
        config.plantNetAPIKey = "pn"
        config.googlePlacesAPIKey = "gp"
        config.tripAdvisorAPIKey = "ta"
        config.foodAvoidUPF = true
        config.foodWatchSalt = true
        config.foodWatchSaturatedFat = true

        let decoded = try JSONDecoder().decode(ClaudeConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded.plantNetAPIKey, "pn")
        XCTAssertEqual(decoded.googlePlacesAPIKey, "gp")
        XCTAssertEqual(decoded.tripAdvisorAPIKey, "ta")
        XCTAssertTrue(decoded.foodAvoidUPF)
        XCTAssertTrue(decoded.foodWatchSalt)
        XCTAssertTrue(decoded.foodWatchSaturatedFat)
    }

    // MARK: - URLs

    func testWsURLCarriesChannelToken() {
        var config = ClaudeConfig()
        config.gatewayHost = "example.local"
        config.channelToken = "secret"
        XCTAssertEqual(config.wsURL.absoluteString, "ws://example.local:18790/ws?token=secret")

        config.channelToken = ""
        XCTAssertEqual(config.wsURL.absoluteString, "ws://example.local:18790/ws")
    }

    // MARK: - Persistence & migration

    func testSaveLoadRoundTrip() {
        var config = ClaudeConfig()
        config.gatewayHost = "roundtrip.local"
        config.foodWatchSalt = true
        config.save()

        let loaded = ClaudeConfig.load()
        XCTAssertEqual(loaded.gatewayHost, "roundtrip.local")
        XCTAssertTrue(loaded.foodWatchSalt)
    }

    func testPauseThresholdMigratesFromOldDefaultOnce() {
        // A config saved under the old 1.5s default…
        var config = ClaudeConfig()
        config.speechPauseThreshold = 1.5
        config.save()

        // …is nudged to the new 1.0s default on first load…
        XCTAssertEqual(ClaudeConfig.load().speechPauseThreshold, 1.0)

        // …but a deliberate later choice of 1.5 sticks, because the
        // migration only ever runs once.
        config.speechPauseThreshold = 1.5
        config.save()
        XCTAssertEqual(ClaudeConfig.load().speechPauseThreshold, 1.5)
    }

    func testUserChosenThresholdIsNotMigrated() {
        var config = ClaudeConfig()
        config.speechPauseThreshold = 2.0
        config.save()
        XCTAssertEqual(ClaudeConfig.load().speechPauseThreshold, 2.0)
    }
}
