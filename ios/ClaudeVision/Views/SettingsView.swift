import SwiftUI

struct SettingsView: View {
    @Binding var config: ClaudeConfig
    @Binding var activeFrameSource: FrameSourceType
    let isConnected: Bool
    let frameSourceStatus: FrameSourceStatus
    let rayBanManager: RayBanManager
    let onConnect: () -> Void
    let onConnectGlasses: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var showRayBanInstructions = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway Connection") {
                    HStack {
                        Text("Host")
                        Spacer()
                        TextField("hostname.local", text: $config.gatewayHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("18790", value: $config.gatewayPort, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }

                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Text("Test Connection")
                            Spacer()
                            if isTesting {
                                ProgressView()
                            } else if let result = testResult {
                                Text(result)
                                    .foregroundColor(result.contains("OK") ? .green : .red)
                            }
                        }
                    }
                }

                Section("Camera Source") {
                    Picker("Source", selection: $activeFrameSource) {
                        ForEach(FrameSourceType.allCases) { source in
                            Label(source.rawValue, systemImage: source.icon)
                                .tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(frameSourceStatus.isConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(frameSourceStatus.label)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    HStack {
                        Text("Frame Interval")
                        Spacer()
                        Text("\(config.videoFrameInterval, specifier: "%.1f")s")
                    }
                    Slider(value: $config.videoFrameInterval, in: 0.5...5.0, step: 0.5)

                    HStack {
                        Text("JPEG Quality")
                        Spacer()
                        Text("\(Int(config.videoJPEGQuality * 100))%")
                    }
                    Slider(value: $config.videoJPEGQuality, in: 0.1...1.0, step: 0.1)
                }

                Section("Meta Ray-Ban Glasses") {
                    HStack {
                        Image(systemName: "eyeglasses")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rayBanManager.glassesName)
                            if activeFrameSource == .rayBan {
                                Text("Stream: \(frameSourceStatus.label)")
                                    .font(.caption)
                                    .foregroundColor(frameSourceStatus.isConnected ? .green : .orange)
                            }
                        }
                        Spacer()
                        if rayBanManager.hasActiveDevice {
                            VStack(spacing: 2) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Paired")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                        }
                    }

                    // Registration status
                    HStack {
                        Text("Registration")
                        Spacer()
                        Text(rayBanManager.isRegistered ? "Registered" : "Not Registered")
                            .foregroundColor(rayBanManager.isRegistered ? .green : .orange)
                            .font(.caption)
                    }

                    if !rayBanManager.isRegistered {
                        Button {
                            onConnectGlasses()
                        } label: {
                            HStack {
                                Image(systemName: "link.circle.fill")
                                    .foregroundColor(.orange)
                                Text("Connect Glasses via Meta AI")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }

                    Button {
                        showRayBanInstructions = true
                    } label: {
                        HStack {
                            Text("Setup Instructions")
                            Spacer()
                            Image(systemName: "info.circle")
                        }
                    }

                    if activeFrameSource == .rayBan && !frameSourceStatus.isConnected {
                        if !rayBanManager.isRegistered {
                            Text("Tap 'Connect Glasses via Meta AI' above to register. This will open the Meta AI app for approval.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            Text("Registered but stream not active. Make sure glasses are powered on with hinges open, and Developer Mode is enabled.")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section("Voice") {
                    HStack {
                        Text("Pause Threshold")
                        Spacer()
                        Text("\(config.speechPauseThreshold, specifier: "%.1f")s")
                    }
                    Slider(value: $config.speechPauseThreshold, in: 0.5...3.0, step: 0.5)

                    HStack {
                        Image(systemName: "speaker.wave.3")
                            .foregroundColor(.orange)
                        Text("TTS Provider")
                        Spacer()
                        Text(config.elevenLabsAPIKey.isEmpty ? "Apple (Basic)" : "ElevenLabs")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }

                    HStack {
                        Text("ElevenLabs Key")
                        Spacer()
                        SecureField("API key", text: $config.elevenLabsAPIKey)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if !config.elevenLabsAPIKey.isEmpty {
                        HStack {
                            Text("Voice ID")
                            Spacer()
                            TextField("Voice ID", text: $config.elevenLabsVoiceId)
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.caption)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(isConnected ? "Connected" : "Disconnected")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showRayBanInstructions) {
                RayBanInstructionsView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connect") {
                        onConnect()
                        dismiss()
                    }
                }
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            do {
                let bridge = ClaudeBridge(config: config)
                let health = try await bridge.checkHealth()
                testResult = "OK (\(health.status))"
            } catch {
                testResult = "Failed"
            }
            isTesting = false
        }
    }

}

// MARK: - Ray-Ban Setup Instructions Sheet

struct RayBanInstructionsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack {
                        Image(systemName: "eyeglasses")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        VStack(alignment: .leading) {
                            Text("Meta Ray-Ban Setup")
                                .font(.title2.bold())
                            Text("Developer Mode Configuration")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.bottom, 8)

                    Divider()

                    // Prerequisites
                    sectionHeader("Prerequisites", icon: "checkmark.circle")
                    bulletPoint("Meta Ray-Ban Smart Glasses or Ray-Ban Display glasses")
                    bulletPoint("Meta AI app installed on this iPhone")
                    bulletPoint("Glasses paired and connected via Meta AI app")
                    linkButton("Download Meta AI App", url: "https://apps.apple.com/app/meta-ai/id1662457680")

                    Divider()

                    // Step-by-step
                    sectionHeader("Step 1: Pair Your Glasses", icon: "wave.3.right")

                    stepView(1, "Open the Meta AI app on your iPhone")
                    stepView(2, "Sign in with your Meta account")
                    stepView(3, "Follow the in-app pairing flow to connect your glasses via Bluetooth")
                    stepView(4, "Make sure glasses are fully updated (Meta AI app will prompt if needed)")

                    Divider()

                    sectionHeader("Step 2: Enable Developer Mode", icon: "wrench.and.screwdriver")

                    stepView(5, "In the Meta AI app, go to:\nSettings → Your glasses → Developer Mode")
                    stepView(6, "Toggle Developer Mode ON")
                    stepView(7, "Restart your glasses:\n• Hold the button for 15 seconds to power off\n• Press the button to power back on")

                    Divider()

                    sectionHeader("Step 3: Connect in VisionClaude", icon: "eyeglasses")

                    stepView(8, "Return to VisionClaude")
                    stepView(9, "Go to Settings → Camera Source → select Meta Ray-Ban")
                    stepView(10, "Tap \"Connect\" — VisionClaude will register with Meta AI")
                    stepView(11, "You may be redirected to the Meta AI app to approve the connection — tap Allow")
                    stepView(12, "Once connected, the camera feed from your glasses will appear in VisionClaude")

                    Divider()

                    sectionHeader("Troubleshooting", icon: "questionmark.circle")
                    bulletPoint("No device found: Make sure glasses are powered on with hinges open")
                    bulletPoint("Stream won't start: Check Developer Mode is ON in Meta AI app")
                    bulletPoint("Glasses need update: Open Meta AI app and follow update prompts")
                    bulletPoint("Connection lost: Close and reopen VisionClaude, or restart glasses")
                    linkButton("DAT Developer Docs", url: "https://wearables.developer.meta.com/docs/develop/")
                    linkButton("Community Forum", url: "https://github.com/facebook/meta-wearables-dat-ios/discussions")

                    Spacer(minLength: 40)
                }
                .padding()
            }
            .navigationTitle("Ray-Ban Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .foregroundColor(.orange)
    }

    private func bulletPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.orange)
            Text(text)
                .font(.body)
        }
        .padding(.leading, 4)
    }

    private func stepView(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.orange)
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
            }
            Text(text)
                .font(.body)
        }
        .padding(.leading, 4)
    }

    private func linkButton(_ title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Image(systemName: "arrow.up.right.square")
                Text(title)
            }
            .font(.caption)
            .foregroundColor(.blue)
        }
        .padding(.leading, 16)
    }
}
