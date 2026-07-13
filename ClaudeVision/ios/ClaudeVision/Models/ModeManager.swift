import Foundation
import Combine

@MainActor
class ModeManager: ObservableObject {
    @Published var activeMode: VisionMode = VisionMode.general
    @Published var allModes: [VisionMode] = []
    @Published var hiddenBuiltInModeIds: Set<String> = []

    private static let customModesKey = "VisionClaude_CustomModes"
    private static let hiddenModesKey = "VisionClaude_HiddenBuiltInModes"
    private static let activeModeKey = "VisionClaude_ActiveModeId"

    init() {
        loadModes()
    }

    // MARK: - Visible Modes (for the selector bar)

    var visibleModes: [VisionMode] {
        allModes.filter { mode in
            if mode.isBuiltIn && hiddenBuiltInModeIds.contains(mode.id) {
                return false
            }
            return true
        }
    }

    // MARK: - Custom Mode Management

    func addCustomMode(name: String, icon: String, color: String, prompt: String, quickActions: [String]) {
        let mode = VisionMode(
            id: "custom_\(UUID().uuidString.prefix(8).lowercased())",
            name: name,
            icon: icon,
            color: color,
            systemPrompt: prompt,
            quickActions: quickActions,
            isBuiltIn: false
        )
        allModes.append(mode)
        saveCustomModes()
    }

    func deleteCustomMode(id: String) {
        allModes.removeAll { $0.id == id && !$0.isBuiltIn }
        if activeMode.id == id {
            activeMode = VisionMode.general
            saveActiveMode()
        }
        saveCustomModes()
    }

    func setActiveMode(_ mode: VisionMode) {
        activeMode = mode
        saveActiveMode()
    }

    func toggleBuiltInModeVisibility(id: String) {
        if hiddenBuiltInModeIds.contains(id) {
            hiddenBuiltInModeIds.remove(id)
        } else {
            hiddenBuiltInModeIds.insert(id)
        }
        saveHiddenModes()
    }

    func isBuiltInModeVisible(_ id: String) -> Bool {
        !hiddenBuiltInModeIds.contains(id)
    }

    // MARK: - Voice Mode Switching

    /// Matches short utterances like "plumber mode", "switch to music mode", or
    /// "qr scanner mode" to a mode. Fuzzy matching tolerates speech-to-text
    /// mishearings ("plumer" still matches Plumber). Returns nil for normal
    /// conversation so it can be sent to Claude as usual.
    func mode(matchingVoiceCommand utterance: String) -> VisionMode? {
        let tokens = utterance.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        // Require the keyword "mode" and a short utterance so ordinary
        // questions that happen to mention a mode name aren't hijacked.
        guard tokens.contains("mode"), tokens.count <= 6 else { return nil }

        let filler: Set<String> = ["mode", "switch", "change", "go", "to", "activate", "enter", "set", "the", "please", "open", "use"]
        let candidate = tokens.filter { !filler.contains($0) }.joined(separator: " ")
        guard !candidate.isEmpty else { return nil }

        if let exact = allModes.first(where: { $0.name.lowercased() == candidate }) {
            return exact
        }

        let scored = allModes
            .map { (mode: $0, distance: Self.editDistance($0.name.lowercased(), candidate)) }
            .min { $0.distance < $1.distance }
        guard let best = scored, best.distance <= max(1, candidate.count / 3) else { return nil }
        return best.mode
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Persistence

    private func loadModes() {
        // Load built-in modes
        var modes = VisionMode.builtInModes

        // Load custom modes
        if let data = UserDefaults.standard.data(forKey: Self.customModesKey),
           let customModes = try? JSONDecoder().decode([VisionMode].self, from: data) {
            modes.append(contentsOf: customModes)
        }

        allModes = modes

        // Load hidden built-in mode IDs
        if let hiddenIds = UserDefaults.standard.stringArray(forKey: Self.hiddenModesKey) {
            hiddenBuiltInModeIds = Set(hiddenIds)
        }

        // Load active mode
        if let activeModeId = UserDefaults.standard.string(forKey: Self.activeModeKey),
           let savedMode = modes.first(where: { $0.id == activeModeId }) {
            activeMode = savedMode
        } else {
            activeMode = VisionMode.general
        }
    }

    private func saveCustomModes() {
        let customModes = allModes.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(customModes) {
            UserDefaults.standard.set(data, forKey: Self.customModesKey)
        }
    }

    private func saveHiddenModes() {
        UserDefaults.standard.set(Array(hiddenBuiltInModeIds), forKey: Self.hiddenModesKey)
    }

    private func saveActiveMode() {
        UserDefaults.standard.set(activeMode.id, forKey: Self.activeModeKey)
    }
}
