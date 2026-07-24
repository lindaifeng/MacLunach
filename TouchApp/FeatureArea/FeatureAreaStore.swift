import AppKit
import Foundation
import FinderFeature
import PomodoroFeature
import ScreenshotFeature
import SuperRightFeature
import SwiftUI
import TouchCore
import TouchFeatureAPI
import TranslationFeature

enum LauncherCustomActionKind: String, Codable, CaseIterable, Identifiable {
    case application
    case file
    case folder
    case webPage
    case shortcut
    case shellScript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: "应用"
        case .file: "文件"
        case .folder: "文件夹"
        case .webPage: "网页"
        case .shortcut: "快捷指令"
        case .shellScript: "Shell 脚本"
        }
    }

    var symbolName: String {
        switch self {
        case .application: "app.dashed"
        case .file: "doc"
        case .folder: "folder"
        case .webPage: "globe"
        case .shortcut: "sparkles"
        case .shellScript: "terminal"
        }
    }
}

struct LauncherCustomAction: Codable, Equatable {
    let kind: LauncherCustomActionKind
    let title: String
    let target: String

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? kind.title : trimmedTitle
    }
}

@MainActor
final class FeatureAreaStore: ObservableObject {
    @Published private(set) var plugins: [any FeaturePlugin]
    @Published private(set) var preferences: FeaturePreferences
    @Published private(set) var states: [String: FeatureState] = [:]
    @Published private(set) var configurations: FeatureConfigurations
    @Published private(set) var customKeyActions: [String: LauncherCustomAction]
    @Published private(set) var globalShortcuts: [String: TouchFeatureAPI.KeyboardShortcut]
    @Published private(set) var globalShortcutRegistrationErrors: [String: String] = [:]

    private let preferencesStore: FeaturePreferencesStore
    private let configurationStore: FeatureConfigurationStore
    private let registry: FeatureRegistry
    private let notificationCenter: NotificationCenter
    private let defaults: UserDefaults

    private static let customActionsDefaultsKey = "launcher.custom-key-actions.v1"
    private static let globalShortcutsDefaultsKey = "feature.global-shortcuts.v1"
    private static let legacyCommandGlobalShortcutDefaultsSeededKey = "feature.global-shortcuts.command-defaults-seeded-v1"
    private static let previousCommandGlobalShortcutDefaultsSeededKey = "feature.global-shortcuts.command-defaults-seeded-v2"
    private static let globalShortcutDefaultsSeededKey = "feature.global-shortcuts.option-defaults-seeded-v3"
    private static let supportedLauncherKeys = [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=",
        "q", "w", "e", "r", "t", "y", "u", "i", "o", "p",
        "a", "s", "d", "f", "g", "h", "j", "k", "l",
        "z", "x", "c", "v", "b", "n", "m"
    ]

    init(
        defaults: UserDefaults = .standard,
        plugins: [any FeaturePlugin],
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        preferencesStore = FeaturePreferencesStore(defaults: defaults)
        configurationStore = FeatureConfigurationStore(defaults: defaults)
        self.notificationCenter = notificationCenter
        let loadedPreferences = (try? preferencesStore.load()) ?? .init()
        preferences = loadedPreferences
        configurations = configurationStore.load()
        customKeyActions = Self.loadCustomActions(defaults: defaults)
        globalShortcuts = Self.loadGlobalShortcuts(
            defaults: defaults,
            plugins: plugins,
            launcherShortcuts: loadedPreferences.shortcuts
        )

        registry = FeatureRegistry(plugins: plugins, preferences: loadedPreferences)
        let storedOrder = Dictionary(uniqueKeysWithValues: loadedPreferences.order.enumerated().map { ($1, $0) })
        self.plugins = plugins.sorted {
            let left = storedOrder[$0.manifest.id] ?? (loadedPreferences.order.count + $0.manifest.defaultOrder)
            let right = storedOrder[$1.manifest.id] ?? (loadedPreferences.order.count + $1.manifest.defaultOrder)
            return left < right
        }
        Task { [weak self] in await self?.loadStates() }
    }

    var visiblePlugins: [any FeaturePlugin] {
        plugins.filter {
            !preferences.hidden.contains($0.manifest.id)
                && !preferences.disabled.contains($0.manifest.id)
        }
    }

    var launcherCustomActionKeys: [String] {
        Self.supportedLauncherKeys.filter { customKeyActions[$0] != nil }
    }

