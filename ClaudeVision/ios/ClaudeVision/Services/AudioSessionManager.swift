import Foundation
import AVFoundation
import UIKit

class AudioSessionManager {
    static let shared = AudioSessionManager()

    /// When true, the Meta Ray-Ban glasses are streaming their camera, so audio MUST stay
    /// on the iPhone. Engaging the glasses over Bluetooth HFP (call mode) is mutually
    /// exclusive with DAT camera streaming — it puts the glasses in a state that kills the
    /// camera session. Set true while the glasses camera is active, false otherwise.
    var reserveGlassesForCamera = false

    /// True while ShazamKit is fingerprinting. Configuring for music capture
    /// tears down the HFP link, which fires a route-change notification — and
    /// the auto-router below would immediately hand the mic back to the
    /// glasses mid-listen, killing the match with ShazamKit error 202. While
    /// this flag is set the input stays on the built-in mic no matter what
    /// routes appear. Set by configureForMusicRecognition(), cleared by
    /// configureForVoiceChat().
    private(set) var musicCaptureActive = false

    private init() {
        setupNotifications()
    }

    /// Configure for voice chat. Uses the glasses' Bluetooth mic when available, UNLESS the
    /// glasses are reserved for camera streaming — in which case all audio stays on the iPhone.
    func configureForVoiceChat() throws {
        musicCaptureActive = false
        let session = AVAudioSession.sharedInstance()

        if reserveGlassesForCamera {
            // Keep ALL audio on the iPhone — no Bluetooth HFP — so the glasses stay free to
            // stream the camera. (HFP call mode would immediately stop the DAT camera session.)
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
            try session.setActive(true)
            routeToBuiltInMic()
            print("[Audio] Glasses reserved for camera — audio kept on iPhone (no HFP)")
            return
        }

        // .allowBluetooth = HFP (Hands-Free Profile) — enables Bluetooth MIC INPUT
        // .allowBluetoothA2DP = A2DP — high-quality Bluetooth OUTPUT only
        // .defaultToSpeaker = fallback to speaker when no Bluetooth connected
        // We need BOTH for glasses: mic input (HFP) + audio output (A2DP)
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setActive(true)

        // If Ray-Ban glasses are connected via Bluetooth, prefer their mic
        routeToBluetoothMicIfAvailable()
        startBackgroundKeepAlive()
    }

    /// True when a Bluetooth mic that looks like the glasses is available to the
    /// session. This is the "glasses are connected" signal that works WITHOUT a
    /// camera stream — RayBanManager's .connected status only fires once a DAT
    /// stream starts, which with on-demand camera can be long after connection.
    static func glassesAudioInputAvailable() -> Bool {
        let inputs = AVAudioSession.sharedInstance().availableInputs ?? []
        return inputs.contains { input in
            input.portType == .bluetoothHFP
                || input.portName.lowercased().contains("ray-ban")
                || input.portName.lowercased().contains("meta")
        }
    }

    /// Reconfigure the session for music fingerprinting (ShazamKit): built-in
    /// mic, default mode, NO Bluetooth HFP. Merely switching the preferred
    /// input isn't enough — with the glasses' HFP link still holding the
    /// output, the split SCO link delivers empty capture buffers
    /// ("mDataByteSize (0) should be non-zero") and Shazam hears nothing.
    /// Dropping HFP entirely moves output to A2DP/speaker and gives the
    /// capture a clean full-bandwidth path. Restore with configureForVoiceChat().
    func configureForMusicRecognition() throws {
        musicCaptureActive = true
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        routeToBuiltInMic()
        print("[Audio] Configured for music recognition (built-in mic, no HFP)")
    }

