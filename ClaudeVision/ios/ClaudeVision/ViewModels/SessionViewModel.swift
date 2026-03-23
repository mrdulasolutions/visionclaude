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
    @Published var connectionMode: ClaudeBridge.ConnectionMode = .channel

    @Published var config: ClaudeConfig {
        didSet {
            bridge.updateConfig(config)
            speechManager.configureElevenLabs(
                apiKey: config.elevenLabsAPIKey,
                voiceId: config.elevenLabsVoiceId
            )
            speechManager.setVoice(config.elevenLabsVoiceId)
            speechManager.setPauseThreshold(config.speechPauseThreshold)
            config.save()
        }
    }

    // Frame sources
    @Published var activeFrameSource: FrameSourceType = .iPhone {
        didSet { switchFrameSource() }
    }
    @Published var frameSourceStatus: FrameSourceStatus = .disconnected
    @Published var rayBanFrame: UIImage?

    let bridge: ClaudeBridge
    let speechManager = SpeechManager()
    let cameraManager = CameraManager()
    let rayBanManager = RayBanManager()
    private var cancellables = Set<AnyCancellable>()

    init(config: ClaudeConfig = ClaudeConfig.load()) {
        self.config = config
        self.bridge = ClaudeBridge(config: config)
        setupBindings()
        setupBridgeCallbacks()
        rayBanManager.startMonitoringRegistration()
        speechManager.configureElevenLabs(
            apiKey: config.elevenLabsAPIKey,
            voiceId: config.elevenLabsVoiceId
        )

        // Forward Ray-Ban frames for SwiftUI reactivity
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

        // Forward bridge connection state
        bridge.$isConnected
            .receive(on: RunLoop.main)
            .assign(to: &$isConnected)

        bridge.$mode
            .receive(on: RunLoop.main)
            .assign(to: &$connectionMode)
    }

    // MARK: - Bridge Callbacks

    private func setupBridgeCallbacks() {
        // When Claude replies via the channel
        bridge.onReply = { [weak self] text, audioUrl in
            Task { @MainActor [weak self] in
                guard let self else { return }

                self.transcript.append(TranscriptMessage(role: .assistant, text: text))
                self.isProcessing = false

                if let audioUrl, let url = URL(string: audioUrl) {
                    // Play TTS audio from channel server
                    self.state = .speaking
                    self.speechManager.playRemoteAudio(url: url) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.isConnected, self.state == .speaking else { return }
                            self.startListening()
                        }
                    }
                } else {
                    // Fallback to local TTS
                    self.state = .speaking
                    self.speechManager.speak(text)
                    self.observeSpeechCompletion()
                }
            }
        }

        bridge.onStatus = { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == "connected" {
                    self.state = .idle
                    self.errorMessage = nil
                    try? AudioSessionManager.shared.configureForVoiceChat()
                    self.startActiveFrameSource()
                }
            }
        }

        bridge.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.state = .disconnected
            }
        }
    }

    // MARK: - Connection

    func connect() async {
        errorMessage = nil

        // Try channel mode first (WebSocket → Claude Code session)
        bridge.mode = .channel
        bridge.connectWebSocket()

        // Also check health endpoint for status
        do {
            let health = try await bridge.checkHealth()
            if health.status == "ok" {
                print("[Session] Channel server health OK")
            }
        } catch {
            print("[Session] Health check failed (channel may still connect via WS): \(error.localizedDescription)")
        }
    }

    func disconnect() {
        speechManager.stopListening()
        speechManager.stopSpeaking()
        cameraManager.stop()
        rayBanManager.stop()
        bridge.disconnect()
        frameSourceStatus = .disconnected
        state = .disconnected
    }

    func connectGlasses() async {
        await rayBanManager.register()
    }

    // MARK: - Frame Source

    private func switchFrameSource() {
        cameraManager.stop()
        rayBanManager.stop()

        if activeFrameSource == .rayBan {
            AudioSessionManager.shared.routeToBluetoothMicIfAvailable()
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
            }
            errorMessage = nil
        } catch {
            frameSourceStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Interrupt

    func interruptSpeaking() {
        speechManager.stopSpeaking()
        state = .idle
        print("[Session] Speaking interrupted by user")
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

        // Grab latest frame
        var image: Data?
        let source: String
        switch activeFrameSource {
        case .iPhone:
            image = cameraManager.consumeFrame()
            source = "iphone"
        case .rayBan:
            image = rayBanManager.consumeFrame()
            source = "rayban"
        }

        if bridge.mode == .channel {
            // Channel mode: send via WebSocket or HTTP upload
            if let imageData = image, imageData.count > 100_000 {
                // Large images: use HTTP multipart (avoids base64 bloat)
                do {
                    try await bridge.uploadImage(text: text, image: imageData, source: source)
                } catch {
                    print("[Session] Upload error, falling back to WS: \(error)")
                    bridge.sendMessage(text: text, image: imageData, source: source)
                }
            } else {
                // Small images or text-only: send via WebSocket
                bridge.sendMessage(text: text, image: image, source: source)
            }
            print("[Session] Sent to channel: \"\(text)\" with \(image != nil ? "image" : "no image")")
            // Reply comes back via onReply callback — don't set isProcessing = false here

        } else {
            // Gateway mode: REST fallback
            do {
                let response = try await bridge.chatREST(text: text, images: image.map { [$0] } ?? [])
                transcript.append(TranscriptMessage(
                    role: .assistant,
                    text: response.text,
                    toolCalls: response.tool_calls
                ))
                state = .speaking
                speechManager.speak(response.text)
                observeSpeechCompletion()
            } catch {
                errorMessage = error.localizedDescription
                state = .idle
            }
            isProcessing = false
        }
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
        bridge.resetConversation()
        errorMessage = nil
    }
}