    func isEnabled(_ featureID: String) -> Bool {
        !preferences.disabled.contains(featureID)
    }

    func shortcut(for featureID: String) -> TouchFeatureAPI.KeyboardShortcut {
        if let shortcut = preferences.shortcuts[featureID] {
            return .init(modifiers: [], key: shortcut.key)
        }
        let key = plugins.first(where: { $0.manifest.id == featureID })?.manifest.defaultShortcut.key ?? ""
        return .init(modifiers: [], key: key)
    }

    func featureID(forLauncherKey key: String) -> String? {
        let normalizedKey = key.lowercased()
        guard customKeyActions[normalizedKey] == nil else { return nil }
        return visiblePlugins.first(where: {
            shortcut(for: $0.manifest.id).key == normalizedKey
        })?.manifest.id
    }

    func customAction(forLauncherKey key: String) -> LauncherCustomAction? {
        customKeyActions[key.lowercased()]
    }

    func globalShortcut(for featureID: String) -> TouchFeatureAPI.KeyboardShortcut? {
        globalShortcuts[featureID]
    }

    func hasLauncherAssignment(for key: String) -> Bool {
        customAction(forLauncherKey: key) != nil || featureID(forLauncherKey: key) != nil
    }

    func searchLauncherActions(query: String) -> [SearchResult] {
        let featureResults = visiblePlugins.map { plugin in
            let key = shortcut(for: plugin.manifest.id).key.uppercased()
            return SearchResult(
                id: "action.feature.\(plugin.manifest.id)",
                title: plugin.manifest.name,
                subtitle: "内置功能 · \(key) 键",
                iconCacheKey: plugin.manifest.id,
                pinyin: plugin.manifest.summary,
                initials: key,
                kind: .action,
                baseScore: 20
            )
        }
        let customResults = customKeyActions.map { key, action in
            SearchResult(
                id: "action.custom.\(key)",
                title: action.displayTitle,
                subtitle: "\(action.kind.title) · \(key.uppercased()) 键",
                path: action.localIconPath,
                iconCacheKey: "custom.\(key).\(action.target)",
                pinyin: action.kind.title,
                initials: key,
                strictSearchTerms: [action.target],
                kind: .action,
                baseScore: 10
            )
        }
        return SearchRanking.sort(featureResults + customResults, query: query)
    }

    func performLauncherSearchResult(_ result: SearchResult) {
        let featurePrefix = "action.feature."
        let customPrefix = "action.custom."
        if result.id.hasPrefix(featurePrefix) {
            let featureID = String(result.id.dropFirst(featurePrefix.count))
            Task { await perform(featureID) }
        } else if result.id.hasPrefix(customPrefix) {
            let key = String(result.id.dropFirst(customPrefix.count))
            Task { await performLauncherKey(key) }
        }
    }

