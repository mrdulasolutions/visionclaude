import Foundation
import Speech
import AVFoundation
import CryptoKit

// MARK: - ElevenLabs Voice Directory

struct ElevenLabsVoice: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let description: String
    let gender: String

    var icon: String {
        gender == "female" ? "person.crop.circle.fill" : "person.crop.circle"
    }

    static let allVoices: [ElevenLabsVoice] = [
        ElevenLabsVoice(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel", description: "Calm & warm", gender: "female"),
        ElevenLabsVoice(id: "29vD33N1CtxCmqQRPOHJ", name: "Drew", description: "Well-rounded", gender: "male"),
        ElevenLabsVoice(id: "2EiwWnXFnvU5JabPnv8n", name: "Clyde", description: "Deep & strong", gender: "male"),
        ElevenLabsVoice(id: "5Q0t7uMcjvnagumLfvZi", name: "Paul", description: "Ground news", gender: "male"),
        ElevenLabsVoice(id: "AZnzlk1XvdvUeBnXmlld", name: "Domi", description: "Assertive", gender: "female"),
        ElevenLabsVoice(id: "CYw3kZ02Hs0563khs1Fj", name: "Dave", description: "British conversational", gender: "male"),
        ElevenLabsVoice(id: "D38z5RcWu1voky8WS1ja", name: "Fin", description: "Irish", gender: "male"),
        ElevenLabsVoice(id: "EXAVITQu4vr4xnSDxMaL", name: "Sarah", description: "Soft & young", gender: "female"),
        ElevenLabsVoice(id: "ErXwobaYiN019PkySvjV", name: "Antoni", description: "Well-rounded", gender: "male"),
        ElevenLabsVoice(id: "MF3mGyEYCl7XYWbV9V6O", name: "Elli", description: "Young & emotional", gender: "female"),
    ]

    static func voice(for id: String) -> ElevenLabsVoice {
        allVoices.first { $0.id == id } ?? allVoices[0]
    }
}

// MARK: - ElevenLabs REST TTS Client (no package dependency)

class ElevenLabsTTSClient {
    private let apiKey: String
    private let session = URLSession.shared

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Synthesize with optimized latency settings
    func synthesize(text: String, voiceId: String) async throws -> Data {
        // Use streaming endpoint for lower time-to-first-byte
        let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "text": text,
            // Flash model — ~75% faster than multilingual_v2, still high quality
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0.0,
                "use_speaker_boost": true
            ],
            // Optimize for low latency
            "optimize_streaming_latency": 3
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "ElevenLabs", code: statusCode,
                         userInfo: [NSLocalizedDescriptionKey: "ElevenLabs API error \(statusCode): \(errorBody)"])
        }

        return data
    }
}

// MARK: - Audio Player for MP3 data

class AudioDataPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioDataPlayer()
    private var player: AVAudioPlayer?
    private var completion: (() -> Void)?

    func play(data: Data, completion: @escaping () -> Void) {
        self.completion = completion

        do {
            let session = AVAudioSession.sharedInstance()
            // Don't flip an already record-capable session to .playback — the
            // category change tears down the Bluetooth HFP route to the glasses
            // and the renegotiation back afterwards makes the next mic start
            // fail with CoreAudio -10868 (format not supported).
            if session.category != .playAndRecord {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            }
            try session.setActive(true)

            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.play()
        } catch {
            print("[AudioPlayer] Error: \(error)")
            completion()
        }
    }

    func stop() {
        player?.stop()
        player = nil
        completion?()
        completion = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.completion?()
            self.completion = nil
        }
    }
}

// MARK: - Speech Manager

@MainActor
class SpeechManager: NSObject, ObservableObject {
    // STT state
    @Published var transcribedText: String = ""
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false

    // STT
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    // var, not let: a Bluetooth route loss (glasses powering off mid-session) can
    // corrupt the engine's cached input graph — start() then fails with -10868
    // forever on that instance, and only a fresh engine recovers.
    private var audioEngine = AVAudioEngine()

