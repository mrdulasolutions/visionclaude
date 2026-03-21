import Foundation
import Combine
import UIKit

enum SessionState: String {
    case disconnected = "Disconnected"
    case idle = "Ready"
    case listening = "Listening"
    case thinking = "Thinking"
    case speaking = "Speaking"
}

@MainActor
class SessionViewModel: ObservableObject {
    @Published var state: SessionState = .disconnected
    @Published var transcript: [TranscriptMessage] = []
    @Published var currentTranscription: String = ""
    @Published var isConnected: Bool = false
    @Published var errorMessage: String?
    @Published var isProcessing: Bool = false

    @Published var config: ClaudeConfig {
        didSet {
            bridge = ClaudeBridge(config: config)
            // Reconfigure ElevenLabs when key or voice changes
            speechManager.configureElevenLabs(
                apiKey: config.elevenLabsAPIKey,
                voiceId: config.elevenLabsVoiceId
            )
            speechManager.setVoice(config.elevenLabsVoiceId)
            speechManager.setPauseThreshold(config.speechPauseThreshold)
            // Persist settings
            config.save()
        }
    }

    // Frame sources
    @Published var activeFrameSource: FrameSourceType = .iPhone {
        didSet { switchFrameSource() }
    }
    @Published var frameSourceStatus: FrameSourceStatus = .disconnected
    @Published var rayBanFrame: UIImage?  // Forwarded from rayBanManager for SwiftUI reactivity

    private var bridge: ClaudeBridge
    let speechManager = SpeechManager()
    let cameraManager = CameraManager()
    let rayBanManager = RayBanManager()
    private var cancellables = Set<AnyCancellable>()

    init(config: ClaudeConfig = ClaudeConfig.load()) {
        self.config = config
        self.bridge = ClaudeBridge(config: config)
        setupBindings()
        rayBanManager.startMonitoringRegistration()
        speechManager.configureElevenLabs(
            apiKey: config.elevenLabsAPIKey,
            voiceId: config.elevenLabsVoiceId
        )

        // Forward Ray-Ban frames to trigger SwiftUI updates
        rayBanManager.$latestImage
            .receive(on: RunLoop.main)
            .assign(to: &$rayBanFrame)

        // Forward Ray-Ban connection status
        rayBanManager.$connectionStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, self.activeFrameSource == .rayBan else { return }
                self.frameSourceStatus = status
            }
            .store(in: &cancellables)
    }

    func connectGlasses() async {
        await rayBanManager.register()
    }

    private func setupBindings() {
        speechManager.$transcribedText
            .receive(on: RunLoop.main)
            .assign(to: &$currentTranscription)

        speechManager.onSpeechPause = { [weak self] text in
            Task { @MainActor in
                await self?.handleUserSpeech(text)
            }
        }

        speechManager.setPauseThreshold(config.speechPauseThreshold)

        NotificationCenter.default.publisher(for: .audioInterruptionBegan)
            .sink { [weak self] _ in
                self?.speechManager.stopListening()
                self?.speechManager.stopSpeaking()
                self?.state = .idle
            }
            .store(in: &cancellables)
    }

    // MARK: - Frame Source

    private func switchFrameSource() {
        cameraManager.stop()
        rayBanManager.stop()

        // Re-route audio when switching sources
        if activeFrameSource == .rayBan {
            AudioSessionManager.shared.routeToBluetoothMicIfAvailable()
            // Auto-start listening in glasses mode (hands-free)
            if isConnected && !speechManager.isListening {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.startListening()
                }
            }
        }
        startActiveFrameSource()
    }

    private func startActiveFrameSource() {
        do {
            switch activeFrameSource {
            case .iPhone:
                cameraManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
                try cameraManager.start()
                frameSourceStatus = .connected
            case .rayBan:
                rayBanManager.configure(frameInterval: config.videoFrameInterval, jpegQuality: config.videoJPEGQuality)
                try rayBanManager.start()
                // Status updated async by RayBanManager
            }
            errorMessage = nil
        } catch {
            frameSourceStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
            if activeFrameSource == .rayBan {
                // Don't auto-switch, let user see the error
            }
        }
    }

    // MARK: - Connection

    func connect() async {
        errorMessage = nil
        do {
            let health = try await bridge.checkHealth()
            if health.status == "ok" {
                isConnected = true
                state = .idle

                try AudioSessionManager.shared.configureForVoiceChat()
                startActiveFrameSource()
            }
        } catch {
            errorMessage = "Gateway: \(error.localizedDescription)"
            state = .disconnected
            isConnected = false
        }
    }

    func disconnect() {
        speechManager.stopListening()
        speechManager.stopSpeaking()
        cameraManager.stop()
        rayBanManager.stop()
        frameSourceStatus = .disconnected
        state = .disconnected
        isConnected = false
    }

    // MARK: - Voice

    func toggleListening() {
        if speechManager.isListening {
            speechManager.stopListening()
            state = .idle
        } else {
            startListening()
        }
    }

    func startListening() {
        if speechManager.isSpeaking {
            speechManager.stopSpeaking()
        }

        do {
            try speechManager.startListening()
            state = .listening
            errorMessage = nil
        } catch {
            errorMessage = "Mic: \(error.localizedDescription)"
        }
    }

    // MARK: - Send Message

    func sendText(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await handleUserSpeech(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func handleUserSpeech(_ text: String) async {
        guard !isProcessing else { return }
        isProcessing = true

        transcript.append(TranscriptMessage(role: .user, text: text))
        currentTranscription = ""
        state = .thinking
        errorMessage = nil

        // Grab latest camera frame
        var images: [Data] = []
        switch activeFrameSource {
        case .iPhone:
            if let frame = cameraManager.consumeFrame() {
                images.append(frame)
            }
        case .rayBan:
            if let frame = rayBanManager.consumeFrame() {
                images.append(frame)
            }
        }

        do {
            print("[Session] Sending to gateway: \"\(text)\" with \(images.count) image(s)")
            let response = try await bridge.chat(text: text, images: images)
            print("[Session] Got response: \"\(response.text.prefix(80))...\"")

            transcript.append(TranscriptMessage(
                role: .assistant,
                text: response.text,
                toolCalls: response.tool_calls
            ))

            state = .speaking
            speechManager.speak(response.text)
            observeSpeechCompletion()

        } catch {
            print("[Session] Error: \(error)")
            errorMessage = error.localizedDescription
            state = .idle
        }

        isProcessing = false
    }

    private func observeSpeechCompletion() {
        speechManager.$isSpeaking
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isConnected, self.state == .speaking else { return }
                self.startListening()
            }
            .store(in: &cancellables)
    }

    func resetConversation() async {
        transcript.removeAll()
        await bridge.resetConversation()
        errorMessage = nil
    }
}
