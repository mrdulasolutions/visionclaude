import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera

@MainActor
class RayBanManager: NSObject, ObservableObject, FrameSource {

    // MARK: - FrameSource Protocol

    @Published var latestFrame: Data?
    @Published var latestImage: UIImage?
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: FrameSourceStatus = .disconnected
    @Published var frameCount: Int = 0

    let sourceType: FrameSourceType = .rayBan

    // MARK: - State

    @Published var glassesName: String = "Not Connected"
    @Published var hasActiveDevice: Bool = false
    @Published var registrationState: String = "unregistered"
    @Published var isRegistered: Bool = false

    // Live diagnostics (surfaced on-screen so failures are visible without Xcode)
    @Published var cameraPermission: String = "unknown"
    @Published var streamState: String = "—"
    @Published var lastError: String = ""
    @Published var datDeviceCount: Int = 0
    @Published var deviceCompatibility: String = "—"
    @Published var deviceLinkState: String = "—"

    // DAT SDK
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var deviceSelector: (any DeviceSelector)?
    private var stateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var errorToken: AnyListenerToken?
    private var deviceMonitorTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var sessionErrorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var streamAdded = false

    /// Video preset from Settings: "fullhd" | "hfr" | "hires" — applied on the next stream start.
    var videoPreset: String = "fullhd"

    private var frameInterval: TimeInterval = 1.0
    private var jpegQuality: CGFloat = 0.5
    private var lastCaptureTime: Date = .distantPast

    // MARK: - SDK Availability

    /// Wearables.shared traps if accessed before a successful Wearables.configure(),
    /// which fails on the simulator — every SDK entry point must check this first.
    static private(set) var isSDKAvailable = false

    static func configureSDK() {
        do {
            try Wearables.configure()
            isSDKAvailable = true
            print("[App] DAT SDK configured")
        } catch {
            print("[App] DAT SDK configuration failed: \(error)")
        }
    }

    // MARK: - Configuration

    func configure(frameInterval: TimeInterval = 1.0, jpegQuality: CGFloat = 0.5) {
        self.frameInterval = frameInterval
        self.jpegQuality = jpegQuality
    }

    // MARK: - Registration (MUST complete before streaming)