    /// Force audio input to the built-in iPhone mic (used when glasses are reserved for camera).
    private func routeToBuiltInMic() {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs else { return }
        if let builtIn = inputs.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
            print("[Audio] Mic forced to iPhone: \(builtIn.portName)")
        }
    }

    /// Route audio input to Bluetooth mic (glasses) if available
    func routeToBluetoothMicIfAvailable() {
        // Never grab the glasses' mic while they're reserved for camera
        // streaming, or while ShazamKit is capturing on the built-in mic.
        if reserveGlassesForCamera || musicCaptureActive {
            routeToBuiltInMic()
            return
        }

        let session = AVAudioSession.sharedInstance()
        guard let availableInputs = session.availableInputs else {
            print("[Audio] No available inputs found")
            return
        }

        // Log all available inputs for debugging
        for input in availableInputs {
            print("[Audio] Available input: \(input.portName) type=\(input.portType.rawValue) uid=\(input.uid)")
        }

        // Log current route
        let currentRoute = session.currentRoute
        for input in currentRoute.inputs {
            print("[Audio] Current input route: \(input.portName) type=\(input.portType.rawValue)")
        }
        for output in currentRoute.outputs {
            print("[Audio] Current output route: \(output.portName) type=\(output.portType.rawValue)")
        }

        // Priority order: HFP first (best for mic), then any Bluetooth input
        let bluetoothTypes: [AVAudioSession.Port] = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
        for btType in bluetoothTypes {
            for input in availableInputs {
                if input.portType == btType {
                    do {
                        try session.setPreferredInput(input)
                        print("[Audio] ✅ Routed mic to Bluetooth: \(input.portName) (\(btType.rawValue))")
                        return
                    } catch {
                        print("[Audio] Failed to route to \(input.portName): \(error)")
                    }
                }
            }
        }

        // Also check for Ray-Ban by name as fallback
        for input in availableInputs {
            if input.portName.lowercased().contains("ray-ban") || input.portName.lowercased().contains("meta") {
                do {
                    try session.setPreferredInput(input)
                    print("[Audio] ✅ Routed mic to glasses by name: \(input.portName)")
                    return
                } catch {
                    print("[Audio] Failed to route to \(input.portName): \(error)")
                }
            }
        }

        print("[Audio] No Bluetooth mic found — using iPhone mic")
    }

    // MARK: - Background keep-alive

    /// iOS honours the "audio" background mode only while audio is actively
    /// flowing. This app stops the mic engine between utterances, so locking
    /// the phone during one of those gaps suspends the process — killing the
    /// listening supervisor, the pending restarts, and the glasses HFP link
    /// with it. A silent, infinitely-looping, zero-volume player holds the
    /// session open so the app keeps running with the screen off.
    private var keepAlivePlayer: AVAudioPlayer?

    func startBackgroundKeepAlive() {
        // An interruption (call, Siri, lock-time route change) STOPS the
        // player without releasing it — a stopped keep-alive is no keep-alive,
        // and iOS then refuses kAUStartIO (error 2003329396) to the
        // backgrounded app. Resume rather than bail when it already exists.
        if let existing = keepAlivePlayer {
            if !existing.isPlaying {
                existing.play()
                print("[Audio] Background keep-alive resumed")
            }
            return
        }
        // One second of 16-bit mono silence at 8 kHz, built in memory.
        let sampleRate = 8000
        let sampleCount = sampleRate
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + sampleCount * 2).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian)   // PCM
        append(UInt16(1).littleEndian)   // mono
        append(UInt32(sampleRate).littleEndian)
        append(UInt32(sampleRate * 2).littleEndian)
        append(UInt16(2).littleEndian)   // block align
        append(UInt16(16).littleEndian)  // bits per sample
        data.append(contentsOf: Array("data".utf8)); append(UInt32(sampleCount * 2).littleEndian)
        data.append(Data(count: sampleCount * 2))

        keepAlivePlayer = try? AVAudioPlayer(data: data)
        keepAlivePlayer?.numberOfLoops = -1
        keepAlivePlayer?.volume = 0
        keepAlivePlayer?.play()
        print("[Audio] Background keep-alive engaged (silent loop)")
    }

    func stopBackgroundKeepAlive() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
        print("[Audio] Background keep-alive released")
    }

    func deactivate() {
        stopBackgroundKeepAlive()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // Monitor audio route changes (glasses connect/disconnect)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // Entering background with a stopped keep-alive is unrecoverable
        // (audio can't be re-activated from the background) — make this the
        // final checkpoint before the screen goes dark.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            try? AVAudioSession.sharedInstance().setActive(true)
            self?.startBackgroundKeepAlive()
        }
    }

    @objc private func handleRouteChange(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        switch reason {
        case .newDeviceAvailable:
            // New Bluetooth device connected — try to route mic to it
            print("[Audio] New audio device connected")
            routeToBluetoothMicIfAvailable()
            if Self.glassesAudioInputAvailable() {
                NotificationCenter.default.post(name: .glassesAudioConnected, object: nil)
            }
            NotificationCenter.default.post(name: .audioInputRouteChanged, object: nil)
            startBackgroundKeepAlive()
        case .oldDeviceUnavailable:
            print("[Audio] Audio device disconnected — falling back to iPhone mic")
            NotificationCenter.default.post(name: .audioInputRouteChanged, object: nil)
            startBackgroundKeepAlive()
        default:
            break
        }
    }

    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            NotificationCenter.default.post(name: .audioInterruptionBegan, object: nil)
        case .ended:
            // Restore the session and keep-alive even when iOS omits the
            // shouldResume hint (common after Siri/lock interruptions) — a
            // lapsed keep-alive means the next backgrounding suspends the app
            // beyond recovery (kAUStartIO 2003329396 until foregrounded).
            try? configureForVoiceChat()
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
            }
        @unknown default:
            break
        }
    }
}

extension Notification.Name {
    static let audioInterruptionBegan = Notification.Name("audioInterruptionBegan")
    static let audioInterruptionEnded = Notification.Name("audioInterruptionEnded")
    static let glassesAudioConnected = Notification.Name("glassesAudioConnected")
    static let audioInputRouteChanged = Notification.Name("audioInputRouteChanged")
}
