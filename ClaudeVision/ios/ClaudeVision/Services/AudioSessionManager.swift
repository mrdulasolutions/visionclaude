import Foundation
import AVFoundation

class AudioSessionManager {
    static let shared = AudioSessionManager()

    private init() {
        setupNotifications()
    }

    /// Configure for voice chat with Bluetooth mic support (Meta Ray-Ban glasses)
    func configureForVoiceChat() throws {
        let session = AVAudioSession.sharedInstance()

        // .allowBluetooth = HFP (Hands-Free Profile) — enables Bluetooth MIC INPUT
        // .allowBluetoothA2DP = A2DP — high-quality Bluetooth OUTPUT only
        // .defaultToSpeaker = fallback to speaker when no Bluetooth connected
        // We need BOTH for glasses: mic input (HFP) + audio output (A2DP)
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)

        // If Ray-Ban glasses are connected via Bluetooth, prefer their mic
        routeToBluetoothMicIfAvailable()
    }

    /// Route audio input to Bluetooth mic (glasses) if available
    func routeToBluetoothMicIfAvailable() {
        let session = AVAudioSession.sharedInstance()
        guard let availableInputs = session.availableInputs else { return }

        // Look for Bluetooth HFP input (glasses mic)
        for input in availableInputs {
            if input.portType == .bluetoothHFP {
                do {
                    try session.setPreferredInput(input)
                    print("[Audio] Routed mic input to Bluetooth: \(input.portName)")
                } catch {
                    print("[Audio] Failed to route to Bluetooth mic: \(error)")
                }
                return
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
