import Foundation
import Combine
import UIKit

enum SessionState: String {
    case disconnected = "Disconnected"
    case idle = "Ready"
    case waitingForWake = "Say “Hey Claude”"
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
    private static let frameSourceKey = "VisionClaude_ActiveFrameSource"
    @Published var activeFrameSource: FrameSourceType = {
        guard let raw = UserDefaults.standard.string(forKey: frameSourceKey),
              let saved = FrameSourceType(rawValue: raw) else { return .iPhone }
        return saved
    }() {
        didSet {
            UserDefaults.standard.set(activeFrameSource.rawValue, forKey: Self.frameSourceKey)
            switchFrameSource()
        }
    }
    @Published var frameSourceStatus: FrameSourceStatus = .disconnected
    @Published var rayBanFrame: UIImage?

    // Mode system
    @Published var modeManager = ModeManager()

    // QR/Barcode toast
    @Published var codeToastMessage: String?
    @Published var codeToastDetectedCode: DetectedCode?

    let bridge: ClaudeBridge
    let speechManager = SpeechManager()
    let cameraManager = CameraManager()
    let rayBanManager = RayBanManager()
    private var cancellables = Set<AnyCancellable>()

    // Wake word / on-demand camera state
    private var awakeUntil: Date = .distantPast
    private var lastReplyWasQuestion = false
    private var wakeExpiryTask: Task<Void, Never>?
    private var cameraIdleTask: Task<Void, Never>?
    private let wakeQuestionWindow: TimeInterval = 12  // after a bare "hey claude"
    private let followUpWindow: TimeInterval = 10      // after Claude finishes replying

    /// True while speech should be sent without needing the wake phrase again.
    private var isAwake: Bool { Date() < awakeUntil }

    /// QR-scanner mode auto-detects codes, which needs a live iPhone camera.
    private var shouldStreamContinuously: Bool {
        if !config.onDemandCamera { return true }
        return modeManager.activeMode.id == "qr_scanner" && activeFrameSource == .iPhone
    }

