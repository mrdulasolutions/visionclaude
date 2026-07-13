import XCTest
@testable import ClaudeVision

/// Quiz mode's on-device gate: only utterances that look like questions
/// leave the device. Tuned for precision, so these specs pin down both
/// what must pass and what must be discarded.
final class QuestionDetectorTests: XCTestCase {

    // MARK: - Questions that must be detected

    func testWhWordQuestions() {
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("what is the capital of Mongolia"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("who wrote War and Peace"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("where does the Nile start"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("how many moons does Jupiter have"))
    }

    func testContractionOfWhWordIsDetected() {
        // ASR often emits "what's" — the apostrophe is stripped before matching
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("what's the tallest mountain"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("who's on first base"))
    }

    func testAuxiliaryVerbQuestions() {
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("is the earth flat"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("did anyone win the lottery"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("can you name the planets"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("should we take the motorway"))
    }

    func testQuizHostImperatives() {
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("name the seven dwarfs"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("spell the word necessary"))
    }

    func testQuizPhrasesAlwaysPass() {
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("true or false the sun is a star"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("for ten points which country hosted the 1966 world cup"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("next question"))
    }

    func testLeadingFillersAreStripped() {
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("and what year was that"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("okay so who painted the Mona Lisa"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("claude what time is it in Tokyo"))
    }

    func testExplicitQuestionMarkIsTrusted() {
        // ASR punctuation beats the token heuristics — even a short utterance passes
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("Paris?"))
        XCTAssertTrue(QuestionDetector.isLikelyQuestion("The 1966 World Cup final was won by England?"))
    }

    // MARK: - Non-questions that must be discarded

    func testStatementsAreRejected() {
        XCTAssertFalse(QuestionDetector.isLikelyQuestion("the sky looks lovely today"))
        XCTAssertFalse(QuestionDetector.isLikelyQuestion("I think we should leave soon"))
    }

    func testEmptyAndWhitespaceAreRejected() {
        XCTAssertFalse(QuestionDetector.isLikelyQuestion(""))
        XCTAssertFalse(QuestionDetector.isLikelyQuestion("   \n "))
    }

    func testLoneWordMumbleIsRejected() {
        XCTAssertFalse(QuestionDetector.isLikelyQuestion("what"))
        XCTAssertFalse(QuestionDetector.isLikelyQuestion("hmm okay"))
    }

    func testLongMonologueIsRejected() {
        let monologue = Array(repeating: "what", count: 41).joined(separator: " ")
        XCTAssertFalse(QuestionDetector.isLikelyQuestion(monologue))
    }

    func testFillerOnlyUtteranceIsRejected() {
        XCTAssertFalse(QuestionDetector.isLikelyQuestion("okay so um right"))
    }
}
