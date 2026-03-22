import Foundation
import Speech
import AVFoundation

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
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
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
    private let audioEngine = AVAudioEngine()

    // TTS — ElevenLabs (direct REST, no package)
    private var elevenLabsClient: ElevenLabsTTSClient?
    private var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel default

    // Fallback TTS — Apple (if no ElevenLabs key)
    private let appleSynthesizer = AVSpeechSynthesizer()

    // Pause detection
    private var silenceTimer: Timer?
    private var pauseThreshold: TimeInterval = 1.5
    var onSpeechPause: ((String) -> Void)?
    var onSpeechFinished: (() -> Void)?

    override init() {
        super.init()
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
        if isSpeaking { stopSpeaking() }
        stopListening()

        // Reset audio engine to pick up current route (iPhone mic vs Bluetooth)
        audioEngine.reset()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        // Use the node's ACTUAL output format — this adapts to whatever
        // audio route is active (iPhone mic = 48kHz, Bluetooth HFP = 16kHz)
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Guard against zero-channel format (happens during route transitions)
        guard recordingFormat.channelCount > 0 else {
            throw NSError(domain: "SpeechManager", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Audio input not ready — try again"])
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcribedText = result.bestTranscription.formattedString
                    self.resetSilenceTimer()
                    if result.isFinal { self.handleFinalResult() }
                }
                if error != nil { self.stopListening() }
            }
        }

        isListening = true
        transcribedText = ""
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
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
        isSpeaking = true

        if let client = elevenLabsClient {
            speakWithElevenLabs(client, text: text)
        } else {
            speakWithApple(text)
        }
    }

    func stopSpeaking() {
        AudioDataPlayer.shared.stop()
        appleSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func speakWithElevenLabs(_ client: ElevenLabsTTSClient, text: String) {
        Task {
            do {
                let voiceName = ElevenLabsVoice.voice(for: elevenLabsVoiceId).name
                print("[Speech] ElevenLabs: synthesizing (voice: \(voiceName))...")
                let audioData = try await client.synthesize(text: text, voiceId: elevenLabsVoiceId)
                print("[Speech] ElevenLabs: received \(audioData.count) bytes, playing...")

                AudioDataPlayer.shared.play(data: audioData) { [weak self] in
                    Task { @MainActor in
                        self?.isSpeaking = false
                        self?.onSpeechFinished?()
                        print("[Speech] ElevenLabs playback finished")
                    }
                }
            } catch {
                print("[Speech] ElevenLabs error: \(error.localizedDescription)")
                print("[Speech] Falling back to Apple TTS...")
                speakWithApple(text)
            }
        }
    }

    private func speakWithApple(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        if let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.language == "en-US" && $0.quality == .enhanced
        }) {
            utterance.voice = premiumVoice
        }

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