    func move(_ sourceID: String, before destinationID: String, animated: Bool) {
        guard sourceID != destinationID,
              let source = plugins.firstIndex(where: { $0.manifest.id == sourceID }),
              let destination = plugins.firstIndex(where: { $0.manifest.id == destinationID }) else { return }

        let updateOrder = {
            let plugin = self.plugins.remove(at: source)
            let adjustedDestination = source < destination ? destination - 1 : destination
            self.plugins.insert(plugin, at: max(0, adjustedDestination))
        }
        if animated {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82), updateOrder)
        } else {
            updateOrder()
        }
        persistOrder()
        Task {
            await registry.move(from: source, to: source < destination ? destination - 1 : destination)
        }
    }

    func setHidden(_ hidden: Bool, for featureID: String) {
        if hidden {
            preferences.hidden.insert(featureID)
        } else {
            preferences.hidden.remove(featureID)
        }
        persist()
        Task { try? await registry.setVisibility(!hidden, for: featureID) }
    }

    func setEnabled(_ enabled: Bool, for featureID: String) async {
        do {
            try await registry.setEnabled(enabled, for: featureID)
            if enabled {
                preferences.disabled.remove(featureID)
            } else {
                preferences.disabled.insert(featureID)
            }
            persist()
        } catch {
            // Unknown plugins cannot be changed by the settings UI.
        }
        await refreshStates()
        notificationCenter.post(name: .featureGlobalShortcutsDidChange, object: featureID)
    }

    func updateFinderConfiguration<Value>(
        _ keyPath: WritableKeyPath<FinderFeatureConfiguration, Value>,
        to value: Value
    ) {
        configurations.finder[keyPath: keyPath] = value
        try? configurationStore.save(configurations.finder)
    }

    func updateScreenshotConfiguration<Value>(
        _ keyPath: WritableKeyPath<ScreenshotFeatureConfiguration, Value>,
        to value: Value
    ) {
        configurations.screenshot[keyPath: keyPath] = value
        try? configurationStore.save(configurations.screenshot)
    }

    func updateScreenshotModeShortcut(
        _ shortcut: TouchFeatureAPI.KeyboardShortcut,
        for mode: ScreenshotCaptureMode
    ) -> String? {
        guard !shortcut.modifiers.isEmpty else {
            return "截图快捷键必须包含修饰键"
        }
        if let conflict = plugins.first(where: { self.shortcut(for: $0.manifest.id) == shortcut }) {
            return "与“\(conflict.manifest.name)”的快捷键冲突"
        }
        if let conflict = configurations.screenshot.modeShortcuts.first(where: {
            $0.key != mode && $0.value == shortcut
        }) {
            return "与“\(conflict.key.settingsTitle)”快捷键冲突"
        }
        if let conflict = globalShortcuts.first(where: { $0.value == shortcut }),
           let plugin = plugins.first(where: { $0.manifest.id == conflict.key }) {
            return "与“\(plugin.manifest.name)”的快捷键冲突"
        }

        configurations.screenshot.modeShortcuts[mode] = shortcut
        try? configurationStore.save(configurations.screenshot)
        notificationCenter.post(name: .screenshotShortcutsDidChange, object: nil)
        return nil
    }

    func updateGlobalShortcut(
        _ shortcut: TouchFeatureAPI.KeyboardShortcut,
        for featureID: String
    ) -> String? {
        guard plugins.contains(where: { $0.manifest.id == featureID }) else {
            return "未找到要设置的功能"
        }
        guard (1...2).contains(shortcut.modifiers.count), !shortcut.key.isEmpty else {
            return "快捷键需要一个主键和一至两个修饰键"
        }
        guard (try? HotKeyMapping.carbonValue(for: shortcut)) != nil else {
            return "这个主键暂不支持全局快捷键"
        }
        if LauncherShortcutPreferences.load(defaults: defaults) == shortcut {
            return "与启动器呼出快捷键冲突"
        }
        if let conflict = globalShortcuts.first(where: {
            $0.key != featureID && $0.value == shortcut
        }), let plugin = plugins.first(where: { $0.manifest.id == conflict.key }) {
            return "与“\(plugin.manifest.name)”的快捷键冲突"
        }
        if let conflict = configurations.screenshot.modeShortcuts.first(where: {
            $0.value == shortcut
        }) {
            return "与“\(conflict.key.settingsTitle)”快捷键冲突"
        }

        globalShortcuts[featureID] = shortcut
        globalShortcutRegistrationErrors.removeValue(forKey: featureID)
        persistGlobalShortcuts()
        notificationCenter.post(name: .featureGlobalShortcutsDidChange, object: featureID)
        return nil
    }

    func removeGlobalShortcut(for featureID: String) {
        guard globalShortcuts.removeValue(forKey: featureID) != nil else { return }
        globalShortcutRegistrationErrors.removeValue(forKey: featureID)
        persistGlobalShortcuts()
        notificationCenter.post(name: .featureGlobalShortcutsDidChange, object: featureID)
    }

    func validateLauncherShortcut(_ shortcut: TouchFeatureAPI.KeyboardShortcut) -> String? {
        if let conflict = globalShortcuts.first(where: { $0.value == shortcut }),
           let plugin = plugins.first(where: { $0.manifest.id == conflict.key }) {
            return "与“\(plugin.manifest.name)”的快捷键冲突"
        }
        if let conflict = configurations.screenshot.modeShortcuts.first(where: {
            $0.value == shortcut
        }) {
            return "与“\(conflict.key.settingsTitle)”快捷键冲突"
        }
        return nil
    }

    func setGlobalShortcutRegistrationError(_ message: String?, for featureID: String) {
        if let message {
            globalShortcutRegistrationErrors[featureID] = message
        } else {
            globalShortcutRegistrationErrors.removeValue(forKey: featureID)
        }
    }

    func updateShortcut(_ shortcut: TouchFeatureAPI.KeyboardShortcut, for featureID: String) -> String? {
        let shortcut = TouchFeatureAPI.KeyboardShortcut(modifiers: [], key: shortcut.key)
        if let conflict = plugins.first(where: {
            $0.manifest.id != featureID && self.shortcut(for: $0.manifest.id) == shortcut
        }) {
            return "与“\(conflict.manifest.name)”的快捷键冲突"
        }

        preferences.shortcuts[featureID] = shortcut
        persist()
        Task { try? await registry.setShortcut(shortcut, for: featureID) }
        if featureID == FeatureConfigurationStore.screenshotID {
            notificationCenter.post(name: .screenshotShortcutsDidChange, object: nil)
        }
        return nil
    }

    func assignKeyboardKey(_ key: String, to featureID: String) -> String? {
        guard plugins.contains(where: { $0.manifest.id == featureID }) else {
            return "未找到要分配的功能"
        }

        let sourceShortcut = shortcut(for: featureID)
        let normalizedKey = key.lowercased()
        if sourceShortcut.key == normalizedKey, customKeyActions[normalizedKey] == nil {
            return nil
        }

        if customKeyActions.removeValue(forKey: normalizedKey) != nil {
            persistCustomActions()
        }

        if let occupiedPlugin = plugins.first(where: {
            $0.manifest.id != featureID && shortcut(for: $0.manifest.id).key == normalizedKey
        }) {
            let occupiedID = occupiedPlugin.manifest.id
            let occupiedShortcut = shortcut(for: occupiedID)
            preferences.shortcuts[featureID] = occupiedShortcut
            preferences.shortcuts[occupiedID] = sourceShortcut
            persist()
            Task { try? await registry.swapShortcuts(between: featureID, and: occupiedID) }
            notifyScreenshotShortcutChangeIfNeeded(featureIDs: [featureID, occupiedID])
            return nil
        }

        return updateShortcut(
            .init(modifiers: [], key: normalizedKey),
            for: featureID
        )
    }

    func assignCustomAction(_ action: LauncherCustomAction, to key: String) -> String? {
        let normalizedKey = key.lowercased()
        guard Self.supportedLauncherKeys.contains(normalizedKey) else {
            return "这个键位暂不支持自定义"
        }
        if let validationError = validate(action) {
            return validationError
        }

        if let occupiedFeatureID = plugins.first(where: {
            shortcut(for: $0.manifest.id).key == normalizedKey
        })?.manifest.id {
            guard let replacementKey = firstAvailableKey(excluding: normalizedKey) else {
                return "没有可用于移动原功能的空键位"
            }
            preferences.shortcuts[occupiedFeatureID] = .init(modifiers: [], key: replacementKey)
            persist()
            Task {
                try? await registry.setShortcut(.init(modifiers: [], key: replacementKey), for: occupiedFeatureID)
            }
            notifyScreenshotShortcutChangeIfNeeded(featureIDs: [occupiedFeatureID])
        }

        customKeyActions[normalizedKey] = action
        persistCustomActions()
        return nil
    }

    func removeCustomAction(for key: String) {
        let normalizedKey = key.lowercased()
        guard customKeyActions.removeValue(forKey: normalizedKey) != nil else { return }
        persistCustomActions()
        if let defaultPlugin = plugins.first(where: {
            $0.manifest.defaultShortcut.key.lowercased() == normalizedKey
        }) {
            _ = assignKeyboardKey(normalizedKey, to: defaultPlugin.manifest.id)
        }
    }

    func performLauncherKey(_ key: String) async {
        if let action = customAction(forLauncherKey: key) {
            perform(action)
            return
        }
        if let featureID = featureID(forLauncherKey: key) {
            await perform(featureID)
        }
    }

    func restoreDefaults(for featureID: String) {
        preferences.shortcuts.removeValue(forKey: featureID)
        preferences.hidden.remove(featureID)
        plugins.sort { $0.manifest.defaultOrder < $1.manifest.defaultOrder }
        persistOrder()
        Task { try? await registry.restoreDefaults(for: featureID) }
    }

    func perform(_ featureID: String) async {
        guard let plugin = plugins.first(where: { $0.manifest.id == featureID }) else { return }
        guard isEnabled(featureID) else {
            openSettings(for: featureID)
            return
        }
        if case .failed? = states[featureID] {
            try? await registry.retry(id: featureID)
            await refreshStates()
        }
        if case .restricted? = states[featureID] {
            openRestrictedDestination(for: featureID)
            return
        }
        // 受限状态优先进入统一权限中心；只有功能可用时，才按
        // `primaryAction` 打开该功能自己的设置页。
        if plugin.manifest.primaryAction == .openSettings {
            openSettings(for: featureID)
            return
        }
        states[featureID] = .running
        do {
            let timeout: Duration? = featureID == FeatureConfigurationStore.screenshotID ? nil : .seconds(5)
            let result = try await registry.perform(id: featureID, timeout: timeout)
            switch result {
            case .requiresSetup:
                openSettings(
                    for: featureID,
                    permissionRequired: featureID == FeatureConfigurationStore.screenshotID
                )
            case let .presentPanel(panelFeatureID):
                notificationCenter.post(name: .presentTouchFeaturePanel, object: panelFeatureID)
            case .completed:
                break
            }
        } catch FeatureRegistryError.unavailable(state: let state) {
            if case .restricted = state {
                openRestrictedDestination(for: featureID)
            } else if state == .disabled {
                openSettings(for: featureID)
            }
        } catch {
            // The registry owns and publishes the isolated failure state below.
        }
        await refreshStates()
    }

    func retry(_ featureID: String) async {
        try? await registry.retry(id: featureID)
        await refreshStates()
    }

    private func loadStates() async {
        await registry.load()
        await refreshStates()
    }

    private func refreshStates() async {
        states = Dictionary(uniqueKeysWithValues: await registry.entries.map { ($0.manifest.id, $0.state) })
    }

    private func openSettings(for featureID: String, permissionRequired: Bool = false) {
        if permissionRequired {
            openPermissions()
            return
        }
        notificationCenter.post(
            name: .openTouchSettings,
            object: TouchSettingsDestination(section: .featureArea, featureID: featureID)
        )
    }

    private func openPermissions() {
        notificationCenter.post(
            name: .openTouchSettings,
            object: TouchSettingsDestination(section: .permissions)
        )
    }

    private func openRestrictedDestination(for featureID: String) {
        if featureID == TranslationFeaturePlugin.id {
            openSettings(for: featureID)
        } else {
            openPermissions()
        }
    }

    private func persistOrder() {
        preferences.order = plugins.map { $0.manifest.id }
        persist()
    }

    private func persist() {
        try? preferencesStore.save(preferences)
        objectWillChange.send()
    }

    private func firstAvailableKey(excluding key: String) -> String? {
        let occupiedFeatureKeys = Set(plugins.map { shortcut(for: $0.manifest.id).key.lowercased() })
        let occupiedCustomKeys = Set(customKeyActions.keys)
        return Self.supportedLauncherKeys.first {
            $0 != key && !occupiedFeatureKeys.contains($0) && !occupiedCustomKeys.contains($0)
        }
    }

    private func validate(_ action: LauncherCustomAction) -> String? {
        let target = action.target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return action.kind == .shortcut ? "请输入快捷指令名称" : "请填写要执行的内容"
        }

        switch action.kind {
        case .application, .file:
            guard FileManager.default.fileExists(atPath: target) else { return "所选项目已不存在" }
        case .folder:
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "所选文件夹已不存在"
            }
        case .webPage:
            guard normalizedWebURL(from: target) != nil else { return "请输入有效的网址" }
        case .shortcut, .shellScript:
            break
        }
        return nil
    }

    private func perform(_ action: LauncherCustomAction) {
        notificationCenter.post(name: .dismissTouchLauncher, object: nil)
        switch action.kind {
        case .application, .file, .folder:
            NSWorkspace.shared.open(URL(fileURLWithPath: action.target))
        case .webPage:
            if let url = normalizedWebURL(from: action.target) {
                NSWorkspace.shared.open(url)
            }
        case .shortcut:
            var components = URLComponents()
            components.scheme = "shortcuts"
            components.host = "run-shortcut"
            components.queryItems = [URLQueryItem(name: "name", value: action.target)]
            if let url = components.url {
                NSWorkspace.shared.open(url)
            }
        case .shellScript:
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", action.target]
            try? process.run()
        }
    }

    private func normalizedWebURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private func persistCustomActions() {
        guard let data = try? JSONEncoder().encode(customKeyActions) else { return }
        defaults.set(data, forKey: Self.customActionsDefaultsKey)
        objectWillChange.send()
    }

    private func persistGlobalShortcuts() {
        guard let data = try? JSONEncoder().encode(globalShortcuts) else { return }
        defaults.set(data, forKey: Self.globalShortcutsDefaultsKey)
    }

    private static func loadCustomActions(defaults: UserDefaults) -> [String: LauncherCustomAction] {
        guard let data = defaults.data(forKey: customActionsDefaultsKey),
              let actions = try? JSONDecoder().decode([String: LauncherCustomAction].self, from: data) else {
            return [:]
        }
        return actions
    }

    private static func loadGlobalShortcuts(
        defaults: UserDefaults,
        plugins: [any FeaturePlugin],
        launcherShortcuts: [String: TouchFeatureAPI.KeyboardShortcut]
    ) -> [String: TouchFeatureAPI.KeyboardShortcut] {
        var shortcuts: [String: TouchFeatureAPI.KeyboardShortcut]
        if let data = defaults.data(forKey: globalShortcutsDefaultsKey),
           let decoded = try? JSONDecoder().decode(
                [String: TouchFeatureAPI.KeyboardShortcut].self,
                from: data
           ) {
            shortcuts = decoded
        } else {
            shortcuts = [:]
        }

        let wasSeededByCommandDefaults = defaults.bool(
            forKey: legacyCommandGlobalShortcutDefaultsSeededKey
        ) || defaults.bool(forKey: previousCommandGlobalShortcutDefaultsSeededKey)
        if !defaults.bool(forKey: globalShortcutDefaultsSeededKey) || wasSeededByCommandDefaults {
            var occupied = Set(shortcuts.values)
            for plugin in plugins {
                let key = launcherShortcuts[plugin.manifest.id]?.key
                    ?? plugin.manifest.defaultShortcut.key
                guard !key.isEmpty else { continue }
                let desiredShortcut = TouchFeatureAPI.KeyboardShortcut(
                    modifiers: [.option],
                    key: key
                )
                let legacyShortcut = TouchFeatureAPI.KeyboardShortcut(
                    modifiers: [.command],
                    key: plugin.manifest.defaultShortcut.key
                )
                let existingShortcut = shortcuts[plugin.manifest.id]
                let replacesLegacyDefault = wasSeededByCommandDefaults
                    && existingShortcut == legacyShortcut
                    && desiredShortcut != legacyShortcut
                guard existingShortcut == nil || replacesLegacyDefault else {
                    continue
                }
                if let existingShortcut {
                    occupied.remove(existingShortcut)
                }
                guard !occupied.contains(desiredShortcut),
                      (try? HotKeyMapping.carbonValue(for: desiredShortcut)) != nil else {
                    if let existingShortcut {
                        occupied.insert(existingShortcut)
                    }
                    continue
                }
                shortcuts[plugin.manifest.id] = desiredShortcut
                occupied.insert(desiredShortcut)
            }
            if let data = try? JSONEncoder().encode(shortcuts) {
                defaults.set(data, forKey: globalShortcutsDefaultsKey)
                defaults.set(true, forKey: globalShortcutDefaultsSeededKey)
            }
            if wasSeededByCommandDefaults {
                defaults.removeObject(forKey: legacyCommandGlobalShortcutDefaultsSeededKey)
                defaults.removeObject(forKey: previousCommandGlobalShortcutDefaultsSeededKey)
            }
        }

        return shortcuts.filter {
            (1...2).contains($0.value.modifiers.count)
                && !$0.value.key.isEmpty
                && (try? HotKeyMapping.carbonValue(for: $0.value)) != nil
        }
    }

    private func notifyScreenshotShortcutChangeIfNeeded(featureIDs: [String]) {
        guard featureIDs.contains(FeatureConfigurationStore.screenshotID) else { return }
        notificationCenter.post(name: .screenshotShortcutsDidChange, object: nil)
    }
}

private extension LauncherCustomAction {
    var localIconPath: String {
        switch kind {
        case .application, .file, .folder:
            target
        case .webPage, .shortcut, .shellScript:
            ""
        }
    }
}

extension Notification.Name {
    static let screenshotShortcutsDidChange = Notification.Name(
        "me.touch.screenshot.shortcuts-did-change"
    )
    static let presentTouchFeaturePanel = Notification.Name("me.touch.present-feature-panel")
    static let startTouchFocusSession = Notification.Name("me.touch.start-focus-session")
    static let featureGlobalShortcutsDidChange = Notification.Name(
        "me.touch.feature-global-shortcuts-did-change"
    )
}

private extension ScreenshotCaptureMode {
    var settingsTitle: String {
        switch self {
        case .region: "区域截图"
        case .window: "窗口截图"
        case .fullScreen: "全屏截图"
        case .allDisplays: "所有显示器截图"
        case .ocrRegion: "文字识别"
        case .colorPicker: "屏幕取色"
        }
    }
}
