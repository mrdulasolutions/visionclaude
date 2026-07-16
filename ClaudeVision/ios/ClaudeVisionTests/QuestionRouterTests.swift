import XCTest
@testable import ClaudeVision

/// Wake-word detection and text-vs-vision routing. Both run on-device and
/// gate what gets streamed off the phone, so the negative cases matter as
/// much as the positive ones.
final class QuestionRouterTests: XCTestCase {

    // MARK: - Wake word

    func testExtractsQuestionAfterWakePhrase() {
        XCTAssertEqual(
            QuestionRouter.questionAfterWakeWord(in: "aelita what is this"),
            "what is this"
        )
        // A leading "hey" is allowed but not required
        XCTAssertEqual(
            QuestionRouter.questionAfterWakeWord(in: "hey aelita what is this"),
            "what is this"
        )
    }

    func testStripsPunctuationAroundQuestion() {
        XCTAssertEqual(
            QuestionRouter.questionAfterWakeWord(in: "Aelita, what is this?"),
            "what is this"
        )
    }

    func testBareWakePhraseReturnsEmptyString() {
        // Empty string = "user said just the wake word, question still coming";
        // distinct from nil = "no wake word at all".
        XCTAssertEqual(QuestionRouter.questionAfterWakeWord(in: "aelita"), "")
        XCTAssertEqual(QuestionRouter.questionAfterWakeWord(in: "Hey Aelita."), "")
    }

    func testNoWakePhraseReturnsNil() {
        XCTAssertNil(QuestionRouter.questionAfterWakeWord(in: "what a lovely day"))
        XCTAssertNil(QuestionRouter.questionAfterWakeWord(in: "hey claude what is this"),
                     "the old wake phrase no longer wakes")
    }

    func testSurnameAndLiveMishearingsWake() {
        // "elite" is how Apple Speech heard "Aelita" in live use; "flux" is
        // the surname and works as a spoken name too.
        XCTAssertEqual(QuestionRouter.questionAfterWakeWord(in: "elite what is this"), "what is this")
        XCTAssertEqual(QuestionRouter.questionAfterWakeWord(in: "flux what is this"), "what is this")
    }

    func testCommonASRMishearingsAreAccepted() {
        // Apple Speech rarely spells "Aelita" right — each mishearing must route
        for phrase in [
            "alita turn it up",
            "a lita turn it up",
            "aleta turn it up",
            "alida turn it up",
            "alito turn it up",
            "elita turn it up",
            "hey alita turn it up",
            "okay aelita turn it up",
        ] {
            XCTAssertEqual(
                QuestionRouter.questionAfterWakeWord(in: phrase), "turn it up",
                "expected wake word to match in: \(phrase)"
            )
        }
    }

    func testHeyAloneDoesNotWake() {
        XCTAssertNil(QuestionRouter.questionAfterWakeWord(in: "hey what's up"))
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
        for mode in [VisionMode.qrScanner, .documentReader, .inventory, .safetyInspector,
                     .plants, .food, .books, .vehicle, .history] {
            XCTAssertTrue(
                QuestionRouter.needsVision("what does it say", mode: mode),
                "\(mode.id) exists to use the camera — must always route to vision"
            )
        }
    }

    func testNonVisionModesDoNotForceVision() {
        XCTAssertFalse(QuestionRouter.needsVision("what part is this", mode: .mechanic))
        XCTAssertFalse(QuestionRouter.needsVision("how do I bleed a radiator", mode: .plumber))
    }

    // MARK: - Full wake → route flow

    func testWakeWordThenVisionRouting() throws {
        let question = try XCTUnwrap(
            QuestionRouter.questionAfterWakeWord(in: "aelita look at this plant")
        )
        XCTAssertEqual(question, "look at this plant")
        XCTAssertTrue(QuestionRouter.needsVision(question, mode: .plants))
    }
}
