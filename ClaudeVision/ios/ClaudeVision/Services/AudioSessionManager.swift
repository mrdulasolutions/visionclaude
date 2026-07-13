import Foundation
import AVFoundation

class AudioSessionManager {
    static let shared = AudioSessionManager()

    /// When true, the Meta Ray-Ban glasses are streaming their camera, so audio MUST stay
    /// on the iPhone. Engaging the glasses over Bluetooth HFP (call mode) is mutually
    /// exclusive with DAT camera streaming — it puts the glasses in a state that kills the
    /// camera session. Set true while the glasses camera is active, false otherwise.
    var reserveGlassesForCamera = false

    private init() {
        setupNotifications()
    }

    /// Configure for voice chat. Uses the glasses' Bluetooth mic when available, UNLESS the
    /// glasses are reserved for camera streaming — in which case all audio stays on the iPhone.
    func configureForVoiceChat() throws {
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
        // Never grab the glasses' mic while they're reserved for camera streaming.
        if reserveGlassesForCamera {
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

    func deactivate() {
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
        case .oldDeviceUnavailable:
            print("[Audio] Audio device disconnected — falling back to iPhone mic")
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
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    try? configureForVoiceChat()
                    NotificationCenter.default.post(name: .audioInterruptionEnded, object: nil)
                }
            }
        @unknown default:
            break
        }
    }
}

extension Notification.Name {
    static let audioInterruptionBegan = Notification.Name("audioInterruptionBegan")
    static let audioInterruptionEnded = Notification.Name("audioInterruptionEnded")
}
