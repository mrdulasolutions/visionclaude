import SwiftUI
import AVFoundation

// MARK: - Anthropic Accent Color

extension Color {
    static let anthropicOrange = Color(red: 232/255, green: 123/255, blue: 53/255)
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var viewModel = SessionViewModel()
    @State private var showSettings = false
    @State private var textInput = ""
    @State private var hasRequestedPermissions = false
    @State private var isTextFieldFocused = false

    var body: some View {
        ZStack {
            // ── Camera Preview (edge-to-edge) ──
            cameraLayer
                .ignoresSafeArea()

            // ── Subtle bottom gradient (replaces heavy overlay) ──
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6), .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: UIScreen.main.bounds.height * 0.55)
            }
            .ignoresSafeArea()

            // ── Top gradient for status bar legibility ──
            VStack {
                LinearGradient(
                    colors: [.black.opacity(0.5), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
                Spacer()
            }
            .ignoresSafeArea()

            // ── Content Layer ──
            VStack(spacing: 0) {
                // ── Top Status Bar ──
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 4)

                Spacer()

                // ── Transcript (slides up from bottom like iMessage) ──
                if !viewModel.transcript.isEmpty {
                    TranscriptView(messages: viewModel.transcript)
                        .frame(maxHeight: UIScreen.main.bounds.height * 0.35)
                        .padding(.horizontal, 12)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                // ── Live Transcription ──
                if !viewModel.currentTranscription.isEmpty {
                    liveTranscriptionBanner
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                // ── Error Banner ──
                if let error = viewModel.errorMessage {
                    errorBanner(error)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // ── Text Input ──
                textInputBar
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                // ── Bottom Controls (frosted glass) ──
                bottomControls
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                config: $viewModel.config,
                activeFrameSource: $viewModel.activeFrameSource,
                isConnected: viewModel.isConnected,
                frameSourceStatus: viewModel.frameSourceStatus,
                rayBanManager: viewModel.rayBanManager,
                onConnect: { Task { await viewModel.connect() } },
                onConnectGlasses: { Task { await viewModel.connectGlasses() } }
            )
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.transcript.count)
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
        .animation(.easeInOut(duration: 0.2), value: viewModel.errorMessage != nil)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .task {
            guard !hasRequestedPermissions else { return }
            hasRequestedPermissions = true
            let authorized = await viewModel.speechManager.requestAuthorization()
            if authorized {
                await viewModel.connect()
            }
        }
    }

    // MARK: - Camera Layer

    @ViewBuilder
    private var cameraLayer: some View {
        if viewModel.activeFrameSource == .iPhone {
            CameraPreviewView(session: viewModel.cameraManager.captureSession)
        } else {
            ZStack {
                RayBanVideoView(rayBanManager: viewModel.rayBanManager)

                if viewModel.rayBanFrame == nil {
                    Color.black
                    VStack(spacing: 16) {
                        Image(systemName: "eyeglasses")
                            .font(.system(size: 52, weight: .thin))
                            .foregroundStyle(.linearGradient(
                                colors: [.anthropicOrange.opacity(0.6), .anthropicOrange.opacity(0.2)],
                                startPoint: .top, endPoint: .bottom
                            ))
                        if viewModel.frameSourceStatus.isConnected {
                            ProgressView()
                                .tint(.anthropicOrange)
                                .scaleEffect(1.1)
                            Text("Receiving stream...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(viewModel.frameSourceStatus.label)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Send

    private func sendTextInput() {
        let text = textInput
        textInput = ""
        triggerHaptic(.light)
        Task { await viewModel.sendText(text) }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            // Connection indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isConnected ? .green : .red)
                    .frame(width: 8, height: 8)
                    .shadow(color: viewModel.isConnected ? .green.opacity(0.5) : .red.opacity(0.5), radius: 4)

                Image(systemName: viewModel.connectionMode == .channel ? "bolt.fill" : "globe")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(viewModel.isConnected ? .white : .white.opacity(0.5))

                Image(systemName: viewModel.activeFrameSource.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(frameSourceColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())

            // State pill
            HStack(spacing: 5) {
                stateIcon
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(stateColor)
                Text(viewModel.state.rawValue)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())

            if viewModel.isProcessing {
                ProgressView()
                    .tint(.anthropicOrange)
                    .scaleEffect(0.8)
            }

            Spacer()

            // Settings button
            Button {
                triggerHaptic(.light)
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    // MARK: - Live Transcription

    private var liveTranscriptionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.anthropicOrange)
                .symbolEffect(.variableColor.iterative, isActive: true)

            Text(viewModel.currentTranscription)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.white)

            Text(error)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer()

            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.2), in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Text Input Bar

    private var textInputBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                TextField("Message...", text: $textInput, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .tint(.anthropicOrange)
                    .onSubmit { sendTextInput() }

                if !textInput.isEmpty {
                    Button(action: sendTextInput) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(Color.anthropicOrange)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .animation(.easeInOut(duration: 0.15), value: textInput.isEmpty)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 0) {
            // Reset button
            Button {
                triggerHaptic(.medium)
                Task { await viewModel.resetConversation() }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 18, weight: .medium))
                    Text("Reset")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.65))
                .frame(maxWidth: .infinity)
            }

            // Mic button (prominent center)
            Button {
                triggerHaptic(viewModel.state == .speaking ? .rigid : .medium)
                if viewModel.state == .speaking {
                    viewModel.interruptSpeaking()
                } else if viewModel.isConnected {
                    viewModel.toggleListening()
                } else {
                    Task { await viewModel.connect() }
                }
            } label: {
                ZStack {
                    // Outer pulse ring for listening state
                    if viewModel.state == .listening {
                        Circle()
                            .stroke(Color.red.opacity(0.3), lineWidth: 3)
                            .frame(width: 82, height: 82)
                            .scaleEffect(viewModel.state == .listening ? 1.15 : 1.0)
                            .opacity(viewModel.state == .listening ? 0 : 1)
                            .animation(
                                .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                value: viewModel.state
                            )
                    }

                    // Main button
                    Circle()
                        .fill(micButtonGradient)
                        .frame(width: 72, height: 72)
                        .shadow(color: micButtonColor.opacity(0.4), radius: 12, y: 4)

                    if viewModel.isProcessing {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.1)
                    } else {
                        Image(systemName: micButtonIcon)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // Source toggle
            Button {
                triggerHaptic(.light)
                viewModel.activeFrameSource = viewModel.activeFrameSource == .iPhone ? .rayBan : .iPhone
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.activeFrameSource.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(frameSourceColor)
                        .contentTransition(.symbolEffect(.replace))
                    Text(viewModel.activeFrameSource == .iPhone ? "iPhone" : "Glasses")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .padding(.horizontal, 12)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var stateIcon: some View {
        switch viewModel.state {
        case .disconnected: Image(systemName: "wifi.slash")
        case .idle: Image(systemName: "checkmark")
        case .listening: Image(systemName: "waveform")
        case .thinking: Image(systemName: "brain")
        case .speaking: Image(systemName: "speaker.wave.2.fill")
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .disconnected: return .red
        case .idle: return .green
        case .listening: return .anthropicOrange
        case .thinking: return .yellow
        case .speaking: return .blue
        }
    }

    private var micButtonColor: Color {
        switch viewModel.state {
        case .listening: return .red
        case .thinking: return .anthropicOrange
        case .speaking: return .blue
        default: return viewModel.isConnected ? .anthropicOrange : .gray
        }
    }

    private var micButtonGradient: LinearGradient {
        let base = micButtonColor
        return LinearGradient(
            colors: [base, base.opacity(0.8)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var micButtonIcon: String {
        switch viewModel.state {
        case .listening: return "mic.fill"
        case .thinking: return "ellipsis"
        case .speaking: return "stop.fill"
        case .disconnected: return "wifi.slash"
        default: return "mic"
        }
    }

    private var frameSourceColor: Color {
        switch viewModel.frameSourceStatus {
        case .connected: return .green
        case .connecting: return .yellow
        case .error: return .red
        default: return .white.opacity(0.5)
        }
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Camera Preview (iPhone AVCaptureSession)

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.previewLayer.session = session
    }

    class PreviewContainerView: UIView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            layer.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }
}

// MARK: - Ray-Ban Video Feed (high-performance UIImageView renderer)

struct RayBanVideoView: UIViewRepresentable {
    let rayBanManager: RayBanManager

    func makeUIView(context: Context) -> RayBanVideoUIView {
        let view = RayBanVideoUIView()
        view.manager = rayBanManager
        return view
    }

    func updateUIView(_ uiView: RayBanVideoUIView, context: Context) {
        // Manager reference stays the same — frames push via observation
    }

    class RayBanVideoUIView: UIView {
        private let imageView = UIImageView()
        private var displayLink: CADisplayLink?
        weak var manager: RayBanManager? {
            didSet { startDisplayLink() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            addSubview(imageView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
        }

        private func startDisplayLink() {
            displayLink?.invalidate()
            displayLink = CADisplayLink(target: self, selector: #selector(updateFrame))
            displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 60, preferred: 30)
            displayLink?.add(to: .main, forMode: .common)
        }

        @objc private func updateFrame() {
            guard let manager else { return }
            // Read latestImage directly — UIKit image view swap is near-zero cost
            Task { @MainActor in
                if let image = manager.latestImage {
                    self.imageView.image = image
                }
            }
        }

        override func removeFromSuperview() {
            displayLink?.invalidate()
            displayLink = nil
            super.removeFromSuperview()
        }
    }
}
