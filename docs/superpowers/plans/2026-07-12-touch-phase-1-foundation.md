# 触达阶段一：原生壳层与插件基础实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task in the current task. The user explicitly prohibits subagents. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建可通过 `Option + Space` 丝滑呼出的原生毛玻璃启动器，建立第一方插件协议、功能区管理、三级设置导航和三套主题，并让“打开访达”卡片真实可用。

**Architecture:** 使用本地 Swift Package 承载可测试的 Feature API、注册中心、偏好存储和三个第一方插件适配器；macOS App target 负责 NSPanel、全局快捷键和 SwiftUI 界面。阶段一不执行截图和 Finder 文件动作，它们以明确的“需要完成设置”状态接入，并在后续阶段连接独立 XPC 服务。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Carbon Hot Key、XCTest、XCUITest、XcodeGen、UserDefaults。

---

## 文件结构

```text
Config/
├── Base.xcconfig
├── Debug.xcconfig
└── Release.xcconfig
Packages/TouchKit/
├── Package.swift
├── Sources/TouchFeatureAPI/
│   ├── FeatureManifest.swift
│   ├── FeaturePlugin.swift
│   ├── FeatureState.swift
│   ├── FeatureActionResult.swift
│   └── KeyboardShortcut.swift
├── Sources/TouchCore/
│   ├── FeatureRegistry.swift
│   ├── FeaturePreferences.swift
│   ├── FeaturePreferencesStore.swift
│   └── Theme.swift
├── Sources/FinderFeature/FinderFeaturePlugin.swift
├── Sources/ScreenshotFeature/ScreenshotFeaturePlugin.swift
├── Sources/SuperRightFeature/SuperRightFeaturePlugin.swift
├── Tests/TouchCoreTests/
│   ├── FeatureRegistryTests.swift
│   ├── FeaturePreferencesStoreTests.swift
│   └── ThemeTests.swift
└── Tests/FeaturePluginTests/BuiltInFeatureTests.swift
TouchApp/
├── App/TouchApp.swift
├── App/AppDelegate.swift
├── Launcher/LauncherPanel.swift
├── Launcher/LauncherPanelController.swift
├── Launcher/GlobalHotKeyController.swift
├── Launcher/FocusRestorer.swift
├── Launcher/LauncherView.swift
├── Launcher/SearchBarView.swift
├── Launcher/FeatureCardView.swift
├── Launcher/FeatureGridView.swift
├── Appearance/ThemeStore.swift
├── Appearance/GlassBackground.swift
├── Settings/SettingsRootView.swift
├── Settings/FeatureAreaSettingsView.swift
├── Settings/FeatureDetailSettingsView.swift
└── Settings/GeneralSettingsView.swift
TouchUITests/
├── LauncherSmokeTests.swift
└── SettingsNavigationTests.swift
Scripts/check-deployment-targets.sh
project.yml
```

### Task 1: 建立统一 macOS 14 工程基线

**Files:**
- Create: `project.yml`
- Create: `Config/Base.xcconfig`
- Create: `Config/Debug.xcconfig`
- Create: `Config/Release.xcconfig`
- Create: `Scripts/check-deployment-targets.sh`
- Create: `TouchApp/App/TouchApp.swift`
- Create: `TouchApp/App/AppDelegate.swift`

- [ ] **Step 1: 安装并验证 XcodeGen**

Run:

```bash
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
xcodegen --version
```

Expected: 输出 XcodeGen 版本且退出码为 0。

- [ ] **Step 2: 写部署目标检查脚本的失败用例**

Create `Scripts/check-deployment-targets.sh` with executable mode and this behavior contract:

```bash
#!/bin/zsh
set -euo pipefail
expected="14.0"
files=(Config/Base.xcconfig Packages/TouchKit/Package.swift project.yml)
for file in $files; do
  [[ -f "$file" ]] || { print -u2 "missing deployment source: $file"; exit 1; }
done
rg -q "MACOSX_DEPLOYMENT_TARGET = $expected" Config/Base.xcconfig
rg -q "\.macOS\(\.v14\)" Packages/TouchKit/Package.swift
rg -q "macOS: '$expected'" project.yml
bad_targets=$(rg -n "deploymentTarget: '[^']+'" project.yml | rg -v "'$expected'" || true)
if [[ -n "$bad_targets" ]]; then
  print -u2 "$bad_targets"
  print -u2 "inconsistent deployment target"
  exit 1
fi
print "deployment targets are consistent at macOS $expected"
```

Run:

```bash
chmod +x Scripts/check-deployment-targets.sh
Scripts/check-deployment-targets.sh
```

Expected: FAIL with `missing deployment source` because configuration files are not created yet.

- [ ] **Step 3: 创建工程定义和最小 App**

Create `Config/Base.xcconfig`:

