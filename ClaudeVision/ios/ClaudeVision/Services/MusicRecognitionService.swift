import Foundation
import ShazamKit

/// Identifies songs playing nearby using ShazamKit (Apple's Shazam catalog — no API key).
/// Uses the active microphone route, so with Meta glasses connected it hears
/// whatever the glasses hear.
final class MusicRecognitionService {

    struct Song {
        let title: String
        let artist: String
        let genres: [String]
        let appleMusicURL: URL?
        let webURL: URL?

        /// Compact summary suitable for injecting into a Claude prompt.
        var promptSummary: String {
            var lines = ["ShazamKit identified the song: \"\(title)\" by \(artist)."]
            if !genres.isEmpty {
                lines.append("Genres: \(genres.joined(separator: ", ")).")
            }
            if let appleMusicURL {
                lines.append("Apple Music: \(appleMusicURL.absoluteString)")
            }
            return lines.joined(separator: " ")
        }
    }

    enum RecognitionOutcome {
        case match(Song)
        case noMatch
        case failed(String)
    }

    private var activeSession: SHManagedSession?
    private var timedOut = false

    /// Listens to the mic and tries to match against the Shazam catalog.
    /// Resolves when ShazamKit finds a match, decides there is none, or the
    /// timeout cancels the session.
    func identify(timeout: TimeInterval = 15) async -> RecognitionOutcome {
        let session = SHManagedSession()
        activeSession = session
        timedOut = false
        defer { activeSession = nil }

        let timeoutTask = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.timedOut = true
            session.cancel()
        }
        defer { timeoutTask.cancel() }

        let result = await session.result()
        switch result {
        case .match(let match):
            guard let item = match.mediaItems.first else { return .noMatch }
            return .match(Song(
                title: item.title ?? "Unknown title",
                artist: item.artist ?? "Unknown artist",
                genres: item.genres,
                appleMusicURL: item.appleMusicURL,
                webURL: item.webURL
            ))
        case .noMatch:
            return .noMatch
        case .error(let error, _):
            // A timeout cancel surfaces here — report it as "no match" rather than a failure
            return timedOut ? .noMatch : .failed(error.localizedDescription)
        }
    }

    func cancel() {
        activeSession?.cancel()
        activeSession = nil
    }
}
