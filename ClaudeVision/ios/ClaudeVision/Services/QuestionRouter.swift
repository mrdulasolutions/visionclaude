import Foundation

/// On-device routing for spoken input: detects the "hey claude" wake phrase and
/// decides whether answering a question requires a camera frame or just text.
/// Both checks run locally so nothing is streamed until the user actually asks.
enum QuestionRouter {

    // MARK: - Wake Word ("hey claude")

    /// Apple Speech rarely spells "Claude" correctly, so match common mishearings.
    private static let wakePattern = try! NSRegularExpression(
        pattern: "\\b(?:hey|hay|hei|okay|ok)[\\s,]+(?:claude|claud|clod|clawed|cloud|clyde|klaud|claw)\\b",
        options: [.caseInsensitive]
    )

    /// Returns the question following the wake phrase, or nil when the utterance
    /// doesn't contain the wake phrase at all. An empty string means the user said
    /// just "hey claude" and the question is still coming.
    static func questionAfterWakeWord(in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = wakePattern.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        let after = text[matchRange.upperBound...]
        return after.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!:;-"))
    }

    // MARK: - Vision Routing

    /// Modes whose whole point is the camera — always attach a frame.
    private static let alwaysVisionModes: Set<String> = [
        "qr_scanner", "document_reader", "inventory", "safety_inspector"
    ]

    /// Explicit camera trigger: saying "look at" ("hey claude, look at this label")
    /// is what routes a question to vision. Any other phrasing is answered from
    /// the spoken words alone, so the camera never starts by accident.
    private static let lookAtPattern = try! NSRegularExpression(
        pattern: "\\blook(?:ing)?\\s+at\\b",
        options: [.caseInsensitive]
    )

    /// True when answering `text` requires a camera frame. Deliberately strict:
    /// only the explicit "look at" phrase (or a mode that exists to use the
    /// camera) turns vision on — everything else stays text-only.
    static func needsVision(_ text: String, mode: VisionMode) -> Bool {
        if alwaysVisionModes.contains(mode.id) { return true }
        let range = NSRange(text.startIndex..., in: text)
        return lookAtPattern.firstMatch(in: text, options: [], range: range) != nil
    }
}
