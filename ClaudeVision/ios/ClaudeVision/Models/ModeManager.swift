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
