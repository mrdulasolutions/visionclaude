import Foundation

/// On-device routing for spoken input: detects the "aelita" wake word and
/// decides whether answering a question requires a camera frame or just text.
/// Both checks run locally so nothing is streamed until the user actually asks.
enum QuestionRouter {

    // MARK: - Wake Phrase ("OK, Flux")

    /// The wake phrase is "OK, Flux" — an "ok"-style opener followed by
    /// anything Flux-shaped. Enumerating STT's renderings of "Flux" proved a
    /// losing game (Plex, Flocks, Flex, Leader-era worse), so the name match
    /// is fuzzy: a known rendering, or any short f-word within edit distance
    /// 2 of "flux". The "ok" anchor keeps false wakes rare.
    private static let okWords: Set<String> = ["ok", "okay", "okey", "kay", "hey"]
    private static let fluxWords: Set<String> = [
        "flux", "fluxx", "flex", "flexx", "plex", "plux", "phlux",
        "flocks", "flax", "fox", "lux", "flix", "fluke", "flus", "bucks"
    ]

    private static func isFluxLike(_ word: String) -> Bool {
        let w = word.lowercased()
        if fluxWords.contains(w) { return true }
        guard w.hasPrefix("f") || w.hasPrefix("p"), (3...6).contains(w.count) else { return false }
        return editDistance(w, "flux") <= 2
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Returns the question following the wake phrase, or nil when the utterance
    /// doesn't contain the wake phrase at all. An empty string means the user said
    /// just "OK, Flux" and the question is still coming.
    static func questionAfterWakeWord(in text: String) -> String? {
        // Walk word pairs; a match is okWord immediately followed by a
        // Flux-shaped word. Word enumeration skips punctuation, so
        // "Okay, Flux." parses the same as "okay flux".
        var words: [(String, Range<String.Index>)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .localized]) { sub, range, _, _ in
            if let sub { words.append((sub.lowercased(), range)) }
        }
        for i in 0..<max(0, words.count - 1) {
            if okWords.contains(words[i].0), isFluxLike(words[i + 1].0) {
                let after = text[words[i + 1].1.upperBound...]
                return after.trimmingCharacters(in: CharacterSet(charactersIn: " ,.?!:;-"))
            }
        }
        return nil
    }

    // MARK: - Vision Routing

    /// Modes whose whole point is the camera — always attach a frame.
    private static let alwaysVisionModes: Set<String> = [
        "qr_scanner", "document_reader", "inventory", "safety_inspector",
        "plants", "food", "books", "vehicle", "history"
    ]

    /// Explicit camera trigger: saying "look at" ("aelita, look at this label")
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
