import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = SessionViewModel()
    @State private var showSettings = false
    @State private var textInput = ""
    @State private var hasRequestedPermissions = false

    var body: some View {
        ZStack {
            // Camera preview — switches based on active source
            if viewModel.activeFrameSource == .iPhone {
                CameraPreviewView(session: viewModel.cameraManager.captureSession)
                    .ignoresSafeArea()
            } else {
                // Ray-Ban: live video feed via CADisplayLink + UIImageView (smooth 24fps)
                ZStack {
                    RayBanVideoView(rayBanManager: viewModel.rayBanManager)
                        .ignoresSafeArea()

                    // Overlay waiting state when no frames yet
                    if viewModel.rayBanFrame == nil {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: "eyeglasses")
                                .font(.system(size: 48))
                                .foregroundColor(.orange.opacity(0.5))
                            if viewModel.frameSourceStatus.isConnected {
                                ProgressView()
                                    .tint(.orange)
                                Text("Receiving stream...")
                                    .font(.callout)
                                    .foregroundColor(.white.opacity(0.5))
                            } else {
                                Text(viewModel.frameSourceStatus.label)
                                    .font(.callout)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                    }
                }
            }

            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Top Status Bar ──
                topBar
                    .padding(.horizontal)
                    .padding(.top, 8)

                Spacer()

                // ── Transcript ──
                if !viewModel.transcript.isEmpty {
                    TranscriptView(messages: viewModel.transcript)
                        .frame(maxHeight: UIScreen.main.bounds.height * 0.35)
                        .padding(.horizontal)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // ── Live Transcription ──
                if !viewModel.currentTranscription.isEmpty {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text(viewModel.currentTranscription)
                            .font(.callout)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                // ── Error ──
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(8)
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .onTapGesture { viewModel.errorMessage = nil }
                }

                // ── Text Input ──
                HStack(spacing: 8) {
                    TextField("Type a message...", text: $textInput)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(22)
                        .foregroundColor(.white)
                        .onSubmit { sendTextInput() }

                    if !textInput.isEmpty {
                        Button(action: sendTextInput) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundColor(.orange)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // ── Bottom Controls ──
                bottomControls
                    .padding(.top, 12)
                    .padding(.bottom, 20)
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
        .animation(.easeInOut(duration: 0.2), value: viewModel.transcript.count)
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
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

    // MARK: - Send

    private func sendTextInput() {
        let text = textInput
        textInput = ""
        Task { await viewModel.sendText(text) }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            // Status pill
            HStack(spacing: 5) {
                Circle()
                    .fill(viewModel.isConnected ? .green : .red)
                    .frame(width: 7, height: 7)
                Text(viewModel.connectionMode == .channel ? "⚡" : "🌐")
                    .font(.system(size: 9))
                Image(systemName: viewModel.activeFrameSource.icon)
                    .font(.system(size: 10))
                    .foregroundColor(frameSourceColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(14)

            // State pill
            HStack(spacing: 4) {
                stateIcon
                    .font(.system(size: 10))
                    .foregroundColor(stateColor)
                Text(viewModel.state.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(14)

            if viewModel.isProcessing {
                ProgressView()
                    .tint(.orange)
                    .scaleEffect(0.7)
            }

            Spacer()

            // Settings
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 0) {
            // Reset
            Button {
                Task { await viewModel.resetConversation() }
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 18))
                    Text("Reset")
                        .font(.system(size: 9))
                }
                .foregroundColor(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
            }

            // Mic button — also stops speaking when tapped during playback
            Button {
                if viewModel.state == .speaking {
                    // Interrupt Claude — stop talking and start listening
                    viewModel.interruptSpeaking()
                } else if viewModel.isConnected {
                    viewModel.toggleListening()
                } else {
                    Task { await viewModel.connect() }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(micButtonColor)
                        .frame(width: 68, height: 68)
                        .shadow(color: micButtonColor.opacity(0.4), radius: 8)

                    if viewModel.isProcessing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: micButtonIcon)
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // Source toggle
            Button {
                viewModel.activeFrameSource = viewModel.activeFrameSource == .iPhone ? .rayBan : .iPhone
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: viewModel.activeFrameSource.icon)
                        .font(.system(size: 18))
                        .foregroundColor(frameSourceColor)
                    Text(viewModel.activeFrameSource == .iPhone ? "iPhone" : "Glasses")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var stateIcon: some View {
        switch viewModel.state {
        case .disconnected: Image(systemName: "wifi.slash")
        case .idle: Image(systemName: "checkmark")
        case .listening: Image(systemName: "waveform")
        case .thinking: Image(systemName: "brain")
        case .speaking: Image(systemName: "speaker.wave.2")
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .disconnected: return .red
        case .idle: return .green
        case .listening: return .orange
        case .thinking: return .yellow
        case .speaking: return .blue
        }
    }

    private var micButtonColor: Color {
        switch viewModel.state {
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .blue
        default: return viewModel.isConnected ? Color(red: 1.0, green: 0.58, blue: 0.0) : .gray
        }
    }

    private var micButtonIcon: String {
        switch viewModel.state {
        case .listening: return "mic.fill"
        case .thinking: return "ellipsis"
        case .speaking: return "stop.fill"  // Tap to interrupt
        case .disconnected: return "wifi.slash"
        default: return "mic"
        }
    }

    private var frameSourceColor: Color {
        switch viewModel.frameSourceStatus {
        case .connected: return .green
        case .connecting: return .yellow
        case .error: return .red
        default: return .white.opacity(0.6)
        }
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
