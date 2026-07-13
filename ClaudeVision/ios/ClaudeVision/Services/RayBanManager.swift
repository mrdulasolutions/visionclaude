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

    // DAT SDK
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var deviceSelector: AutoDeviceSelector?
    private var sessionStateToken: AnyListenerToken?
    private var sessionErrorToken: AnyListenerToken?
    private var streamStateToken: AnyListenerToken?
    private var frameToken: AnyListenerToken?
    private var streamErrorToken: AnyListenerToken?
    private var deviceMonitorTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?

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
        let wearables = Wearables.shared
        registrationTask = Task { @MainActor in
            for await state in wearables.registrationStateStream() {
                switch state {
                case .registered:
                    self.registrationState = "registered"
                    self.isRegistered = true
                    print("[RayBan] Registration complete")
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

        // Check current state
        let currentState = wearables.registrationState
        switch currentState {
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

        let wearables = Wearables.shared
        let selector = AutoDeviceSelector(wearables: wearables)
        self.deviceSelector = selector

        // Monitor device availability
        deviceMonitorTask = Task { @MainActor in
            for await deviceId in selector.activeDeviceStream() {
                self.hasActiveDevice = deviceId != nil
                if let deviceId {
                    let device = Wearables.shared.deviceForIdentifier(deviceId)
                    self.glassesName = device?.nameOrId() ?? "Ray-Ban Meta"
                    print("[RayBan] Device active: \(self.glassesName)")
                } else {
                    self.glassesName = "No Device"
                    print("[RayBan] No active device")
                }
            }
        }

        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: selector)
        } catch {
            let msg = formatSessionError(error)
            print("[RayBan] Failed to create device session: \(msg)")
            connectionStatus = .error(msg)
            return
        }
        self.deviceSession = session

        // Session state changes — the stream capability can only be attached
        // once the session reaches .started.
        sessionStateToken = session.statePublisher.listen { [weak self] (state: DeviceSessionState) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[RayBan] Session state: \(state)")
                switch state {
                case .started:
                    self.attachStreamIfNeeded()
                case .stopped:
                    self.isRunning = false
                    self.connectionStatus = .disconnected
                case .idle, .starting, .paused, .stopping:
                    break
                @unknown default:
                    break
                }
            }
        }

        // Session errors
        sessionErrorToken = session.errorPublisher.listen { [weak self] (error: DeviceSessionError) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = self.formatSessionError(error)
                print("[RayBan] Session error: \(msg)")
                self.connectionStatus = .error(msg)
            }
        }

        // Request camera permission THEN start (matches VisionClaw pattern)
        Task {
            do {
                print("[RayBan] Checking camera permission...")
                let status = try await wearables.checkPermissionStatus(.camera)
                print("[RayBan] Camera permission status: \(status)")
                if status == .granted {
                    print("[RayBan] Camera permission already granted — starting session")
                    self.startSession(session)
                    return
                }

                print("[RayBan] Requesting camera permission (will open Meta AI)...")
                let result = try await wearables.requestPermission(.camera)
                print("[RayBan] Permission result: \(result)")
                if result == .granted {
                    print("[RayBan] Camera permission granted — starting session")
                    self.startSession(session)
                } else {
                    print("[RayBan] Camera permission denied by user")
                    self.connectionStatus = .error("Camera permission denied. Grant in Meta AI app.")
                }
            } catch {
                print("[RayBan] Permission error: \(error)")
                // Try starting anyway — Developer Mode may bypass permissions
                print("[RayBan] Attempting session start despite permission error...")
                self.startSession(session)
            }
        }
    }

    private func startSession(_ session: DeviceSession) {
        do {
            try session.start()
            print("[RayBan] Session start() returned, state: \(session.state)")
            // If the session was already started before our listener attached,
            // the .started transition won't fire again.
            if session.state == .started {
                attachStreamIfNeeded()
            }
        } catch {
            let msg = formatSessionError(error)
            print("[RayBan] Session start error: \(msg)")
            connectionStatus = .error(msg)
        }
    }

    private func attachStreamIfNeeded() {
        guard stream == nil, let session = deviceSession else { return }

        // Stream at 30fps, high resolution (720x1280)
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .high,
            frameRate: 30
        )

        let newStream: MWDATCamera.Stream
        do {
            guard let created = try session.addStream(config: config) else {
                print("[RayBan] addStream returned nil")
                connectionStatus = .error("Could not start camera stream. Restart app.")
                return
            }
            newStream = created
        } catch {
            let msg = formatSessionError(error)
            print("[RayBan] addStream error: \(msg)")
            connectionStatus = .error(msg)
            return
        }
        self.stream = newStream

        // State changes
        streamStateToken = newStream.statePublisher.listen { [weak self] (state: StreamState) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[RayBan] Stream state: \(state)")
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
                @unknown default:
                    break
                }
            }
        }

        // Video frames
        frameToken = newStream.videoFramePublisher.listen { [weak self] (videoFrame: VideoFrame) in
            Task { @MainActor [weak self] in
                guard let self else { return }

                guard let uiImage = videoFrame.makeUIImage() else { return }

                // Always update preview
                self.latestImage = uiImage
                self.frameCount += 1

                // Throttle JPEG for Claude
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

        // Errors
        streamErrorToken = newStream.errorPublisher.listen { [weak self] (error: StreamError) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let msg = self.formatError(error)
                print("[RayBan] Stream error: \(msg)")
                self.connectionStatus = .error(msg)
            }
        }

        newStream.start()
        print("[RayBan] Stream start() returned, state: \(newStream.state)")
    }

    func stop() {
        stream?.stop()
        deviceSession?.stop()
        streamStateToken = nil
        frameToken = nil
        streamErrorToken = nil
        sessionStateToken = nil
        sessionErrorToken = nil
        deviceMonitorTask?.cancel()
        deviceMonitorTask = nil
        stream = nil
        deviceSession = nil
        deviceSelector = nil
        isRunning = false
        connectionStatus = .disconnected
        latestFrame = nil
        latestImage = nil
        glassesName = "Not Connected"
        hasActiveDevice = false
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
