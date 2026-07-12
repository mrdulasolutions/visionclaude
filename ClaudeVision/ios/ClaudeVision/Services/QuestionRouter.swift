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

    /// Multi-word phrases that reference the camera view.
    private static let visionPhrases: [String] = [
        "in front of me", "do you see", "can you see", "what do you see",
        "what is that", "what's that", "look at that", "read that",
        "is that", "on the screen", "over here", "right here",
        "am i looking", "what am i", "take a look", "check this", "check that"
    ]

    /// Single words (word-boundary matched) that almost always mean "use your eyes".
    private static let visionWords: [String] = [
        "this", "these", "those", "here", "see", "look", "looking", "watch",
        "read", "describe", "identify", "scan", "count", "color", "colour",
        "wearing", "holding", "screen", "sign", "label", "written", "front",
        "picture", "photo", "camera"
    ]

    private static let visionWordPattern: NSRegularExpression = {
        let alternation = visionWords.joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\b(?:\(alternation))\\b", options: [.caseInsensitive])
    }()

    /// True when answering `text` likely requires seeing a camera frame.
    /// Biased toward vision: a false positive costs one JPEG, a false negative
    /// leaves Claude blind to the thing the user is pointing at.
    static func needsVision(_ text: String, mode: VisionMode) -> Bool {
        if alwaysVisionModes.contains(mode.id) { return true }
        let lower = text.lowercased()
        if visionPhrases.contains(where: { lower.contains($0) }) { return true }
        let range = NSRange(lower.startIndex..., in: lower)
        return visionWordPattern.firstMatch(in: lower, options: [], range: range) != nil
    }
}
