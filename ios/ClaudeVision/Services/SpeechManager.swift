import Foundation
import Speech
import AVFoundation
import ElevenLabsKit

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

    // TTS — ElevenLabs
    private var elevenLabsClient: ElevenLabsTTSClient?
    private var elevenLabsVoiceId: String = "21m00Tcm4TlvDq8ikWAM" // Rachel

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
            print("[Speech] ElevenLabs TTS configured (voice: \(elevenLabsVoiceId))")
        } else {
            elevenLabsClient = nil
            print("[Speech] No ElevenLabs key — using Apple TTS fallback")
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
        if isSpeaking { stopSpeaking() }
        stopListening()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        if speechRecognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
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
        PCMStreamingAudioPlayer.shared.stop()
        appleSynthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func speakWithElevenLabs(_ client: ElevenLabsTTSClient, text: String) {
        Task {
            let request = ElevenLabsTTSRequest(
                text: text,
                modelId: "eleven_v3",
                outputFormat: "pcm_44100"
            )

            print("[Speech] ElevenLabs: streaming TTS (voice: \(elevenLabsVoiceId))...")
            let stream = client.streamSynthesize(
                voiceId: elevenLabsVoiceId,
                request: request
            )

            // play() is async — it returns when audio finishes
            let result = await PCMStreamingAudioPlayer.shared.play(stream: stream, sampleRate: 44100)

            await MainActor.run {
                self.isSpeaking = false
                if result.finished {
                    print("[Speech] ElevenLabs playback finished")
                } else {
                    print("[Speech] ElevenLabs playback interrupted at \(result.interruptedAt ?? 0)s")
                }
                self.onSpeechFinished?()
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
