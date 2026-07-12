import SwiftUI

/// Live checklist of the Ray-Ban streaming pipeline, in the order the frames must pass through:
/// registration → camera permission → active device → stream state → frames.
/// Surfaced both as a HUD on the camera screen and inside Settings so the failing
/// gate is visible on-device without tailing the Xcode console.
struct RayBanDiagnosticsView: View {
    @ObservedObject var rayBanManager: RayBanManager
    let frameSourceStatus: FrameSourceStatus

    private let accentColor = Color(red: 232/255, green: 123/255, blue: 53/255)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(
                title: "Registered with Meta AI",
                value: rayBanManager.isRegistered ? "Yes" : "No",
                level: rayBanManager.isRegistered ? .ok : .blocked
            )
            row(
                title: "Camera permission",
                value: permissionValue,
                level: permissionLevel
            )
            row(
                title: "Active device (glasses)",
                value: rayBanManager.hasActiveDevice ? "Paired" : "None",
                level: rayBanManager.hasActiveDevice ? .ok : .waiting
            )
            row(
                title: "Stream state",
                value: rayBanManager.streamState,
                level: streamLevel
            )
            row(
                title: "Frames received",
                value: "\(rayBanManager.frameCount)",
                level: rayBanManager.frameCount > 0 ? .ok : .waiting
            )
            if !rayBanManager.lastError.isEmpty {
                row(title: "Last error", value: rayBanManager.lastError, level: .blocked)
            }
        }
    }

    // MARK: - Row

    private enum Level {
        case ok, waiting, blocked

        var color: Color {
            switch self {
            case .ok: return .green
            case .waiting: return .yellow
            case .blocked: return .red
            }
        }

        var icon: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .waiting: return "clock.fill"
            case .blocked: return "xmark.circle.fill"
            }
        }
    }

    private func row(title: String, value: String, level: Level) -> some View {
        HStack(spacing: 10) {
            Image(systemName: level.icon)
                .font(.system(size: 13))
                .foregroundStyle(level.color)
                .frame(width: 16)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    // MARK: - Derived state

    private var permissionValue: String {
        rayBanManager.cameraPermission
    }

    private var permissionLevel: Level {
        let p = rayBanManager.cameraPermission.lowercased()
        if p.contains("grant") { return .ok }
        if p.contains("deny") || p.contains("error") { return .blocked }
        return .waiting
    }

    private var streamLevel: Level {
        let s = rayBanManager.streamState.lowercased()
        if s.contains("streaming") { return .ok }
        if s == "—" || s.contains("stopped") { return .waiting }
        return .waiting
    }
}
