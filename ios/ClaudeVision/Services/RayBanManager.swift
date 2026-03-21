import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera

// ═══════════════════════════════════════════════════════════════════════
// RayBanManager — Meta Ray-Ban Smart Glasses via DAT SDK
// ═══════════════════════════════════════════════════════════════════════
//
// Uses the official Meta Wearables Device Access Toolkit (DAT) SDK.
// SPM: https://github.com/facebook/meta-wearables-dat-ios
//
// PREREQUISITES:
//   1. Register at https://wearables.developer.meta.com
//   2. Create an organization and project
//   3. Add your app's bundle ID to the project
//   4. Pair glasses via Meta View app on iPhone
//   5. Enable Developer Mode in Meta View settings
//
// ═══════════════════════════════════════════════════════════════════════

@MainActor
class RayBanManager: NSObject, ObservableObject, FrameSource {

    // MARK: - FrameSource Protocol

    @Published var latestFrame: Data?
    @Published var latestImage: UIImage? // For live preview display
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: FrameSourceStatus = .disconnected
    @Published var frameCount: Int = 0

    let sourceType: FrameSourceType = .rayBan

    // MARK: - Ray-Ban State

    @Published var glassesName: String = "Not Connected"
    @Published var hasActiveDevice: Bool = false
    @Published var isRegistered: Bool = false

    // DAT SDK
    private var streamSession: StreamSession?
    private var deviceSelector: AutoDeviceSelector?
    private var stateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var deviceMonitorTask: Task<Void, Never>?

    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.5
    private var lastCaptureTime: Date = .distantPast

    // MARK: - Configuration

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.5) {
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
    }

    // MARK: - SDK Initialization

    /// Call once at app launch (before start)
    func initializeSDK() {
        do {
            try Wearables.configure()
        } catch {
            connectionStatus = .error("SDK config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Registration (Pairing)

    func connectGlasses() async {
        do {
            try await Wearables.shared.startRegistration()
        } catch {
            connectionStatus = .error("Registration failed: \(error.localizedDescription)")
        }
    }

    func disconnectGlasses() async {
        do {
            try await Wearables.shared.startUnregistration()
        } catch {
            connectionStatus = .error("Disconnect failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FrameSource Implementation

    func start() throws {
        guard !isRunning else { return }
        connectionStatus = .connecting

        let wearables = Wearables.shared
        let selector = AutoDeviceSelector(wearables: wearables)
        self.deviceSelector = selector

        // Stream at 24fps for smooth preview — we throttle JPEG capture for Claude separately
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )
        let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
        self.streamSession = session

        // Monitor device availability
        deviceMonitorTask = Task { @MainActor in
            for await device in selector.activeDeviceStream() {
                self.hasActiveDevice = device != nil
                if let device {
                    self.glassesName = "Ray-Ban Meta"
                } else {
                    self.glassesName = "Not Connected"
                }
            }
        }

        // Listen for state changes
        stateToken = session.statePublisher.listen { [weak self] (state: StreamSessionState) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .streaming:
                    self.isRunning = true
                    self.connectionStatus = .connected
                case .stopped:
                    self.isRunning = false
                    self.connectionStatus = .disconnected
                    self.latestFrame = nil
                case .waitingForDevice, .starting, .stopping, .paused:
                    self.connectionStatus = .connecting
                @unknown default:
                    break
                }
            }
        }

        // Listen for video frames — update preview on every frame, throttle JPEG for Claude
        frameToken = session.videoFramePublisher.listen { [weak self] (videoFrame: VideoFrame) in
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard let uiImage = videoFrame.makeUIImage() else { return }

                // Always update preview image for smooth display
                self.latestImage = uiImage
                self.frameCount += 1

                // Throttle JPEG capture for Claude (every frameInterval seconds)
                let now = Date()
                if now.timeIntervalSince(self.lastCaptureTime) >= self.frameInterval {
                    self.lastCaptureTime = now
                    if let jpegData = uiImage.jpegData(compressionQuality: self.jpegQuality) {
                        self.latestFrame = jpegData
                    }
                }
            }
        }

        // Listen for errors
        errorToken = session.errorPublisher.listen { [weak self] (error: StreamSessionError) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectionStatus = .error(self.formatError(error))
            }
        }

        // Request camera permission and start
        Task {
            do {
                let status = try await wearables.checkPermissionStatus(.camera)
                if status != .granted {
                    let result = try await wearables.requestPermission(.camera)
                    guard result == .granted else {
                        self.connectionStatus = .error("Camera permission denied")
                        return
                    }
                }
                await session.start()
            } catch {
                self.connectionStatus = .error("Permission error: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        Task {
            await streamSession?.stop()
        }
        stateToken = nil
        frameToken = nil
        errorToken = nil
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        streamSession = nil
        deviceSelector = nil
        isRunning = false
        connectionStatus = .disconnected
        latestFrame = nil
        glassesName = "Not Connected"
        hasActiveDevice = false
    }

    func consumeFrame() -> Data? {
        // Keep the frame available for preview — don't nil it
        let frame = latestFrame
        if frame != nil {
            print("[RayBan] Consuming frame (\(frame!.count) bytes)")
        } else {
            print("[RayBan] No frame available to consume")
        }
        return frame
    }

    // MARK: - Error Formatting

    private func formatError(_ error: StreamSessionError) -> String {
        switch error {
        case .deviceNotFound:
            return "Glasses not found. Make sure they're powered on and paired."
        case .deviceNotConnected:
            return "Glasses disconnected. Check Bluetooth connection."
        case .permissionDenied:
            return "Camera permission denied. Grant access in Settings."
        case .hingesClosed:
            return "Glasses hinges are closed. Open them to stream."
        case .thermalCritical:
            return "Glasses overheating. Streaming paused."
        case .timeout:
            return "Connection timed out. Try again."
        case .videoStreamingError:
            return "Video stream failed. Try restarting."
        case .internalError:
            return "Internal SDK error. Try restarting the app."
        @unknown default:
            return "Unknown glasses error."
        }
    }

    // MARK: - Pairing Instructions

    func showPairingInstructions() -> String {
        return """
        To connect your Meta Ray-Ban glasses:

        1. Register at wearables.developer.meta.com
        2. Install the Meta View app from the App Store
        3. Open Meta View and sign in with your Meta account
        4. Pair your glasses via Bluetooth
        5. Enable Developer Mode:
           • Meta View → Settings → your glasses → Developer Mode → ON
        6. Restart your glasses:
           • Hold the button for 15 seconds to power off
           • Press the button to power back on
        7. Return to ClaudeVision and select "Meta Ray-Ban" as your camera source
        """
    }
}