```text
MACOSX_DEPLOYMENT_TARGET = 14.0
SWIFT_VERSION = 6.0
CODE_SIGN_STYLE = Automatic
ENABLE_USER_SCRIPT_SANDBOXING = YES
```

Create `Config/Debug.xcconfig`:

```text
#include "Base.xcconfig"
SWIFT_OPTIMIZATION_LEVEL = -Onone
SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG
```

Create `Config/Release.xcconfig`:

```text
#include "Base.xcconfig"
SWIFT_OPTIMIZATION_LEVEL = -O
SWIFT_COMPILATION_MODE = wholemodule
```

Create `TouchApp/App/TouchApp.swift`:

```swift
import SwiftUI

@main
struct TouchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Text("触达设置")
                .frame(width: 680, height: 480)
        }
    }
}
```

Create `TouchApp/App/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

Create `project.yml`:

```yaml
name: Touch
options:
  minimumXcodeGenVersion: 2.42.0
  deploymentTarget:
    macOS: '14.0'
configs:
  Debug: debug
  Release: release
configFiles:
  Debug: Config/Debug.xcconfig
  Release: Config/Release.xcconfig
packages:
  TouchKit:
    path: Packages/TouchKit
targets:
  Touch:
    type: application
    platform: macOS
    deploymentTarget: '14.0'
    sources:
      - TouchApp
    dependencies:
      - package: TouchKit
        product: TouchFeatureAPI
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: me.touch.launcher
        PRODUCT_NAME: 触达
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_LSUIElement: YES
        CODE_SIGNING_ALLOWED: NO
    scheme:
      testTargets:
        - TouchUITests
  TouchUITests:
    type: bundle.ui-testing
    platform: macOS
    deploymentTarget: '14.0'
    sources:
      - TouchUITests
    dependencies:
      - target: Touch
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: me.touch.launcher.uitests
        GENERATE_INFOPLIST_FILE: YES
        CODE_SIGNING_ALLOWED: NO
```

- [ ] **Step 4: 生成工程并确认预期失败**

Run:

```bash
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' build
```

Expected: FAIL because the local `Packages/TouchKit` package does not exist yet.

- [ ] **Step 5: 保留失败基线，不提交不可构建状态**

```bash
git status --short
```

Expected: only the new baseline files are listed. Do not commit until Task 2 makes the project buildable.

### Task 2: 定义 FeaturePlugin 公共协议

**Files:**
- Create: `Packages/TouchKit/Package.swift`
- Create: `Packages/TouchKit/Sources/TouchFeatureAPI/FeatureManifest.swift`
- Create: `Packages/TouchKit/Sources/TouchFeatureAPI/FeaturePlugin.swift`
- Create: `Packages/TouchKit/Sources/TouchFeatureAPI/FeatureState.swift`
- Create: `Packages/TouchKit/Sources/TouchFeatureAPI/FeatureActionResult.swift`
- Create: `Packages/TouchKit/Sources/TouchFeatureAPI/KeyboardShortcut.swift`
- Create: `Packages/TouchKit/Tests/TouchFeatureAPITests/FeatureModelTests.swift`

- [ ] **Step 1: 创建 package 和失败测试**

Create `Packages/TouchKit/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TouchFeatureAPI", targets: ["TouchFeatureAPI"])
    ],
    targets: [
        .target(name: "TouchFeatureAPI"),
        .testTarget(name: "TouchFeatureAPITests", dependencies: ["TouchFeatureAPI"])
    ]
)
```

Create `FeatureModelTests.swift`:

```swift
import Testing
@testable import TouchFeatureAPI

@Test func manifestIdentityIsStable() {
    let manifest = FeatureManifest(
        id: "me.touch.finder",
        name: "打开访达",
        summary: "打开 Finder",
        symbolName: "face.smiling",
        defaultOrder: 0,
        defaultShortcut: .init(modifiers: [.command], key: "1")
    )
    #expect(manifest.id == "me.touch.finder")
    #expect(manifest.defaultShortcut.displayValue == "⌘1")
}

@Test func stateDescribesAvailability() {
    #expect(FeatureState.available.isSelectable)
    #expect(!FeatureState.disabled.isSelectable)
    #expect(!FeatureState.failed(message: "服务异常").isSelectable)
}
```

Run:

```bash
swift test --package-path Packages/TouchKit --filter FeatureModelTests
```

Expected: FAIL because feature models do not exist.

- [ ] **Step 2: 实现不可变模型和插件协议**

Create `FeatureManifest.swift`:

```swift
public struct FeatureManifest: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    public let symbolName: String
    public let defaultOrder: Int
    public let defaultShortcut: KeyboardShortcut

    public init(id: String, name: String, summary: String, symbolName: String, defaultOrder: Int, defaultShortcut: KeyboardShortcut) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbolName = symbolName
        self.defaultOrder = defaultOrder
        self.defaultShortcut = defaultShortcut
    }
}
```

Create `KeyboardShortcut.swift`:

```swift
public struct KeyboardShortcut: Codable, Hashable, Sendable {
    public enum Modifier: String, Codable, Hashable, Sendable { case command, option, control, shift }
    public let modifiers: Set<Modifier>
    public let key: String

