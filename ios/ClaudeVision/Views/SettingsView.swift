import SwiftUI

struct SettingsView: View {
    @Binding var config: ClaudeConfig
    let isConnected: Bool
    let onConnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?
    @State private var isTesting = false

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

                Section("Camera") {
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
