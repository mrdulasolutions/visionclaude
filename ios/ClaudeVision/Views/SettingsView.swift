import SwiftUI

struct SettingsView: View {
    @Binding var config: ClaudeConfig
    @Binding var activeFrameSource: FrameSourceType
    let isConnected: Bool
    let frameSourceStatus: FrameSourceStatus
    let rayBanManager: RayBanManager
    let onConnect: () -> Void
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
                        Text("Glasses paired but stream not active. Make sure glasses are powered on with hinges open, and Developer Mode is enabled.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }

                Section("Speech") {
                    HStack {
                        Text("Pause Threshold")
                        Spacer()
                        Text("\(config.speechPauseThreshold, specifier: "%.1f")s")
                    }
                    Slider(value: $config.speechPauseThreshold, in: 0.5...3.0, step: 0.5)
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
                    bulletPoint("Meta Ray-Ban Smart Glasses (any model)")
                    bulletPoint("Meta View app installed on this iPhone")
                    bulletPoint("Meta Developer Account")
                    linkButton("Create Developer Account", url: "https://developers.meta.com")

                    Divider()

                    // Step-by-step
                    sectionHeader("Enable Developer Mode", icon: "wrench.and.screwdriver")

                    stepView(1, "Open the Meta View app on your iPhone")
                    stepView(2, "Sign in with your Meta account")
                    stepView(3, "Pair your glasses via Bluetooth (if not already)")
                    stepView(4, "Go to Settings → your glasses → Developer Mode")
                    stepView(5, "Toggle Developer Mode ON")
                    stepView(6, "Restart your glasses:\n• Hold the button for 15 seconds to power off\n• Press the button to power back on")
                    stepView(7, "Return to ClaudeVision and select \"Meta Ray-Ban\" as camera source")

                    Divider()

                    // DAT SDK note
                    sectionHeader("Developer Note", icon: "exclamationmark.triangle")
                    Text("The Meta Device Access Toolkit (DAT) SDK is required for camera frame access. Apply for SDK access through Meta's developer portal. Once you have the SDK, add the framework to the Xcode project and the RayBanManager will handle the integration.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    linkButton("Meta DAT SDK Portal", url: "https://developers.meta.com")

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