    public init(modifiers: Set<Modifier>, key: String) {
        self.modifiers = modifiers
        self.key = key.lowercased()
    }

    public var displayValue: String {
        let order: [(Modifier, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + key.uppercased()
    }
}
```

Create `FeatureState.swift`:

```swift
public enum FeatureState: Equatable, Sendable {
    case unloaded
    case available
    case running
    case restricted(message: String)
    case failed(message: String)
    case disabled

    public var isSelectable: Bool {
        switch self {
        case .available: true
        default: false
        }
    }
}
```

Create `FeatureActionResult.swift`:

```swift
public enum FeatureActionResult: Equatable, Sendable {
    case completed
    case requiresSetup(message: String)
}
```

Create `FeaturePlugin.swift`:

```swift
public protocol FeaturePlugin: Sendable {
    var manifest: FeatureManifest { get }
    func initialState() async -> FeatureState
    func perform() async throws -> FeatureActionResult
}
```

- [ ] **Step 3: 运行模型测试**

Run:

```bash
swift test --package-path Packages/TouchKit --filter FeatureModelTests
Scripts/check-deployment-targets.sh
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' build
```

Expected: tests PASS, script prints `deployment targets are consistent at macOS 14.0`, and app build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Config Scripts project.yml TouchApp Packages/TouchKit
git commit -m "build: establish macOS 14 plugin project"
```

### Task 3: 实现 FeatureRegistry 隔离状态机

**Files:**
- Modify: `Packages/TouchKit/Package.swift`
- Modify: `project.yml`
- Create: `Packages/TouchKit/Sources/TouchCore/FeatureRegistry.swift`
- Create: `Packages/TouchKit/Tests/TouchCoreTests/FeatureRegistryTests.swift`

- [ ] **Step 1: 写注册、隔离和快捷键冲突失败测试**

Create `FeatureRegistryTests.swift`:

```swift
import Testing
import TouchFeatureAPI
@testable import TouchCore

private struct Plugin: FeaturePlugin {
    let manifest: FeatureManifest
    let state: FeatureState
    func initialState() async -> FeatureState { state }
    func perform() async throws -> FeatureActionResult { .completed }
}

@Test func registrySortsByStoredOrderAndIsolatesFailure() async throws {
    let first = Plugin(manifest: .init(id: "a", name: "A", summary: "A", symbolName: "a.circle", defaultOrder: 0, defaultShortcut: .init(modifiers: [.command], key: "1")), state: .failed(message: "broken"))
    let second = Plugin(manifest: .init(id: "b", name: "B", summary: "B", symbolName: "b.circle", defaultOrder: 1, defaultShortcut: .init(modifiers: [.command], key: "2")), state: .available)
    let registry = FeatureRegistry(plugins: [second, first])
    await registry.load()
    let entries = await registry.entries
    #expect(entries.map(\.manifest.id) == ["a", "b"])
    #expect(await registry.state(for: "a") == .failed(message: "broken"))
    #expect(await registry.state(for: "b") == .available)
}

@Test func registryRejectsShortcutConflict() async throws {
    let shortcut = KeyboardShortcut(modifiers: [.command], key: "1")
    let a = Plugin(manifest: .init(id: "a", name: "A", summary: "A", symbolName: "a.circle", defaultOrder: 0, defaultShortcut: shortcut), state: .available)
    let b = Plugin(manifest: .init(id: "b", name: "B", summary: "B", symbolName: "b.circle", defaultOrder: 1, defaultShortcut: .init(modifiers: [.command], key: "2")), state: .available)
    let registry = FeatureRegistry(plugins: [a, b])
    do {
        try await registry.setShortcut(shortcut, for: "b")
        Issue.record("expected shortcut conflict")
    } catch let error as FeatureRegistryError {
        #expect(error == .shortcutConflict(existingFeatureID: "a"))
    }
}
```

Run:

```bash
swift test --package-path Packages/TouchKit --filter FeatureRegistryTests
```

Expected: FAIL because `FeatureRegistry` is undefined.

- [ ] **Step 2: 实现 actor 注册中心**

First expand `Package.swift` to include the core module and tests:

```swift
products: [
    .library(name: "TouchFeatureAPI", targets: ["TouchFeatureAPI"]),
    .library(name: "TouchCore", targets: ["TouchCore"])
],
targets: [
    .target(name: "TouchFeatureAPI"),
    .target(name: "TouchCore", dependencies: ["TouchFeatureAPI"]),
    .testTarget(name: "TouchFeatureAPITests", dependencies: ["TouchFeatureAPI"]),
    .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore", "TouchFeatureAPI"])
]
```

Create `FeatureRegistry.swift`:

```swift
import TouchFeatureAPI

public enum FeatureRegistryError: Error, Equatable {
    case unknownFeature
    case shortcutConflict(existingFeatureID: String)
}

public struct FeatureEntry: Sendable {
    public let manifest: FeatureManifest
    public var state: FeatureState
    public var shortcut: KeyboardShortcut
    public var isVisible: Bool
}

public actor FeatureRegistry {
    private let plugins: [String: any FeaturePlugin]
    public private(set) var entries: [FeatureEntry]

    public init(plugins: [any FeaturePlugin]) {
        self.plugins = Dictionary(uniqueKeysWithValues: plugins.map { ($0.manifest.id, $0) })
        self.entries = plugins
            .sorted { $0.manifest.defaultOrder < $1.manifest.defaultOrder }
            .map { FeatureEntry(manifest: $0.manifest, state: .unloaded, shortcut: $0.manifest.defaultShortcut, isVisible: true) }
    }

    public func load() async {
        for index in entries.indices {
            guard let plugin = plugins[entries[index].manifest.id] else { continue }
            entries[index].state = await plugin.initialState()
        }
    }

    public func state(for id: String) -> FeatureState? {
        entries.first { $0.manifest.id == id }?.state
    }

    public func setShortcut(_ shortcut: KeyboardShortcut, for id: String) throws {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }) else { throw FeatureRegistryError.unknownFeature }
        if let conflict = entries.first(where: { $0.manifest.id != id && $0.shortcut == shortcut }) {
            throw FeatureRegistryError.shortcutConflict(existingFeatureID: conflict.manifest.id)
        }
        entries[index].shortcut = shortcut
    }

    public func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source), destination >= 0, destination <= entries.count else { return }
        let entry = entries.remove(at: source)
        entries.insert(entry, at: min(destination, entries.count))
    }
}
```

- [ ] **Step 3: 运行注册中心测试**

Run:

```bash
swift test --package-path Packages/TouchKit --filter FeatureRegistryTests
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/TouchKit/Sources/TouchCore/FeatureRegistry.swift Packages/TouchKit/Tests/TouchCoreTests/FeatureRegistryTests.swift
git commit -m "feat: add isolated feature registry state machine"
```

### Task 4: 持久化功能区顺序、显示和快捷键

**Files:**
- Create: `Packages/TouchKit/Sources/TouchCore/FeaturePreferences.swift`
- Create: `Packages/TouchKit/Sources/TouchCore/FeaturePreferencesStore.swift`
- Create: `Packages/TouchKit/Tests/TouchCoreTests/FeaturePreferencesStoreTests.swift`

- [ ] **Step 1: 写独立命名空间和往返失败测试**

Create `FeaturePreferencesStoreTests.swift`:

```swift
import Foundation
import Testing
import TouchFeatureAPI
@testable import TouchCore

@Test func preferencesRoundTripWithoutTouchingOtherSuite() throws {
    let suiteName = "FeaturePreferencesStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = FeaturePreferencesStore(defaults: defaults)
    let value = FeaturePreferences(order: ["screenshot", "finder"], hidden: ["finder"], shortcuts: ["screenshot": .init(modifiers: [.command], key: "2")])
    try store.save(value)
    #expect(try store.load() == value)
    #expect(UserDefaults.standard.data(forKey: FeaturePreferencesStore.storageKey) == nil)
}
```

Run:

```bash
swift test --package-path Packages/TouchKit --filter FeaturePreferencesStoreTests
```

Expected: FAIL because preference types do not exist.

- [ ] **Step 2: 实现 Codable 偏好存储**

Create `FeaturePreferences.swift`:

```swift
import TouchFeatureAPI

public struct FeaturePreferences: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: Set<String>
    public var shortcuts: [String: KeyboardShortcut]

    public init(order: [String] = [], hidden: Set<String> = [], shortcuts: [String: KeyboardShortcut] = [:]) {
        self.order = order
        self.hidden = hidden
        self.shortcuts = shortcuts
    }
}
```

Create `FeaturePreferencesStore.swift`:

```swift
import Foundation

public struct FeaturePreferencesStore {
    public static let storageKey = "feature-area.preferences.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public func load() throws -> FeaturePreferences {
        guard let data = defaults.data(forKey: Self.storageKey) else { return .init() }
        return try JSONDecoder().decode(FeaturePreferences.self, from: data)
    }

    public func save(_ value: FeaturePreferences) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: Self.storageKey)
    }
}
```

- [ ] **Step 3: 运行存储测试**

Run:

```bash
swift test --package-path Packages/TouchKit --filter FeaturePreferencesStoreTests
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Packages/TouchKit/Sources/TouchCore Packages/TouchKit/Tests/TouchCoreTests/FeaturePreferencesStoreTests.swift
git commit -m "feat: persist feature area preferences"
```

### Task 5: 实现三个第一方插件适配器

**Files:**
- Modify: `Packages/TouchKit/Package.swift`
- Create: `Packages/TouchKit/Sources/FinderFeature/FinderFeaturePlugin.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenshotFeaturePlugin.swift`
- Create: `Packages/TouchKit/Sources/SuperRightFeature/SuperRightFeaturePlugin.swift`
- Create: `Packages/TouchKit/Tests/FeaturePluginTests/BuiltInFeatureTests.swift`

- [ ] **Step 1: 写清单、状态和 Finder 动作失败测试**

Create `BuiltInFeatureTests.swift`:

```swift
import Testing
import TouchFeatureAPI
@testable import FinderFeature
@testable import ScreenshotFeature
@testable import SuperRightFeature

@Test func builtInFeatureManifestsAreUnique() {
    let plugins: [any FeaturePlugin] = [FinderFeaturePlugin(), ScreenshotFeaturePlugin(), SuperRightFeaturePlugin()]
    #expect(Set(plugins.map { $0.manifest.id }).count == 3)
    #expect(plugins.map { $0.manifest.name } == ["打开访达", "截取屏幕", "超级右键"])
}

@Test func unfinishedServicesAreExplicitlyRestricted() async {
    #expect(await ScreenshotFeaturePlugin().initialState() == .restricted(message: "需要配置屏幕录制权限"))
    #expect(await SuperRightFeaturePlugin().initialState() == .restricted(message: "需要启用 Finder 扩展"))
}
```

Run:

```bash
swift test --package-path Packages/TouchKit --filter BuiltInFeatureTests
```

Expected: FAIL because built-in plugin types do not exist.

- [ ] **Step 2: 实现三个插件适配器**

Expand `Package.swift` to its final stage-one product and target list:

```swift
products: [
    .library(name: "TouchFeatureAPI", targets: ["TouchFeatureAPI"]),
    .library(name: "TouchCore", targets: ["TouchCore"]),
    .library(name: "FinderFeature", targets: ["FinderFeature"]),
    .library(name: "ScreenshotFeature", targets: ["ScreenshotFeature"]),
    .library(name: "SuperRightFeature", targets: ["SuperRightFeature"])
],
targets: [
    .target(name: "TouchFeatureAPI"),
    .target(name: "TouchCore", dependencies: ["TouchFeatureAPI"]),
    .target(name: "FinderFeature", dependencies: ["TouchFeatureAPI"]),
    .target(name: "ScreenshotFeature", dependencies: ["TouchFeatureAPI"]),
    .target(name: "SuperRightFeature", dependencies: ["TouchFeatureAPI"]),
    .testTarget(name: "TouchFeatureAPITests", dependencies: ["TouchFeatureAPI"]),
    .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore", "TouchFeatureAPI"]),
    .testTarget(name: "FeaturePluginTests", dependencies: ["FinderFeature", "ScreenshotFeature", "SuperRightFeature", "TouchFeatureAPI"])
]
```

Add the four newly available package products to the `Touch` target dependencies in `project.yml`:

```yaml
      - package: TouchKit
        product: TouchCore
      - package: TouchKit
        product: FinderFeature
      - package: TouchKit
        product: ScreenshotFeature
      - package: TouchKit
        product: SuperRightFeature
```

Create `FinderFeaturePlugin.swift`:

```swift
import AppKit
import TouchFeatureAPI

public struct FinderFeaturePlugin: FeaturePlugin {
    public init() {}
    public let manifest = FeatureManifest(id: "me.touch.finder", name: "打开访达", summary: "打开 Finder", symbolName: "face.smiling", defaultOrder: 0, defaultShortcut: .init(modifiers: [.command], key: "1"))
    public func initialState() async -> FeatureState { .available }
    public func perform() async throws -> FeatureActionResult {
        await MainActor.run {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()))
        }
        return .completed
    }
}
```

Create `ScreenshotFeaturePlugin.swift`:

```swift
import TouchFeatureAPI

public struct ScreenshotFeaturePlugin: FeaturePlugin {
    public init() {}
    public let manifest = FeatureManifest(id: "me.touch.screenshot", name: "截取屏幕", summary: "截图、标注与钉图", symbolName: "crop", defaultOrder: 1, defaultShortcut: .init(modifiers: [.command], key: "2"))
    public func initialState() async -> FeatureState { .restricted(message: "需要配置屏幕录制权限") }
    public func perform() async throws -> FeatureActionResult { .requiresSetup(message: "请在功能区中配置截取屏幕") }
}
```

Create `SuperRightFeaturePlugin.swift`:

```swift
import TouchFeatureAPI

public struct SuperRightFeaturePlugin: FeaturePlugin {
    public init() {}
    public let manifest = FeatureManifest(id: "me.touch.super-right", name: "超级右键", summary: "增强 Finder 右键菜单", symbolName: "ellipsis", defaultOrder: 2, defaultShortcut: .init(modifiers: [.command], key: "3"))
    public func initialState() async -> FeatureState { .restricted(message: "需要启用 Finder 扩展") }
    public func perform() async throws -> FeatureActionResult { .requiresSetup(message: "请在功能区中配置超级右键") }
}
```

- [ ] **Step 3: 运行插件测试和工程构建**

Run:

```bash
swift test --package-path Packages/TouchKit --filter BuiltInFeatureTests
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' build
```

Expected: package tests PASS and app build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Packages/TouchKit/Sources Packages/TouchKit/Tests project.yml
git commit -m "feat: register three built-in feature plugins"
```

### Task 6: 实现全局快捷键和可复用 NSPanel

**Files:**
- Create: `TouchApp/Launcher/GlobalHotKeyController.swift`
- Create: `TouchApp/Launcher/LauncherPanel.swift`
- Create: `TouchApp/Launcher/FocusRestorer.swift`
- Create: `TouchApp/Launcher/LauncherPanelController.swift`
- Modify: `TouchApp/App/AppDelegate.swift`

- [ ] **Step 1: 写快捷键映射单元测试**

Add `Packages/TouchKit/Sources/TouchCore/HotKeyMapping.swift` and `Packages/TouchKit/Tests/TouchCoreTests/HotKeyMappingTests.swift` test first:

```swift
import Testing
import TouchFeatureAPI
@testable import TouchCore

@Test func optionSpaceMapsToCarbonValues() throws {
    let value = try HotKeyMapping.carbonValue(for: .init(modifiers: [.option], key: "space"))
    #expect(value.keyCode == 49)
    #expect(value.modifiers != 0)
}

@Test func unsupportedKeyIsRejected() {
    #expect(throws: HotKeyMappingError.unsupportedKey("💡")) {
        try HotKeyMapping.carbonValue(for: .init(modifiers: [.option], key: "💡"))
    }
}
```

Run `swift test --package-path Packages/TouchKit --filter HotKeyMappingTests`.

Expected: FAIL because `HotKeyMapping` is undefined.

- [ ] **Step 2: 实现映射、Carbon 注册和面板复用**

Implement `HotKeyMapping` as a pure map supporting `space`, `a...z`, `0...9`; implement `GlobalHotKeyController` with `RegisterEventHotKey`, one event handler, `start(shortcut:onPress:)` and `stop()`; implement `LauncherPanel` as an `NSPanel` subclass returning `true` for `canBecomeKey`; implement `LauncherPanelController.toggle()` so it creates the panel once, records the previous frontmost app, centers on `NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })`, and restores focus on close.

Use these exact public signatures:

```swift
public struct CarbonHotKeyValue: Equatable, Sendable { public let keyCode: UInt32; public let modifiers: UInt32 }
public enum HotKeyMappingError: Error, Equatable { case unsupportedKey(String) }
public enum HotKeyMapping { public static func carbonValue(for shortcut: KeyboardShortcut) throws -> CarbonHotKeyValue }
final class GlobalHotKeyController { func start(shortcut: KeyboardShortcut, onPress: @escaping @MainActor () -> Void) throws; func stop() }
@MainActor final class LauncherPanelController { func toggle(); func show(); func hide() }
```

- [ ] **Step 3: 连接 AppDelegate**

Update `AppDelegate` to construct one `LauncherPanelController`, register `Option + Space` during `applicationDidFinishLaunching`, and stop the hotkey during termination. Registration failure must show a single alert and keep the menu bar process alive.

- [ ] **Step 4: 运行测试和手动冒烟**

Run:

```bash
swift test --package-path Packages/TouchKit --filter HotKeyMappingTests
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/Touch-*/Build/Products/Debug/触达.app
```

Expected: tests PASS; pressing `Option + Space` repeatedly shows and hides the same centered panel without creating duplicate windows.

- [ ] **Step 5: Commit**

```bash
git add Packages/TouchKit TouchApp/Launcher TouchApp/App/AppDelegate.swift
git commit -m "feat: add reusable launcher panel and global hotkey"
```

### Task 7: 实现三主题毛玻璃启动页

**Files:**
- Create: `Packages/TouchKit/Sources/TouchCore/Theme.swift`
- Create: `Packages/TouchKit/Tests/TouchCoreTests/ThemeTests.swift`
- Create: `TouchApp/Appearance/ThemeStore.swift`
- Create: `TouchApp/Appearance/GlassBackground.swift`
- Create: `TouchApp/Launcher/LauncherView.swift`
- Create: `TouchApp/Launcher/SearchBarView.swift`
- Create: `TouchApp/Launcher/FeatureCardView.swift`
- Create: `TouchApp/Launcher/FeatureGridView.swift`
- Modify: `TouchApp/Launcher/LauncherPanelController.swift`

- [ ] **Step 1: 写主题持久化和循环失败测试**

Create `ThemeTests.swift`:

```swift
import Testing
@testable import TouchCore