    // TTS — ElevenLabs (direct REST, no package)
    private var elevenLabsClient: ElevenLabsTTSClient?
    private var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel default

    // Fallback TTS — Apple (if no ElevenLabs key)
    /// When true, replies use the local Apple voice even if ElevenLabs is
    /// configured — set from ClaudeConfig.useAppleVoice.
    var preferAppleVoice = true

    private let appleSynthesizer = AVSpeechSynthesizer()

    // Instant local-only synth for canned acknowledgments ("On it."). A
    // separate instance with no delegate: zero network latency, and its
    // completion can never flip isSpeaking or restart the mic mid-thinking.
    private let ackSynthesizer = AVSpeechSynthesizer()

    // Pre-synthesized ElevenLabs audio for the canned acknowledgment phrases,
    // keyed by exact text. The phrases are a small fixed set, so caching them
    // up front lets the ack play in the assistant's real voice with the same
    // zero latency as local TTS. Rebuilt when the voice changes.
    private var ackAudioCache: [String: Data] = [:]
    private var ackPhrases: [String] = []

    // MARK: Disk cache for canned phrase audio

    // ElevenLabs bills per character, so canned phrases are synthesized ONCE
    // EVER per voice and kept on disk — re-synthesizing ~25 phrases on every
    // app launch was silently draining the account's monthly quota.
    private var ackCacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AckAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Filenames are voice-scoped, so switching voices never overwrites and
    /// switching back is free.
    private func ackCacheURL(for text: String) -> URL {
        let digest = SHA256.hash(data: Data("\(elevenLabsVoiceId)|\(text)".utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined().prefix(32)
        return ackCacheDir.appendingPathComponent("\(name).mp3")
    }

    private func loadCachedAckAudio(for text: String) -> Data? {
        if let data = ackAudioCache[text] { return data }
        guard let data = try? Data(contentsOf: ackCacheURL(for: text)) else { return nil }
        ackAudioCache[text] = data
        return data
    }

    private func storeAckAudio(_ data: Data, for text: String) {
        ackAudioCache[text] = data
        try? data.write(to: ackCacheURL(for: text))
    }

    // Pause detection
    private var silenceTimer: Timer?
    private var pauseThreshold: TimeInterval = 1.5
    var onSpeechPause: ((String) -> Void)?
    var onSpeechFinished: (() -> Void)?
    /// Fired when recognition dies unexpectedly (not via stopListening) — lets the
    /// session restart the mic so wake-word listening survives long sessions.
    var onListeningStopped: (() -> Void)?

    // iOS quietly ends long-running recognition tasks; cycle them during silence.
    private var watchdogTimer: Timer?
    private let watchdogInterval: TimeInterval = 50

    override init() {
        super.init()
        // A mediaserverd crash invalidates every live audio object — the old
        // engine then fails with 'what' (2003332927) forever. Replace it and
        // let the session's supervisor restart listening on the fresh one.
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                print("[Speech] Media services reset — rebuilding audio engine")
                self.stopListening()
                self.audioEngine = AVAudioEngine()
                try? AudioSessionManager.shared.configureForVoiceChat()
                self.onListeningStopped?()
            }
        }
        appleSynthesizer.delegate = self
    }

    // MARK: - Configuration

    func configureElevenLabs(apiKey: String, voiceId: String? = nil) {
        if !apiKey.isEmpty {
            elevenLabsClient = ElevenLabsTTSClient(apiKey: apiKey)
            if let voiceId { elevenLabsVoiceId = voiceId }
            let voice = ElevenLabsVoice.voice(for: elevenLabsVoiceId)
            print("[Speech] ElevenLabs TTS configured (voice: \(voice.name))")
        } else {
            elevenLabsClient = nil
            print("[Speech] No ElevenLabs key — using Apple TTS fallback")
        }
    }

