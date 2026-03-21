import Foundation
import Combine

enum FrameSourceType: String, CaseIterable, Identifiable {
    case iPhone = "iPhone Camera"
    case rayBan = "Meta Ray-Ban"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .iPhone: return "camera.fill"
        case .rayBan: return "eyeglasses"
        }
    }
}

@MainActor
protocol FrameSource: AnyObject {
    var latestFrame: Data? { get }
    var isRunning: Bool { get }
    var sourceType: FrameSourceType { get }
    var connectionStatus: FrameSourceStatus { get }
    func start() throws
    func stop()
    func consumeFrame() -> Data?
}

enum FrameSourceStatus {
    case disconnected
    case connecting
    case connected
    case error(String)

    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}