@Test func themesCycleInProductOrder() {
    #expect(TouchTheme.crystal.next == .obsidian)
    #expect(TouchTheme.obsidian.next == .amber)
    #expect(TouchTheme.amber.next == .crystal)
}
```

Run `swift test --package-path Packages/TouchKit --filter ThemeTests`.

Expected: FAIL because `TouchTheme` is undefined.

- [ ] **Step 2: 实现主题模型和 UI 令牌**

Create `Theme.swift`:

```swift
public enum TouchTheme: String, Codable, CaseIterable, Sendable {
    case crystal, obsidian, amber
    public var next: Self {
        let values = Self.allCases
        return values[(values.firstIndex(of: self)! + 1) % values.count]
    }
}
```

Implement `ThemeStore` as `@MainActor @Observable`, storing `TouchTheme` in UserDefaults key `appearance.theme.v1`. Implement `GlassBackground` with `NSVisualEffectView` via `NSViewRepresentable`; select `.hudWindow` for obsidian and `.underWindowBackground` for crystal/amber. Respect `accessibilityReduceTransparency` by switching to an opaque semantic color.

- [ ] **Step 3: 实现确认原型的启动页**

Implement `LauncherView` with fixed content hierarchy:

```text
Header: 触达 + 心之所想，一触即达 + theme button + settings button
Search: magnifier + 应用/文件 segmented tabs + Tab 切换 + text field
Feature area: three compact horizontal cards in one row
```

Use a 1180×680 panel, 36pt outer corner radius, 72pt horizontal padding, 54pt top padding, 64pt card height, 20pt gaps, and SF Symbols from each `FeatureManifest`. Add accessibility identifiers `launcher.root`, `search.mode.application`, `search.mode.file`, `feature.<plugin-id>`, `theme.switch`, and `settings.open`.

- [ ] **Step 4: 连接主题和插件清单**

Construct `FeatureRegistry` from the three built-in plugins in `AppDelegate`, load it once, and pass entries to `LauncherView`. Card selection calls `plugin.perform()`; `.requiresSetup` opens the matching feature settings route.

- [ ] **Step 5: 运行测试和构建**

Run:

```bash
swift test --package-path Packages/TouchKit --filter ThemeTests
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' build
```

Expected: PASS; manual theme cycling preserves card positions and does not recreate the NSPanel.

- [ ] **Step 6: Commit**

```bash
git add Packages/TouchKit TouchApp/Appearance TouchApp/Launcher TouchApp/App
git commit -m "feat: build frosted glass launcher with three themes"
```

### Task 8: 实现功能区和三级设置导航

**Files:**
- Create: `TouchApp/Settings/SettingsRootView.swift`
- Create: `TouchApp/Settings/GeneralSettingsView.swift`
- Create: `TouchApp/Settings/FeatureAreaSettingsView.swift`
- Create: `TouchApp/Settings/FeatureDetailSettingsView.swift`
- Modify: `TouchApp/App/TouchApp.swift`
- Create: `TouchUITests/SettingsNavigationTests.swift`

- [ ] **Step 1: 写设置导航 UI 失败测试**

Create `SettingsNavigationTests.swift`:

```swift
import XCTest

