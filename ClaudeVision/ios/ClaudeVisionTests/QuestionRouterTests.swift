import XCTest
@testable import ClaudeVision

/// Wake-word detection and text-vs-vision routing. Both run on-device and
/// gate what gets streamed off the phone, so the negative cases matter as
/// much as the positive ones.
final class QuestionRouterTests: XCTestCase {

    // MARK: - Wake word

    func testExtractsQuestionAfterWakePhrase() {
        XCTAssertEqual(
            QuestionRouter.questionAfterWakeWord(in: "hey claude what is this"),
            "what is this"
        )
    }

    func testStripsPunctuationAroundQuestion() {
        XCTAssertEqual(
            QuestionRouter.questionAfterWakeWord(in: "Hey Claude, what is this?"),
            "what is this"
        )
    }

    func testBareWakePhraseReturnsEmptyString() {
        // Empty string = "user said just the wake phrase, question still coming";
        // distinct from nil = "no wake phrase at all".
        XCTAssertEqual(QuestionRouter.questionAfterWakeWord(in: "hey claude"), "")
        XCTAssertEqual(QuestionRouter.questionAfterWakeWord(in: "Hey Claude."), "")
    }

    func testNoWakePhraseReturnsNil() {
        XCTAssertNil(QuestionRouter.questionAfterWakeWord(in: "what a lovely day"))
        XCTAssertNil(QuestionRouter.questionAfterWakeWord(in: "claude is a nice name"))
    }

    func testCommonASRMishearingsAreAccepted() {
        // Apple Speech rarely spells "Claude" right — each mishearing must route
        for phrase in [
            "hey claud turn it up",
            "hey clod turn it up",
            "hey clawed turn it up",
            "hey cloud turn it up",
            "hey clyde turn it up",
            "ok claude turn it up",
            "okay claude turn it up",
            "hay claude turn it up",
        ] {
            XCTAssertEqual(
                QuestionRouter.questionAfterWakeWord(in: phrase), "turn it up",
                "expected wake phrase to match in: \(phrase)"
            )
        }
    }

    func testWakePhraseRequiresBothWords() {
        XCTAssertNil(QuestionRouter.questionAfterWakeWord(in: "hey what's up"))
        XCTAssertNil(QuestionRouter.questionAfterWakeWord(in: "claude what's up"))
    }

    // MARK: - Vision routing

    func testLookAtPhraseTriggersVision() {
        XCTAssertTrue(QuestionRouter.needsVision("look at this label", mode: .general))
        XCTAssertTrue(QuestionRouter.needsVision("what am I looking at", mode: .general))
        XCTAssertTrue(QuestionRouter.needsVision("Look At the sign", mode: .general))
    }

    func testOtherPhrasingStaysTextOnly() {
        // Deliberately strict: the camera must never start by accident
        XCTAssertFalse(QuestionRouter.needsVision("what is this", mode: .general))
        XCTAssertFalse(QuestionRouter.needsVision("describe the scene", mode: .general))
        XCTAssertFalse(QuestionRouter.needsVision("check the outlook for tomorrow", mode: .general))
    }

    func testAlwaysVisionModesAttachAFrameRegardlessOfPhrasing() {
        for mode in [VisionMode.qrScanner, .documentReader, .inventory, .safetyInspector] {
            XCTAssertTrue(
                QuestionRouter.needsVision("what does it say", mode: mode),
                "\(mode.id) exists to use the camera — must always route to vision"
            )
        }
    }

    func testNonVisionModesDoNotForceVision() {
        XCTAssertFalse(QuestionRouter.needsVision("what part is this", mode: .mechanic))
        XCTAssertFalse(QuestionRouter.needsVision("is this taxed", mode: .vehicle))
    }

    // MARK: - Full wake → route flow

    func testWakeWordThenVisionRouting() throws {
        let question = try XCTUnwrap(
            QuestionRouter.questionAfterWakeWord(in: "hey claude look at this plant")
        )
        XCTAssertEqual(question, "look at this plant")
        XCTAssertTrue(QuestionRouter.needsVision(question, mode: .plants))
    }
}