    func setVoice(_ voiceId: String) {
        elevenLabsVoiceId = voiceId
        let voice = ElevenLabsVoice.voice(for: voiceId)
        print("[Speech] Voice changed to: \(voice.name)")
        // Cached ack audio is in the old voice — rebuild in the new one.
        ackAudioCache.removeAll()
        prewarmAcknowledgments(ackPhrases)
    }

    /// Pre-synthesizes the canned acknowledgment phrases through ElevenLabs so
    /// they play instantly in the assistant's voice. Runs in the background;
    /// until a phrase lands in the cache it falls back to local Apple TTS.
    func prewarmAcknowledgments(_ phrases: [String]) {
        ackPhrases = phrases
        guard let client = elevenLabsClient else { return }
        let voiceId = elevenLabsVoiceId
        Task {
            var synthesized = 0
            for phrase in phrases where loadCachedAckAudio(for: phrase) == nil {
                if let data = try? await client.synthesize(text: phrase, voiceId: voiceId) {
                    storeAckAudio(data, for: phrase)
                    synthesized += 1
                }
            }
            print("[Speech] Ack cache ready (\(ackAudioCache.count) in memory, \(synthesized) newly synthesized)")
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return status == .authorized
    }

    // MARK: - STT (Apple Speech — on-device)

    func startListening() throws {
        // Stop any current speech first, then wait for audio session to settle
        if isSpeaking {
            stopSpeaking()
            // Give audio session time to transition before reconfiguring
            Thread.sleep(forTimeInterval: 0.15)
        }
        stopListening()

        // Reconfigure audio session for recording
        try? AudioSessionManager.shared.configureForVoiceChat()

        // Reset audio engine to pick up current route (iPhone mic vs Bluetooth)
        audioEngine.reset()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // "Aelita" isn't in the recognizer's vocabulary — without this bias the
        // wake word comes back as arbitrary soundalikes and never matches.
        request.contextualStrings = ["Flux", "OK Flux", "Okay Flux"]

        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request

        do {
            try startEngineWithTap()
        } catch {
            // A stale input graph after a route loss fails with -10868 on every
            // start() no matter how long we wait — rebuild the engine and retry
            // once. No settle sleep here: this runs on the main thread right
            // after replies (route renegotiation time) and a sleep freezes the
            // UI. The sample-rate guard in startEngineWithTap makes a too-early
            // retry throw cheaply, and SessionViewModel's async retry ladder
            // (0.6s spacing) provides the settle time off the main thread.
            print("[Speech] Engine start failed (\(error.localizedDescription)) — rebuilding audio engine")
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine = AVAudioEngine()
            try startEngineWithTap()
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                // Ignore stale callbacks from a session we already tore down —
                // cancel() delivers an error asynchronously, after a new session
                // may have started, and must not kill the fresh one.
                guard self.recognitionRequest === request else { return }
                if let result {
                    self.transcribedText = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                    if result.isFinal { self.handleFinalResult() }
                }
                if let error {
                    print("[Speech] Recognition ended with error: \(error)")
                    self.stopListening()
                    self.onListeningStopped?()
                }
            }
        }

        isListening = true
        transcribedText = ""
        scheduleWatchdog()
    }

