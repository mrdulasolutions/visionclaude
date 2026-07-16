import XCTest
@testable import ClaudeVision

@MainActor
final class ModeManagerTests: XCTestCase {

    private let persistedKeys = [
        "VisionClaude_CustomModes",
        "VisionClaude_HiddenBuiltInModes",
        "VisionClaude_ActiveModeId",
    ]

    override func setUp() {
        super.setUp()
        persistedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        persistedKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Defaults

    func testStartsWithAllBuiltInModesAndGeneralActive() {
        let manager = ModeManager()
        XCTAssertEqual(manager.allModes.count, VisionMode.builtInModes.count)
        XCTAssertEqual(manager.activeMode, VisionMode.general)
        XCTAssertEqual(manager.visibleModes.count, VisionMode.builtInModes.count)
    }

    // MARK: - Voice mode switching

    func testExactModeNameSwitches() {
        let manager = ModeManager()
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "plumber mode")?.id, "plumber")
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "switch to music mode")?.id, "music")
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "go to quiz mode")?.id, "quiz")
    }

    func testMultiWordModeNameSwitches() {
        let manager = ModeManager()
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "qr scanner mode")?.id, "qr_scanner")
    }

    func testMishearingStillMatches() {
        // "plumer" is one edit away from "plumber" — must still switch
        let manager = ModeManager()
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "plumer mode")?.id, "plumber")
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "mechanik mode")?.id, "mechanic")
    }

    func testFluxAddressedModeSwitches() {
        // "Flux mode plants" / "Aelita Flux mode plants" — the assistant's
        // name tokens are stripped as filler so only the mode name remains
        let manager = ModeManager()
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "flux mode plants")?.id, "plants")
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "aelita flux mode plants")?.id, "plants")
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "flex mode vehicle")?.id, "vehicle",
                       "'flex' is a common mishearing of 'flux'")
    }

    func testUtteranceWithoutModeKeywordIsIgnored() {
        let manager = ModeManager()
        XCTAssertNil(manager.mode(matchingVoiceCommand: "plumber"))
        XCTAssertNil(manager.mode(matchingVoiceCommand: "call the plumber tomorrow"))
    }

    func testLongUtteranceMentioningAModeIsNotHijacked() {
        let manager = ModeManager()
        XCTAssertNil(manager.mode(matchingVoiceCommand: "what mode is best for checking food labels at the shop"))
    }

    func testUnknownModeNameReturnsNil() {
        let manager = ModeManager()
        XCTAssertNil(manager.mode(matchingVoiceCommand: "banana mode"))
    }

    func testFillerOnlyCommandReturnsNil() {
        let manager = ModeManager()
        XCTAssertNil(manager.mode(matchingVoiceCommand: "switch mode please"))
    }

    // MARK: - Custom modes

    func testAddCustomModeAppendsAndPersists() {
        let manager = ModeManager()
        manager.addCustomMode(
            name: "Birdwatcher", icon: "bird.fill", color: "#00AAFF",
            prompt: "Identify birds.", quickActions: ["What bird is that?"]
        )
        let added = manager.allModes.last
        XCTAssertEqual(added?.name, "Birdwatcher")
        XCTAssertEqual(added?.isBuiltIn, false)
        XCTAssertTrue(added?.id.hasPrefix("custom_") ?? false)

        // A fresh manager reloads it from UserDefaults
        let reloaded = ModeManager()
        XCTAssertTrue(reloaded.allModes.contains { $0.name == "Birdwatcher" })
    }

    func testCustomModeIsVoiceSwitchable() {
        let manager = ModeManager()
        manager.addCustomMode(
            name: "Birdwatcher", icon: "bird.fill", color: "#00AAFF",
            prompt: "Identify birds.", quickActions: []
        )
        XCTAssertEqual(manager.mode(matchingVoiceCommand: "birdwatcher mode")?.name, "Birdwatcher")
    }

    func testDeleteCustomModeFallsBackToGeneral() {
        let manager = ModeManager()
        manager.addCustomMode(
            name: "Birdwatcher", icon: "bird.fill", color: "#00AAFF",
            prompt: "Identify birds.", quickActions: []
        )
        let custom = manager.allModes.last!
        manager.setActiveMode(custom)
        XCTAssertEqual(manager.activeMode.id, custom.id)

        manager.deleteCustomMode(id: custom.id)
        XCTAssertFalse(manager.allModes.contains { $0.id == custom.id })
        XCTAssertEqual(manager.activeMode, VisionMode.general)
    }

    func testDeleteCannotRemoveBuiltInMode() {
        let manager = ModeManager()
        manager.deleteCustomMode(id: "general")
        XCTAssertTrue(manager.allModes.contains { $0.id == "general" })
    }

    // MARK: - Visibility & active-mode persistence

    func testHidingABuiltInModeRemovesItFromSelector() {
        let manager = ModeManager()
        manager.toggleBuiltInModeVisibility(id: "hvac")
        XCTAssertFalse(manager.isBuiltInModeVisible("hvac"))
        XCTAssertFalse(manager.visibleModes.contains { $0.id == "hvac" })

        manager.toggleBuiltInModeVisibility(id: "hvac")
        XCTAssertTrue(manager.visibleModes.contains { $0.id == "hvac" })
    }

    func testActiveModePersistsAcrossInstances() {
        let manager = ModeManager()
        manager.setActiveMode(VisionMode.food)
        XCTAssertEqual(ModeManager().activeMode.id, "food")
    }
}