final class SettingsNavigationTests: XCTestCase {
    func testFeatureAreaOwnsFeatureSpecificSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings"]
        app.launch()
        app.outlines.buttons["settings.feature-area"].click()
        XCTAssertTrue(app.staticTexts["功能区总览"].waitForExistence(timeout: 2))
        app.buttons["settings.feature.me.touch.screenshot"].click()
        XCTAssertTrue(app.staticTexts["截取屏幕设置"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.outlines.buttons["settings.screenshot.top-level"].exists)
    }
}
```

Run:

```bash
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' -only-testing:TouchUITests/SettingsNavigationTests test
```

Expected: FAIL because settings navigation is not implemented.

- [ ] **Step 2: 实现三级设置导航**

Implement `SettingsRootView` with sidebar items: 通用、搜索与索引、功能区、外观、权限、更新、隐私与存储、关于。Do not add screenshot or super-right as top-level items. `FeatureAreaSettingsView` lists registry entries with enable toggle, startup-card visibility, shortcut button, order controls, state badge, and detail navigation. `FeatureDetailSettingsView` switches only on known feature IDs and renders these exact stage-one fields:

```text
打开访达：默认位置、激活已有窗口
截取屏幕：权限状态、进入后续功能说明
超级右键：Finder 扩展状态、进入后续功能说明
```

- [ ] **Step 3: 运行设置测试**

Run:

```bash
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' -only-testing:TouchUITests/SettingsNavigationTests test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add TouchApp/Settings TouchApp/App/TouchApp.swift TouchUITests/SettingsNavigationTests.swift
git commit -m "feat: add feature area and isolated plugin settings"
```

### Task 9: 实现卡片拖动排序和快捷键编辑

**Files:**
- Modify: `Packages/TouchKit/Sources/TouchCore/FeatureRegistry.swift`
- Modify: `TouchApp/Launcher/FeatureGridView.swift`
- Modify: `TouchApp/Launcher/FeatureCardView.swift`
- Modify: `TouchApp/Settings/FeatureAreaSettingsView.swift`
- Create: `TouchApp/Settings/ShortcutRecorderView.swift`
- Create: `TouchUITests/LauncherSmokeTests.swift`

- [ ] **Step 1: 写启动页 UI 失败测试**

Create `LauncherSmokeTests.swift`:

```swift
import XCTest