    func startMonitoringRegistration() {
        guard Self.isSDKAvailable else {
            registrationState = "unavailable"
            return
        }
        // The DAT SDK's CBCentralManager powers on asynchronously after
        // configure(); touching Wearables APIs in the first moments races it
        // and logs "API MISUSE: can only accept this command while in the
        // powered on state" / "XPC connection invalid". Give the Bluetooth
        // stack a beat before the first call.
        registrationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            let wearables = Wearables.shared

            // Current state first, then follow the stream.
            switch wearables.registrationState {
            case .registered:
                isRegistered = true
                registrationState = "registered"
            case .registering:
                registrationState = "registering"
            case .available, .unavailable:
                registrationState = "unregistered"
            @unknown default:
                break
            }

            for await state in wearables.registrationStateStream() {
                switch state {
                case .registered:
                    self.registrationState = "registered"
                    self.isRegistered = true
                    print("[RayBan] Registration complete")
                    // Paired glasses at rest are STANDBY from the moment the
                    // app launches — before this, the status stayed
                    // "Disconnected" until the first stream ran, which made a
                    // healthy connection look broken on the main screen.
                    if !self.isRunning, case .disconnected = self.connectionStatus,
                       !Wearables.shared.devices.isEmpty {
                        self.connectionStatus = .standby
                    }
                case .registering:
                    self.registrationState = "registering"
                    print("[RayBan] Registration in progress...")
                case .available, .unavailable:
                    self.registrationState = "unregistered"
                    self.isRegistered = false
                    print("[RayBan] Not registered")
                @unknown default:
                    break
                }
            }
        }
    }

    func register() async {
        guard Self.isSDKAvailable else {
            connectionStatus = .error("Glasses are not supported on this device.")
            return
        }
        guard !isRegistered else {
            print("[RayBan] Already registered")
            return
        }

        do {
            print("[RayBan] Starting registration with Meta AI...")
            connectionStatus = .connecting
            try await Wearables.shared.startRegistration()
        } catch {
            print("[RayBan] Registration error: \(error)")
            connectionStatus = .error("Registration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - FrameSource Implementation

    func start() throws {
        guard !isRunning else { return }

        guard Self.isSDKAvailable else {
            connectionStatus = .error("Glasses are not supported on this device.")
            return
        }

        // Re-check registration state directly from SDK
        let currentState = Wearables.shared.registrationState
        if currentState == .registered {
            isRegistered = true
            registrationState = "registered"
        }

        guard isRegistered else {
            print("[RayBan] Not registered (state: \(currentState)) — starting registration first")
            connectionStatus = .error("Tap 'Connect Glasses' in Settings to register with Meta AI first")
            Task { await register() }
            return
        }

        connectionStatus = .connecting
        print("[RayBan] Starting device session...")

        // ORDER MATTERS: the camera stream capability is permission-gated — addStream()
        // returns nil until camera permission is granted (SDK: "streaming status is set
        // to stopped if permission is not granted"). So request permission FIRST, then
        // build the session and add the stream. (Previously permission was requested
        // AFTER addStream, so addStream always returned nil and the code returned early
        // before ever asking — a deadlock.)
        Task { @MainActor in
            guard await self.ensureCameraPermission() else { return }
            self.buildAndStartSession()
        }
    }

    /// Checks camera permission and requests it if needed (opens Meta AI). Returns true when
    /// the stream may proceed (granted, or a permission-check error under Developer Mode).
    private func ensureCameraPermission() async -> Bool {
        let wearables = Wearables.shared
        do {
            print("[RayBan] Checking camera permission...")
            let status = try await wearables.checkPermissionStatus(.camera)
            print("[RayBan] Camera permission status: \(status)")
            self.cameraPermission = "\(status)"
            if status == .granted { return true }

            print("[RayBan] Requesting camera permission (will open Meta AI)...")
            let result = try await wearables.requestPermission(.camera)
            print("[RayBan] Permission result: \(result)")
            self.cameraPermission = "\(result)"
            if result == .granted { return true }

            print("[RayBan] Camera permission denied by user")
            self.connectionStatus = .error("Camera permission denied. Grant in Meta AI app.")
            return false
        } catch {
            print("[RayBan] Permission error: \(error)")
            self.cameraPermission = "error: \(error.localizedDescription)"
            // Developer Mode may bypass permissions — proceed and let the stream verdict decide.
            print("[RayBan] Proceeding despite permission error (Developer Mode may bypass)...")
            return true
        }
    }

    /// Builds and starts the camera stream. Camera permission must already be resolved.
    /// Correct DAT ordering (per SDK sample): createSession → deviceSession.start() →
    /// wait for session state `.started` → addStream() → stream.start().
    /// addStream() returns nil if called before the session is `.started`.
    private func buildAndStartSession() {
        streamAdded = false

        // TEST: allow voice to keep using the Meta glasses microphone (Bluetooth HFP) while
        // the camera streams, to check whether the two can actually coexist. If the camera
        // session starts dropping again, flip this back to `true` — the reservation mechanism
        // in AudioSessionManager is retained.
        AudioSessionManager.shared.reserveGlassesForCamera = false

        let wearables = Wearables.shared

        // Resolve a concrete device. A SpecificDeviceSelector bound to a known id avoids
        // AutoDeviceSelector's async selection race, which threw `noEligibleDevice` when
        // createSession ran before the selector had picked a device.
        let knownDevices = wearables.devices
        self.datDeviceCount = knownDevices.count
        print("[RayBan] DAT known devices: \(knownDevices.count)")

        guard let deviceId = knownDevices.first else {
            self.deviceCompatibility = "DAT sees no device"
            self.deviceLinkState = "—"
            print("[RayBan] DAT sees NO device — cannot stream")
            connectionStatus = .error("Glasses not available. Check the Meta AI app connection.")
            return
        }

        if let device = wearables.deviceForIdentifier(deviceId) {
            let compat = device.compatibility()
            self.glassesName = device.nameOrId()
            self.deviceCompatibility = compat.displayString
            self.deviceLinkState = "\(device.linkState)"
            print("[RayBan] Device '\(device.nameOrId())' type=\(device.deviceType().rawValue) link=\(device.linkState) compatibility=\(compat.displayString)")
            if compat != .compatible {
                self.lastError = "Compatibility: \(compat.displayString)"
            }
        }

        let selector = SpecificDeviceSelector(device: deviceId)
        self.deviceSelector = selector

        // Create the session, then START it. The stream can only be added once the
        // session reaches `.started`.
        let deviceSession: DeviceSession
        do {
            deviceSession = try wearables.createSession(deviceSelector: selector)
        } catch {
            print("[RayBan] createSession failed: \(error)")
            self.lastError = "Session: \(error)"
            connectionStatus = .error("Failed to start glasses session: \(error.localizedDescription)")
            return
        }
        self.deviceSession = deviceSession

        // Observe session state + errors BEFORE start(), so we never miss the `.started`
        // transition and so any DeviceSessionError explaining a stop is captured.
        sessionStateTask = Task { @MainActor in
            for await state in deviceSession.stateStream() {
                print("[RayBan] Session state: \(state)")
                switch state {
                case .started:
                    self.addStreamOnce(to: deviceSession)
                case .stopped:
                    self.connectionStatus = .disconnected
                default:
                    self.connectionStatus = .connecting
                }
            }
        }

        sessionErrorTask = Task { @MainActor in
            for await err in deviceSession.errorStream() {
                print("[RayBan] Session ERROR: \(err)")
                self.lastError = "Session error: \(err)"
                if err == .datAppOnTheGlassesUpdateRequired {
                    // A camera-access app runs ON the glasses (separate from firmware) and it's
                    // out of date — the SDK stops the session until it's updated. Send the user
                    // straight to the update flow in Meta AI.
                    self.connectionStatus = .error("Glasses app update required — opening Meta AI to update.")
                    print("[RayBan] Opening DAT glasses-app update flow...")
                    try? await Wearables.shared.openDATGlassesAppUpdate()
                } else {
                    self.connectionStatus = .error("Glasses session error: \(err)")
                }
            }
        }

        // Monitor device availability
        deviceMonitorTask = Task { @MainActor in
            for await device in selector.activeDeviceStream() {
                self.hasActiveDevice = device != nil
            }
        }

        // Now start the session — the observers above fire addStream on `.started`.
        do {
            try deviceSession.start()
            print("[RayBan] Device session start() called")
        } catch {
            print("[RayBan] Device session start failed: \(error)")
            self.lastError = "Session start: \(error)"
            connectionStatus = .error("Could not start glasses session: \(error.localizedDescription)")
            return
        }
    }

    /// Adds the camera stream to an already-`.started` session, wires listeners, starts it.
    private func addStreamOnce(to deviceSession: DeviceSession) {
        guard !streamAdded else { return }
        // Preset → DAT stream parameters. The SDK offers resolution
        // (high/medium/low) and frame rate only — stabilisation and clip
        // length are native Meta capture features it does not expose.
        let config: StreamConfiguration
        switch videoPreset {
        case "hfr":   config = StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 60)
        case "hires": config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 24)
        default:      config = StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 30)
        }
        print("[RayBan] Stream config: preset=\(videoPreset) resolution=\(config.resolution) fps=\(config.frameRate)")
        let session: MWDATCamera.Stream
        do {
            guard let stream = try deviceSession.addStream(config: config) else {
                print("[RayBan] addStream returned nil (after .started)")
                self.lastError = "addStream returned nil"
                connectionStatus = .error("Failed to add camera stream")
                return
            }
            session = stream
        } catch {
            print("[RayBan] addStream threw: \(error)")
            self.lastError = "addStream: \(error)"
            connectionStatus = .error("Failed to add camera stream: \(error.localizedDescription)")
            return
        }
        streamAdded = true
        self.stream = session
        attachStreamListeners(session)
        session.start()
        print("[RayBan] Stream start() called, state: \(session.state)")
    }

    /// Wires up the camera stream's state / frame / error listeners.
    private func attachStreamListeners(_ session: MWDATCamera.Stream) {
        stateToken = session.statePublisher.listen { [weak self] (state: StreamState) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[RayBan] State: \(state)")
                self.streamState = "\(state)"
                switch state {
                case .streaming:
                    self.isRunning = true
                    self.connectionStatus = .connected
                case .stopped:
                    self.isRunning = false
                    self.connectionStatus = .disconnected
                case .waitingForDevice:
                    self.connectionStatus = .connecting
                case .starting:
                    self.connectionStatus = .connecting
                case .stopping:
                    self.connectionStatus = .connecting
                case .paused:
                    self.connectionStatus = .connecting
                }
            }
        }

        frameToken = session.videoFramePublisher.listen { [weak self] (videoFrame: VideoFrame) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let uiImage = videoFrame.makeUIImage() else { return }
                self.latestImage = uiImage
                self.frameCount += 1
                let now = Date()
                if now.timeIntervalSince(self.lastCaptureTime) >= self.frameInterval {
                    self.lastCaptureTime = now
                    if let jpegData = uiImage.jpegData(compressionQuality: self.jpegQuality) {
                        self.latestFrame = jpegData
                        print("[RayBan] Captured JPEG frame (\(jpegData.count) bytes)")
                    }
                }
            }
        }

        errorToken = session.errorPublisher.listen { [weak self] (error: StreamError) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = self.formatError(error)
                print("[RayBan] Error: \(msg)")
                self.lastError = msg
                self.connectionStatus = .error(msg)
            }
        }
    }

    /// The glasses' Bluetooth audio vanished — user walked out of range.
    /// Reflect it in the status so the UI doesn't claim a idle-but-ready
    /// connection that isn't there.
    func noteGlassesOutOfRange() {
        guard !isRunning else { return }  // a live stream reports its own failures
        if case .standby = connectionStatus {
            connectionStatus = .disconnected
            print("[RayBan] Glasses out of range — standby → disconnected")
        }
    }

    /// The glasses' Bluetooth audio is back — restore standby so the next
    /// vision question streams without any manual reconnect.
    func noteGlassesReturned() {
        guard !isRunning, isRegistered, !Wearables.shared.devices.isEmpty else { return }
        if case .disconnected = connectionStatus {
            connectionStatus = .standby
            lastError = ""
            print("[RayBan] Glasses back in range — disconnected → standby")
        }
    }

    func stop() {
        // Cancel the observers BEFORE stopping the session. Otherwise the session's
        // async `.stopping` event lands after this method sets .disconnected and
        // strands connectionStatus at .connecting, which blocks the next start.
        stateToken = nil
        frameToken = nil
        errorToken = nil
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil
        sessionErrorTask?.cancel()
        sessionErrorTask = nil
        stream?.stop()
        deviceSession?.stop()
        streamAdded = false
        // A deliberate stop with the glasses still registered is STANDBY, not
        // disconnected — the device is paired and one question away from
        // streaming again. Without this the UI says "Disconnected" whenever
        // the on-demand camera idles out, which reads as a broken connection.
        if isRegistered && datDeviceCount > 0 {
            connectionStatus = .standby
        } else {
            connectionStatus = .disconnected
        }
        // Glasses no longer streaming — allow voice audio to use them again.
        AudioSessionManager.shared.reserveGlassesForCamera = false
        stream = nil
        deviceSession = nil
        deviceSelector = nil
        isRunning = false
        connectionStatus = .disconnected
        latestFrame = nil
        latestImage = nil
        glassesName = "Not Connected"
        hasActiveDevice = false
        streamState = "—"
    }

    func consumeFrame() -> Data? {
        return latestFrame
    }

    func cleanup() {
        stop()
        registrationTask?.cancel()
        registrationTask = nil
    }

    // MARK: - Error Formatting

    private func formatError(_ error: StreamError) -> String {
        switch error {
        case .deviceNotFound: return "Glasses not found. Power on and open hinges."
        case .deviceNotConnected: return "Glasses disconnected. Check Bluetooth."
        case .permissionDenied: return "Camera permission denied. Grant in Meta AI app Settings."
        case .hingesClosed: return "Open the glasses hinges to stream."
        case .thermalCritical: return "Glasses overheating. Streaming paused."
        case .thermalEmergency: return "Glasses too hot. Streaming stopped — let them cool down."
        case .peakPowerShutdown: return "Glasses shut down to protect the battery. Try again shortly."
        case .batteryCritical: return "Glasses battery critically low. Charge to stream."
        case .timeout: return "Connection timed out. Try again."
        case .videoStreamingError: return "Video stream failed. Restart app."
        case .internalError: return "Internal SDK error. Restart app."
        @unknown default: return "Unknown glasses error."
        }
    }

    private func formatSessionError(_ error: Error) -> String {
        guard let sessionError = error as? DeviceSessionError else {
            return "Glasses session error: \(error.localizedDescription)"
        }
        switch sessionError {
        case .noEligibleDevice: return "No compatible glasses found. Power on and open hinges."
        case .sessionAlreadyStopped: return "Glasses session ended. Try again."
        case .sessionAlreadyExists: return "Glasses session already active. Restart app."
        case .sessionIdle: return "Glasses session not started yet. Try again."
        case .capabilityAlreadyActive: return "Camera stream already active."
        case .capabilityNotFound: return "Camera stream unavailable. Restart app."
        case .thermalCritical: return "Glasses overheating. Streaming paused."
        case .thermalEmergency: return "Glasses too hot. Streaming stopped — let them cool down."
        case .peakPowerShutdown: return "Glasses shut down to protect the battery. Try again shortly."
        case .batteryCritical: return "Glasses battery critically low. Charge to stream."
        case .datAppOnTheGlassesUpdateRequired: return "Glasses software update required. Open Meta AI app."
        case .dwaUnavailable: return "Meta AI app unavailable. Install or update it."
        case .unexpectedError(let description): return "Glasses error: \(description)"
        @unknown default: return "Unknown glasses session error."
        }
    }
}