    /// Installs the mic tap on the engine's current input node and starts it.
    private func startEngineWithTap() throws {
        audioEngine.reset()
        let inputNode = audioEngine.inputNode
        // Use the node's ACTUAL output format — this adapts to whatever
        // audio route is active (iPhone mic = 48kHz, Bluetooth HFP = 16kHz)
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Guard against zero-channel format (happens during route transitions)
        guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
            throw NSError(domain: "SpeechManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Audio input not ready — try again"])
        }

        // The engine's input graph must agree with the live hardware rate. While
        // a Bluetooth HFP route is renegotiating (glasses mic arriving at 16kHz,
        // iPhone mic at 48kHz), even a FRESH engine can read the outgoing rate —
        // engine.start() then dies deep in CoreAudio with -10868. Fail fast here
        // instead, so the retry ladder waits the transition out.
        let hwSampleRate = AVAudioSession.sharedInstance().sampleRate
        guard recordingFormat.sampleRate == hwSampleRate else {
            throw NSError(domain: "SpeechManager", code: -10868,
                         userInfo: [NSLocalizedDescriptionKey: "Audio route still settling (mic \(Int(hwSampleRate))Hz, engine \(Int(recordingFormat.sampleRate))Hz) — try again"])
        }

        // Pass `nil` (not the captured `recordingFormat`) so the engine resolves the
        // bus's CURRENT native format at install time. If the route changes between the
        // read above and here — e.g. Bluetooth HFP glasses (16kHz) dropping to the iPhone
        // mic (48kHz) — a captured format would no longer match the live bus and
        // installTap throws an uncatchable NSException (SIGABRT). nil closes that window.
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // An inactive session makes engine.start() fail with the opaque
        // 'what' error (2003332927) — activation can silently lapse across
        // route flaps and interruptions, so re-assert it here.
        try? AVAudioSession.sharedInstance().setActive(true)

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Nuclear option for stuck CoreAudio states: discard the engine
    /// entirely. The supervisor calls this after repeated failed revives.
    func rebuildEngine() {
        stopListening()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine = AVAudioEngine()
        print("[Speech] Audio engine rebuilt on request")
    }

    func stopListening() {
        isListening = false
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func scheduleWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogFired() }
        }
    }

    private func watchdogFired() {
        guard isListening else { return }
        // Mid-utterance — the silence timer owns the session, don't cycle it.
        guard transcribedText.isEmpty else { return }
        print("[Speech] Watchdog: cycling recognition task to keep listening alive")
        stopListening()
        do { try startListening() } catch {
            print("[Speech] Watchdog restart failed: \(error.localizedDescription)")
            onListeningStopped?()
        }
    }

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: pauseThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.handleSpeechPause() }
        }
    }

    private func handleSpeechPause() {
        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stopListening()
        onSpeechPause?(text)
    }

    private func handleFinalResult() {
        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stopListening()
        onSpeechPause?(text)
    }

    // MARK: - TTS

    func speak(_ text: String) {
        // The real reply supersedes any still-playing acknowledgment.
        ackSynthesizer.stopSpeaking(at: .immediate)
        // The mic may still be open (it listens during thinking so "stop"
        // works) — close it so the reply doesn't transcribe itself.
        if isListening { stopListening() }
        isSpeaking = true

        if !preferAppleVoice, let client = elevenLabsClient {
            speakWithElevenLabs(client, text: text)
        } else {
            speakWithApple(text)
        }
    }

    /// Speaks a short canned confirmation — no state changes, fire-and-forget.
    /// Always local Apple TTS: ElevenLabs is reserved for AI replies (it bills
    /// per character, and these fire on every interaction).
    func speakAcknowledgment(_ text: String) {
        ackSynthesizer.stopSpeaking(at: .immediate)
        speakAckWithApple(text)
    }

    /// One consistent local voice for EVERYTHING the app says with Apple TTS —
    /// replies, acknowledgments and confirmations previously picked different
    /// voices, which sounded like two assistants. Siri's own voices aren't
    /// available to third-party apps, so this selects the most natural
    /// installed female English voice: UK English first, premium quality over
    /// enhanced over default.
    static let appleVoice: AVSpeechSynthesisVoice? = {
        // Female is a hard requirement, not a tiebreaker — an all-male
        // installed set is the only case that falls through. Within the
        // female pool: British English first, then voice quality.
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            var score = 0
            if v.language == "en-GB" { score += 40 }
            else if v.language.hasPrefix("en") { score += 20 }
            switch v.quality {
            case .premium: score += 30
            case .enhanced: score += 20
            default: break
            }
            return score
        }
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let female = english.filter { $0.gender == .female }
        // Known-female fallback for voices that report .unspecified gender
        let knownFemaleNames: Set<String> = ["samantha", "kate", "serena", "martha", "stephanie", "ava", "allison", "susan", "zoe", "nicky", "moira", "karen", "tessa"]
        let namedFemale = english.filter { knownFemaleNames.contains($0.name.lowercased().components(separatedBy: " ").first ?? "") }
        let pool = !female.isEmpty ? female : (!namedFemale.isEmpty ? namedFemale : english)
        let voice = pool.max { rank($0) < rank($1) }
        print("[Speech] Apple voice: \(voice?.name ?? "system default") (\(voice?.language ?? "?"), gender \(voice?.gender.rawValue ?? -1), quality \(voice?.quality.rawValue ?? 0))")
        return voice
    }()

    /// Last-resort local voice, used only when ElevenLabs is unavailable.
    private func speakAckWithApple(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.appleVoice ?? AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        ackSynthesizer.speak(utterance)
    }

    /// Speaks arbitrary short text in the ElevenLabs voice without touching
    /// speech state — used to confirm a captured quiz question back to the
    /// user while the answer is being generated. Dynamic text can't be
    /// pre-cached, so this pays one synthesis round trip; if the real answer
    /// starts speaking first, the late confirmation is dropped.
    func speakConfirmation(_ text: String) {
        // Always local Apple TTS — echoing every quiz question through
        // ElevenLabs was the single biggest credit spender.
        ackSynthesizer.stopSpeaking(at: .immediate)
        speakAckWithApple(text)
    }

    func stopSpeaking() {
        AudioDataPlayer.shared.stop()
        appleSynthesizer.stopSpeaking(at: .immediate)
        ackSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Play TTS audio from a remote URL (used in channel mode where server generates TTS)
    func playRemoteAudio(url: URL, completion: @escaping () -> Void) {
        isSpeaking = true
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    print("[Speech] Remote audio fetch failed")
                    await MainActor.run { self.isSpeaking = false }
                    completion()
                    return
                }
                print("[Speech] Playing remote audio: \(data.count) bytes from \(url.lastPathComponent)")
                AudioDataPlayer.shared.play(data: data) {
                    Task { @MainActor in
                        self.isSpeaking = false
                        print("[Speech] Remote audio playback finished")
                    }
                    completion()
                }
            } catch {
                print("[Speech] Remote audio error: \(error)")
                await MainActor.run { self.isSpeaking = false }
                completion()
            }
        }
    }

    private func speakWithElevenLabs(_ client: ElevenLabsTTSClient, text: String) {
        // Pre-cached phrases (the greeting, canned confirmations) play without
        // touching the network — immune to the quota/rate-limit fallback below.
        if let cached = loadCachedAckAudio(for: text) {
            playElevenLabsData(cached)
            return
        }
        Task {
            do {
                let voiceName = ElevenLabsVoice.voice(for: elevenLabsVoiceId).name
                print("[Speech] ElevenLabs: synthesizing (voice: \(voiceName))...")
                let audioData = try await client.synthesize(text: text, voiceId: elevenLabsVoiceId)
                print("[Speech] ElevenLabs: received \(audioData.count) bytes, playing...")
                playElevenLabsData(audioData)
            } catch {
                print("[Speech] ElevenLabs error: \(error.localizedDescription)")
                print("[Speech] Falling back to Apple TTS...")
                speakWithApple(text)
            }
        }
    }

    private func playElevenLabsData(_ data: Data) {
        AudioDataPlayer.shared.play(data: data) {
            Task { @MainActor in
                self.isSpeaking = false
                self.onSpeechFinished?()
                print("[Speech] ElevenLabs playback finished")
            }
        }
    }

    private func speakWithApple(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.appleVoice ?? AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        appleSynthesizer.speak(utterance)
    }

    func setPauseThreshold(_ threshold: TimeInterval) {
        pauseThreshold = threshold
    }
}

// MARK: - AVSpeechSynthesizerDelegate (Apple TTS fallback)

extension SpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onSpeechFinished?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
