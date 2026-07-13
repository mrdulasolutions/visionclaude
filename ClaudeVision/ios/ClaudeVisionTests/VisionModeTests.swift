import XCTest
import SwiftUI
@testable import ClaudeVision

final class VisionModeTests: XCTestCase {

    func testBuiltInModeIdsAreUnique() {
        let ids = VisionMode.builtInModes.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate mode ids break selection and persistence")
    }

    func testEveryBuiltInModeIsFullyDefined() {
        for mode in VisionMode.builtInModes {
            XCTAssertFalse(mode.name.isEmpty, "\(mode.id) has no name")
            XCTAssertFalse(mode.icon.isEmpty, "\(mode.id) has no SF Symbol")
            XCTAssertFalse(mode.systemPrompt.isEmpty, "\(mode.id) has no system prompt")
            XCTAssertFalse(mode.quickActions.isEmpty, "\(mode.id) has no quick actions")
            XCTAssertTrue(mode.isBuiltIn)
        }
    }

    func testNewExtensionModesAreRegistered() {
        let ids = Set(VisionMode.builtInModes.map(\.id))
        for expected in ["plants", "music", "food", "trip", "books", "vehicle", "history", "quiz"] {
            XCTAssertTrue(ids.contains(expected), "extension mode \(expected) missing from builtInModes")
        }
    }

    func testEqualityIsById() {
        var renamed = VisionMode.general
        // Same id compares equal regardless of other fields
        XCTAssertEqual(renamed, VisionMode.general)
        renamed = VisionMode(
            id: "general", name: "Other", icon: "x", color: "#000000",
            systemPrompt: "p", quickActions: [], isBuiltIn: false
        )
        XCTAssertEqual(renamed, VisionMode.general)
        XCTAssertNotEqual(VisionMode.general, VisionMode.food)
    }

    func testSwiftColorParsesSixDigitHex() {
        let mode = VisionMode(
            id: "t", name: "T", icon: "x", color: "#FF0000",
            systemPrompt: "p", quickActions: [], isBuiltIn: false
        )
        XCTAssertEqual(mode.swiftColor, Color(red: 1, green: 0, blue: 0))
    }

    func testSwiftColorFallsBackToOrangeOnGarbage() {
        for bad in ["", "#FFF", "not-a-color", "#GGGGGG", "#FF00001"] {
            let mode = VisionMode(
                id: "t", name: "T", icon: "x", color: bad,
                systemPrompt: "p", quickActions: [], isBuiltIn: false
            )
            XCTAssertEqual(mode.swiftColor, .orange, "expected fallback for \(bad)")
        }
    }

    func testCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(VisionMode.food)
        let decoded = try JSONDecoder().decode(VisionMode.self, from: data)
        XCTAssertEqual(decoded.id, "food")
        XCTAssertEqual(decoded.systemPrompt, VisionMode.food.systemPrompt)
        XCTAssertEqual(decoded.quickActions, VisionMode.food.quickActions)
    }
}