    init(config: ClaudeConfig = ClaudeConfig.load()) {
        self.config = config
        self.bridge = ClaudeBridge(config: config)
        setupBindings()
        setupBridgeCallbacks()
        setupCodeDetection()
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
                self.lastReplyWasQuestion = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")

                if let audioUrl, let url = URL(string: audioUrl) {
                    // Play TTS audio from channel server
                    self.state = .speaking
                    self.speechManager.playRemoteAudio(url: url) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.isConnected, self.state == .speaking else { return }
                            self.startFollowUpListening()
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
                    // On-demand policy: leave the camera off until a question needs
                    // vision — continuous streaming drains the glasses and the phone.
                    if self.shouldStreamContinuously {
                        self.startActiveFrameSource()
                    }
                    // Hands-free: listen for "hey claude" right away.
                    if self.config.wakeWordEnabled && !self.speechManager.isListening {
                        self.startListening()
                    }
                }
            }
        }

        bridge.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.state = .disconnected
            }
        }
    }

    // MARK: - QR/Barcode Detection

    private func setupCodeDetection() {
        cameraManager.$lastDetectedCode
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] code in
                guard let self else { return }
                self.handleDetectedCode(code)
            }
            .store(in: &cancellables)
    }

    private func handleDetectedCode(_ code: DetectedCode) {
        if modeManager.activeMode.id == "qr_scanner" {
            // In QR Scanner mode: automatically send to Claude
            let message = "I scanned a \(code.type) code: \(code.value). What is this?"
            Task { await self.sendText(message) }
        } else {
            // In other modes: show a toast notification
            codeToastDetectedCode = code
            codeToastMessage = "\(code.type): \(code.value)"
            // Auto-dismiss toast after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.codeToastDetectedCode?.timestamp == code.timestamp {
                    self?.codeToastMessage = nil
                    self?.codeToastDetectedCode = nil
                }
            }
        }
    }

    func sendCodeToChat(_ code: DetectedCode) {
        codeToastMessage = nil
        codeToastDetectedCode = nil
        let message = "I scanned a \(code.type) code: \(code.value). What is this?"
        Task { await self.sendText(message) }
    }

    func copyCodeToClipboard(_ code: DetectedCode) {
        UIPasteboard.general.string = code.value
        codeToastMessage = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.codeToastMessage = nil
            self?.codeToastDetectedCode = nil
        }
    }

    // MARK: - Connection

    func connect() async {
        errorMessage = nil

        // Try channel mode first (WebSocket -> Claude Code session)
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
        cameraIdleTask?.cancel()
        wakeExpiryTask?.cancel()
        awakeUntil = .distantPast
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
        cameraIdleTask?.cancel()
        cameraManager.stop()
        rayBanManager.stop()
        frameSourceStatus = .disconnected

        if activeFrameSource == .rayBan {
            // Reconfigure audio session for Bluetooth, then route mic
            try? AudioSessionManager.shared.configureForVoiceChat()
            // Retry mic routing after DAT SDK has had time to set up streaming
            // The SDK may reset the audio route when it starts
            for delay in [0.5, 1.5, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    AudioSessionManager.shared.routeToBluetoothMicIfAvailable()
                }
            }
            if isConnected && !speechManager.isListening {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.startListening()
                }
            }
        }
        if shouldStreamContinuously {
            startActiveFrameSource()
        }
    }

    /// Starts the active source only when it isn't already running or mid-startup —
    /// re-entering RayBanManager.start() during its async session dance would
    /// rebuild the DAT session underneath the in-flight one.
    private func startActiveFrameSourceIfNeeded() {
        let status = activeFrameSource == .iPhone
            ? cameraManager.connectionStatus
            : rayBanManager.connectionStatus
        switch status {
        case .connected, .connecting: return
        default: startActiveFrameSource()
        }
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
        print("[Session] Speaking interrupted by user — resuming listening")
        // Brief delay for audio session to settle after stopping playback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startFollowUpListening()
        }
    }

    // MARK: - Voice

    func toggleListening() {
        if speechManager.isListening {
            if state == .waitingForWake {
                // Mic tap while passively waiting = "I want to talk now" — skip the wake word.
                extendAwake(by: wakeQuestionWindow)
                state = .listening
            } else {
                speechManager.stopListening()
                state = .idle
            }
        } else {
            startListening()
        }
    }

    func startListening() {
        startListening(retriesRemaining: 3)
    }

    private func startListening(retriesRemaining: Int) {
        if speechManager.isSpeaking {
            speechManager.stopSpeaking()
        }
        do {
            try speechManager.startListening()
            state = (config.wakeWordEnabled && !isAwake) ? .waitingForWake : .listening
            errorMessage = nil
        } catch {
            print("[Session] startListening failed (retries left: \(retriesRemaining)): \(error)")
            // Audio route transitions (glasses HFP <-> iPhone after TTS playback)
            // briefly reject the engine's input format — CoreAudio -10868
            // kAudioUnitErr_FormatNotSupported. The route settles within a
            // second, so retry before surfacing an error to the user.
            if retriesRemaining > 0, isConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.isConnected,
                          !self.speechManager.isListening, !self.speechManager.isSpeaking else { return }
                    self.startListening(retriesRemaining: retriesRemaining - 1)
                }
            } else {
                errorMessage = "Mic: \(error.localizedDescription)"
            }
        }
    }

    /// Resume listening after Claude replies, keeping a short window where
    /// follow-ups don't need the wake phrase again.
    private func startFollowUpListening() {
        if config.wakeWordEnabled {
            extendAwake(by: followUpWindow)
        }
        startListening()
    }

    /// Marks the session awake for `window` seconds and schedules the state pill
    /// to drop back to "Say Hey Claude" when the window lapses unused.
    private func extendAwake(by window: TimeInterval) {
        awakeUntil = Date().addingTimeInterval(window)
        wakeExpiryTask?.cancel()
        wakeExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.state == .listening && !self.isAwake && self.config.wakeWordEnabled {
                self.state = .waitingForWake
            }
        }
    }

    private func setupBindings() {
        speechManager.$transcribedText
            .receive(on: RunLoop.main)
            .assign(to: &$currentTranscription)

        // Pre-warm the camera the moment the vision trigger ("look at") shows up
        // in the PARTIAL transcription — the stream cold-start then overlaps with
        // the user finishing their sentence instead of adding to answer latency.
        // A bare wake word no longer pre-warms: most questions are text-only.
        speechManager.$transcribedText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self, self.config.wakeWordEnabled, self.config.onDemandCamera,
                      self.isConnected, !text.isEmpty,
                      let question = QuestionRouter.questionAfterWakeWord(in: text),
                      QuestionRouter.needsVision(question, mode: self.modeManager.activeMode)
                else { return }
                self.preWarmCamera()
            }
            .store(in: &cancellables)

        speechManager.onSpeechPause = { [weak self] text in
            Task { @MainActor in
                await self?.handleVoiceSpeech(text)
            }
        }

        // Recognition died on its own (route change, iOS task limit) — restart it
        // so hands-free wake-word listening survives long idle stretches.
        speechManager.onListeningStopped = { [weak self] in
            Task { @MainActor in
                guard let self, self.isConnected, self.config.wakeWordEnabled,
                      !self.isProcessing, !self.speechManager.isSpeaking,
                      self.state == .listening || self.state == .waitingForWake else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !self.speechManager.isListening else { return }
                self.startListening()
            }
        }

        // QR-scanner mode needs the camera running to auto-detect codes;
        // leaving it re-arms the on-demand idle shutdown.
        modeManager.$activeMode
            .receive(on: RunLoop.main)
            .removeDuplicates { $0.id == $1.id }
            .sink { [weak self] mode in
                guard let self, self.isConnected, self.config.onDemandCamera else { return }
                if mode.id == "qr_scanner" && self.activeFrameSource == .iPhone {
                    self.cameraIdleTask?.cancel()
                    self.startActiveFrameSourceIfNeeded()
                } else {
                    self.scheduleCameraIdleStop()
                }
            }
            .store(in: &cancellables)

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

    /// Voice input goes through the wake-word gate; typed messages and quick
    /// actions call handleUserSpeech directly and skip it.
    private func handleVoiceSpeech(_ text: String) async {
        guard config.wakeWordEnabled else {
            await handleUserSpeech(text)
            return
        }

        if let question = QuestionRouter.questionAfterWakeWord(in: text) {
            if question.isEmpty {
                // A bare "hey claude" — stay hot and capture the actual question next.
                print("[Session] Wake word heard — listening for the question")
                extendAwake(by: wakeQuestionWindow)
                currentTranscription = ""
                startListening()
                return
            }
            awakeUntil = .distantPast
            await handleUserSpeech(question)
        } else if isAwake {
            // Follow-up window: filter out conversational fragments ("Wait", "Yeah")
            // that aren't addressed to Claude — each junk send costs a round trip
            // and a spoken reply, which re-opens the window and compounds. Single
            // words only count when they answer a question Claude just asked.
            let wordCount = text.split(whereSeparator: { $0 == " " }).count
            if wordCount < 2 && !lastReplyWasQuestion {
                print("[Session] Ignoring one-word follow-up: \"\(text)\"")
                currentTranscription = ""
                startListening()
                return
            }
            awakeUntil = .distantPast
            await handleUserSpeech(text)
        } else {
            // Ambient speech without the wake word — discard and keep waiting.
            print("[Session] Ignoring speech without wake word: \"\(text.prefix(60))\"")
            currentTranscription = ""
            startListening()
        }
    }

    private func handleUserSpeech(_ text: String) async {
        guard !isProcessing else { return }
        isProcessing = true

        transcript.append(TranscriptMessage(role: .user, text: text))
        currentTranscription = ""
        state = .thinking
        errorMessage = nil

        // Route: does this question need eyes, or just text?
        let wantsVision = QuestionRouter.needsVision(text, mode: modeManager.activeMode)
        var image: Data?
        if wantsVision {
            image = await captureFrameOnDemand()
            scheduleCameraIdleStop()
        }
        let source = activeFrameSource == .iPhone ? "iphone" : "rayban"
        print("[Session] Routing: \(wantsVision ? "vision" : "text-only")\(wantsVision && image == nil ? " (frame unavailable)" : "")")

        // Prepend mode system prompt as context
        let modeContext = modeManager.activeMode.systemPrompt
        var fullText = "[Mode: \(modeManager.activeMode.name)] \(modeContext)\n\nUser: \(text)"
        if wantsVision && image == nil {
            fullText += "\n\n(Note: the camera could not provide a frame for this question — answer from context or say you can't see right now.)"
        }

        if bridge.mode == .channel {
            // Channel mode: send via WebSocket or HTTP upload
            if let imageData = image, imageData.count > 100_000 {
                // Large images: use HTTP multipart (avoids base64 bloat)
                do {
                    try await bridge.uploadImage(text: fullText, image: imageData, source: source)
                } catch {
                    print("[Session] Upload error, falling back to WS: \(error)")
                    bridge.sendMessage(text: fullText, image: imageData, source: source)
                }
            } else {
                // Small images or text-only: send via WebSocket
                bridge.sendMessage(text: fullText, image: image, source: source)
            }
            print("[Session] Sent to channel: \"\(text)\" with \(image != nil ? "image" : "no image") [mode: \(modeManager.activeMode.name)]")
            // Reply comes back via onReply callback — don't set isProcessing = false here

        } else {
            // Gateway mode: REST fallback
            do {
                let response = try await bridge.chatREST(text: fullText, images: image.map { [$0] } ?? [])
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

    // MARK: - On-Demand Frame Capture

    /// Starts the active frame source speculatively (no-op if already running or
    /// starting). The idle timer is armed immediately so a text-only question
    /// doesn't leave a pre-warmed stream running forever; a vision question
    /// re-arms it after the frame is captured.
    private func preWarmCamera() {
        let status = activeFrameSource == .iPhone
            ? cameraManager.connectionStatus
            : rayBanManager.connectionStatus
        if case .connected = status { return }
        if case .connecting = status { return }
        print("[Session] Wake word heard — pre-warming \(activeFrameSource.rawValue)")
        startActiveFrameSource()
        scheduleCameraIdleStop()
    }

    /// Spins up the active frame source (if it isn't already streaming) just long
    /// enough to grab one fresh JPEG. Returns nil on timeout — glasses cold-starts
    /// go through the whole DAT session dance and can legitimately take a while.
    private func captureFrameOnDemand() async -> Data? {
        cameraIdleTask?.cancel()
        let source: any FrameSource = activeFrameSource == .iPhone ? cameraManager : rayBanManager
        if !source.isRunning {
            print("[Session] Vision question — starting \(activeFrameSource.rawValue) on demand")
            startActiveFrameSourceIfNeeded()
        }

        let timeout: TimeInterval = activeFrameSource == .rayBan ? 15 : 5
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = source.consumeFrame() { return frame }
            if case .error = source.connectionStatus { return nil }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        print("[Session] Timed out waiting for a frame from \(activeFrameSource.rawValue)")
        return nil
    }

    /// Shuts the stream back down after a quiet period so follow-up vision
    /// questions stay snappy without leaving the camera burning battery.
    private func scheduleCameraIdleStop() {
        cameraIdleTask?.cancel()
        guard config.onDemandCamera, !shouldStreamContinuously else { return }
        let timeout = config.cameraIdleTimeout
        cameraIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard !self.isProcessing else {
                self.scheduleCameraIdleStop()  // still waiting on a reply — check again later
                return
            }
            print("[Session] Camera idle for \(Int(timeout))s — stopping stream to save battery")
            self.stopFrameSources()
        }
    }

    private func stopFrameSources() {
        cameraManager.stop()
        rayBanManager.stop()
        frameSourceStatus = .disconnected
    }

    private func observeSpeechCompletion() {
        speechManager.$isSpeaking
            .dropFirst()
            .filter { !$0 }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isConnected, self.state == .speaking else { return }
                self.startFollowUpListening()
            }
            .store(in: &cancellables)
    }

    func resetConversation() async {
        transcript.removeAll()
        bridge.resetConversation()
        errorMessage = nil
    }
}
