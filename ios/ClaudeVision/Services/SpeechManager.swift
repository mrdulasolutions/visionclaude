import Foundation
import Speech
import AVFoundation

@MainActor
class SpeechManager: NSObject, ObservableObject {
    // STT state
    @Published var transcribedText: String = ""
    @Published var isListening: Bool = false
    @Published var isSpeaking: Bool = false

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // TTS
    private let synthesizer = AVSpeechSynthesizer()

    // Pause detection
    private var silenceTimer: Timer?
    private var pauseThreshold: TimeInterval = 1.5
    var onSpeechPause: ((String) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return speechStatus == .authorized
    }

    // MARK: - STT

    func startListening() throws {
        // Stop TTS if speaking
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Cancel any existing task
        stopListening()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        // Use on-device recognition if available
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

                    if result.isFinal {
                        self.handleFinalResult()
                    }
                }

                if error != nil {
                    self.stopListening()
                }
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
            Task { @MainActor in
                self?.handleSpeechPause()
            }
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
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Try to use a premium voice
        if let premiumVoice = AVSpeechSynthesisVoice.speechVoices().first(where: {
            $0.language == "en-US" && $0.quality == .enhanced
        }) {
            utterance.voice = premiumVoice
        }

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    func setPauseThreshold(_ threshold: TimeInterval) {
        pauseThreshold = threshold
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}