final class LauncherSmokeTests: XCTestCase {
    func testLauncherShowsThreeFeaturesAndSwitchesSearchMode() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher"]
        app.launch()
        XCTAssertTrue(app.otherElements["launcher.root"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["feature.me.touch.finder"].exists)
        XCTAssertTrue(app.buttons["feature.me.touch.screenshot"].exists)
        XCTAssertTrue(app.buttons["feature.me.touch.super-right"].exists)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.buttons["search.mode.file"].isSelected)
    }
}
```

Run the test and expect FAIL until launch arguments and tab handling exist.

- [ ] **Step 2: 实现拖动和快捷键录入**

Use SwiftUI `draggable`/`dropDestination` with plugin IDs. Begin visual lift after 180ms, but start moving immediately when pointer displacement exceeds 4pt. Persist order through `FeaturePreferencesStore`. Implement `ShortcutRecorderView` using a local `NSEvent` monitor; normalize modifiers and key through `KeyboardShortcut`, call `FeatureRegistry.setShortcut`, and show the conflicting feature name without saving on conflict.

- [ ] **Step 3: 实现 Tab 状态机和测试启动参数**

Add `SearchMode: String { case applications, files }` and an `onKeyPress(.tab)` handler that toggles mode while preserving query. In Debug/UI-test builds only, `--show-launcher` shows the panel after launch and `--open-settings` opens Settings.

- [ ] **Step 4: 运行 UI 和单元测试**

Run:

```bash
swift test --package-path Packages/TouchKit
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' test
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/TouchKit TouchApp TouchUITests
git commit -m "feat: customize feature order and shortcuts"
```

### Task 10: 阶段一性能、兼容性和可访问性验收

**Files:**
- Create: `TouchApp/Diagnostics/LaunchPerformanceRecorder.swift`
- Create: `Scripts/measure-launcher.sh`
- Modify: `TouchUITests/LauncherSmokeTests.swift`
- Create: `docs/verification/phase-1-foundation.md`

- [ ] **Step 1: 添加可测性能标记**

Implement `LaunchPerformanceRecorder` with `os_signpost` intervals named `LauncherToggleToVisible`. Emit begin immediately when hotkey callback fires and end in `LauncherView.onAppear` after the first rendered frame callback. `measure-launcher.sh` launches the Release app 30 times through the UI-test launch argument, parses signpost durations with `xctrace`, sorts milliseconds, and fails when P95 exceeds 120.

- [ ] **Step 2: 扩充可访问性 UI 测试**

Add assertions that every card, theme button, settings button and search mode has a non-empty accessibility label; launch once with `--reduce-transparency` and assert `launcher.root` remains visible and searchable.

- [ ] **Step 3: 执行阶段一全量验收**

Run:

```bash
Scripts/check-deployment-targets.sh
swift test --package-path Packages/TouchKit
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -configuration Release -destination 'platform=macOS' build
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' test
Scripts/measure-launcher.sh
git status --short
```

Expected:

```text
deployment targets are consistent at macOS 14.0
All Swift package tests passed
** BUILD SUCCEEDED **
** TEST SUCCEEDED **
LauncherToggleToVisible P95 <= 120 ms
```

- [ ] **Step 4: 记录验收结果**

Create `docs/verification/phase-1-foundation.md` containing the exact machine model, macOS version, Xcode version, git commit, test command results, measured P50/P95, known non-blocking limitations, and screenshots of the three themes. Do not claim screenshot or Finder extension functionality is complete in this phase.

- [ ] **Step 5: Commit**

```bash
git add TouchApp/Diagnostics Scripts TouchUITests docs/verification/phase-1-foundation.md
git commit -m "test: verify launcher foundation quality gates"
```

## 阶段一完成条件

- [ ] `Option + Space` 可重复呼出和关闭同一个 NSPanel。
- [ ] 三套主题即时切换，设置可持久化。
- [ ] 三个内置插件状态相互隔离。
- [ ] 打开访达真实可用。
- [ ] 功能区统一管理顺序、显示和快捷键。
- [ ] 截图和超级右键只显示明确的配置状态，不伪装为已完成。
- [ ] macOS 14 部署检查、单元测试、UI 测试和 Release 构建通过。
- [ ] 呼出性能 P95 小于 120ms。
- [ ] 工作树清洁。
