import Foundation

/// Decides whether a finalised utterance is a question that wants an answer.
/// Runs entirely on-device; in Quiz mode, utterances that fail this check are
/// discarded without ever being sent anywhere. Tuned for precision over
/// recall — better to miss a mumble than to blurt answers at dinner
/// conversation.
enum QuestionDetector {

    private static let whWords: Set<String> = [
        "what", "whats", "who", "whos", "whose", "whom", "when", "where",
        "wheres", "which", "why", "how", "hows"
    ]

    /// Auxiliary-verb starts ("is the…", "did anyone…", "can you…").
    private static let auxWords: Set<String> = [
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
        "will", "would", "should", "shall", "has", "have", "had"
    ]

    /// Quiz-host imperatives ("name the…", "spell…").
    private static let imperatives: Set<String> = ["name", "spell"]

    /// Leading fillers stripped before testing ("and what year was that?").
    private static let fillers: Set<String> = [
        "and", "so", "but", "ok", "okay", "right", "um", "uh", "er", "hey",
        "now", "then", "claude", "alright", "question"
    ]

    private static let quizPhrases = [
        "true or false", "for ten points", "for 10 points", "next question",
        "bonus question", "your starter"
    ]

    static func isLikelyQuestion(_ utterance: String) -> Bool {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard !lowered.isEmpty else { return false }

        if quizPhrases.contains(where: { lowered.contains($0) }) { return true }

        var tokens = lowered
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "'", with: "") }

        // ASR sometimes punctuates — trust an explicit question mark.
        if trimmed.hasSuffix("?"), !tokens.isEmpty { return true }

        // Bounds: a lone word is a mumble, 40+ words is a monologue.
        guard tokens.count >= 3, tokens.count <= 40 else { return false }

        while let first = tokens.first, fillers.contains(first) {
            tokens.removeFirst()
        }
        guard let first = tokens.first else { return false }

        return whWords.contains(first) || auxWords.contains(first) || imperatives.contains(first)
    }
}
