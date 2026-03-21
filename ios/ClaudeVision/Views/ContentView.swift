import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = SessionViewModel()
    @State private var showSettings = false
    @State private var showTranscript = true
    @State private var textInput = ""
    @State private var hasRequestedPermissions = false

    var body: some View {
        ZStack {
            // Camera preview background
            CameraPreviewView(session: viewModel.cameraManager.captureSession)
                .ignoresSafeArea()

            // Dark overlay for readability
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack {
                // Top bar
                HStack {
                    // Connection status
                    HStack(spacing: 6) {
                        Circle()
                            .fill(viewModel.isConnected ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(viewModel.isConnected ? "Connected" : "Disconnected")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)

                    Spacer()

                    // State indicator
                    stateIndicator

                    Spacer()

                    // Settings button
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                }
                .padding()

                Spacer()

                // Transcript
                if showTranscript {
                    TranscriptView(messages: viewModel.transcript)
                        .frame(maxHeight: 300)
                        .padding(.horizontal)
                }

                // Current transcription (live STT)
                if !viewModel.currentTranscription.isEmpty {
                    Text(viewModel.currentTranscription)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding(.horizontal)
                }

                // Error message
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                }

                // Text input fallback
                HStack {
                    TextField("Type a message...", text: $textInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let text = textInput
                            textInput = ""
                            Task { await viewModel.sendText(text) }
                        }

                    Button {
                        let text = textInput
                        textInput = ""
                        Task { await viewModel.sendText(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(textInput.isEmpty)
                }
                .padding(.horizontal)

                // Bottom controls
                HStack(spacing: 30) {
                    // Transcript toggle
                    Button {
                        showTranscript.toggle()
                    } label: {
                        Image(systemName: showTranscript ? "text.bubble.fill" : "text.bubble")
                            .font(.title2)
                            .foregroundColor(.white)
                    }

                    // Main mic button
                    Button {
                        if viewModel.isConnected {
                            viewModel.toggleListening()
                        } else {
                            Task { await viewModel.connect() }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(micButtonColor)
                                .frame(width: 72, height: 72)
                                .shadow(color: micButtonColor.opacity(0.5), radius: 10)

                            Image(systemName: micButtonIcon)
                                .font(.title)
                                .foregroundColor(.white)
                        }
                    }

                    // Reset conversation
                    Button {
                        Task { await viewModel.resetConversation() }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.title2)
                            .foregroundColor(.white)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(config: $viewModel.config, isConnected: viewModel.isConnected) {
                Task { await viewModel.connect() }
            }
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

    // MARK: - UI Helpers

    private var stateIndicator: some View {
        Group {
            switch viewModel.state {
            case .disconnected:
                Label("Disconnected", systemImage: "wifi.slash")
            case .idle:
                Label("Ready", systemImage: "checkmark.circle")
            case .listening:
                Label("Listening...", systemImage: "waveform")
            case .thinking:
                Label("Thinking...", systemImage: "brain")
            case .speaking:
                Label("Speaking...", systemImage: "speaker.wave.2")
            }
        }
        .font(.caption)
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    private var micButtonColor: Color {
        switch viewModel.state {
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .blue
        default: return viewModel.isConnected ? .green : .gray
        }
    }

    private var micButtonIcon: String {
        switch viewModel.state {
        case .listening: return "mic.fill"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .disconnected: return "wifi.slash"
        default: return "mic"
        }
    }
}

// MARK: - Camera Preview

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        context.coordinator.previewLayer = previewLayer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.previewLayer?.frame = uiView.bounds
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}
