# 功能工作台、剪贴板、离线翻译与 OCR Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为“一念”增加 Markdown 预览目录抽屉、加密文本/图片剪贴板历史、macOS 15 系统离线翻译，以及无缩略图的独立 OCR 工作台。

**Architecture:** TouchKit 承载领域模型、加密存储、工作流协议和可替换 Provider；Touch App 承载系统剪贴板、截图/OCR、窗口和主题化 UI。翻译和 OCR 共用 `ScreenTextCapturing`，OCR 经 `TextWorkflowRouter` 只传递已校对文字；剪贴板只读写一念自有 SQLite 和一念专属钥匙串项目。

**Tech Stack:** Swift 6、SwiftUI、AppKit、WebKit、Translation（macOS 15）、ScreenCaptureKit、Vision、CryptoKit、Security、SQLite3、XCTest、XCUITest、XcodeGen。

---

## 文件结构与职责

| 路径 | 责任 |
| --- | --- |
| `Packages/TouchKit/Sources/MarkdownPreviewFeature/MarkdownOutline.swift` | 预览标题、抽屉可用状态、活动标题纯模型；绝不读取或改写 Markdown 源文件。 |
| `Packages/TouchKit/Sources/ClipboardFeature/ClipboardModels.swift` | 剪贴板领域模型、哈希和复制回写闸门。 |
| `Packages/TouchKit/Sources/ClipboardFeature/EncryptedClipboardRepository.swift` | 应用专属钥匙串密钥、AES-GCM SQLite 载荷、普通历史上限。 |
| `Packages/TouchKit/Sources/TranslationFeature/AppleOnDeviceTranslationProvider.swift` | macOS 15+ Apple Translation 的可替换实现，无网络 Provider。 |
| `TouchApp/FeatureArea/MarkdownPreviewPanelController.swift` | WebKit 预览 DOM 桥接、目录抽屉。 |
| `TouchApp/FeatureArea/ClipboardPasteboardMonitor.swift` | 通用剪贴板监听、图片规范化、回写防重入。 |
| `TouchApp/FeatureArea/ClipboardPanelController.swift` | 剪贴板窗口和主题化列表。 |
| `TouchApp/FeatureArea/TranslationPanelController.swift` | 翻译会话、语言状态和窗口。 |
| `TouchApp/FeatureArea/OCRWorkspacePanelController.swift` | 无缩略图的可编辑 OCR 工作台。 |
| `TouchApp/Screenshot/ScreenTextCaptureBroker.swift` | 受控临时截图、OCR、临时文件删除。 |
| `TouchApp/App/AppDelegate.swift` | 注册插件、分派窗口、启动器恢复、权限页跳转。 |
| `project.yml` | 三个新增 TouchKit product 到 `Touch` target 的依赖。 |

## 实施约束

- 不覆盖、回退或整体暂存用户的既有改动；每次提交只 `git add` 本任务列出的文件。
- 新增源文件或修改 `project.yml` 后，先请用户关闭 Xcode，再运行一次 `xcodegen generate`；其余构建只用 `Touch.xcodeproj`。
- 带标题栏窗口设置 `isMovableByWindowBackground = false`，关闭时调用已有的启动器恢复回调。
- 编辑控件让 responder chain 处理 `⌘C`、`⌘V`、`⌘A`；不得由窗口或全局快捷键抢占。
- 失败日志只记录插件 ID、错误类别、状态码和临时文件删除结果，不记录密码、验证码、图片、OCR 原文或译文。

### Task 1: 建立受保护的实施基线

**Files:**
- Modify: `docs/superpowers/plans/2026-07-20-feature-workspaces-clipboard-translation-ocr.md`
- Test: `Packages/TouchKit/Tests/ClipboardFeatureTests/ClipboardFeatureTests.swift`

- [ ] **Step 1: 记录当前工作区而不修改用户文件。**

Run: `git status --short && git diff -- Packages/TouchKit/Package.swift project.yml TouchApp/App/AppDelegate.swift`

Expected: 输出既有用户修改；确认 `ClipboardFeature`、`TranslationFeature`、`OCRFeature`、`MarkdownOutline.swift` 和 `TextWorkflow.swift` 是未提交骨架，绝不整体暂存。

- [ ] **Step 2: 运行 TouchKit 测试，取得可复现起点。**

Run: `swift test --package-path Packages/TouchKit`

Expected: 测试通过；若当前骨架本身失败，记录精确失败命令和原因，后续以测试修复，不删除测试或权限检查。<br>实际基线记录：已运行 `swift test --package-path Packages/TouchKit`，退出码 `1`；失败来自既有骨架 `Packages/TouchKit/Tests/TranslationFeatureTests/TranslationFeatureTests.swift:8:30`，精确错误为 `'async' call in an autoclosure that does not support concurrency`，触发行是在 `XCTAssertEqual` 的 autoclosure 中直接调用 `plugin.initialState()`；没有删除测试、没有规避权限检查，本轮后续任务会以 TDD 修复。

- [ ] **Step 3: 扫描既有 XCTest 异步 assertion 的编译阻断并分配修复任务。**

Run:

```bash
xct_assertion='XCTAssert'
await_token='await'
rg -n -g '*Tests.swift' "${xct_assertion}[^\\n]*${await_token}|${await_token}[^\\n]*${xct_assertion}" Packages/TouchKit/Tests
```

Expected: 当前骨架只命中 `TranslationFeatureTests.swift:8` 和 `ClipboardFeatureTests.swift:19,25,27,32`。Task 2 统一覆盖这 5 处最小 Swift 6 修正；没有其他后续计划会执行的 XCTest target 被此类 autoclosure 阻断。修正均为先等待局部变量、再断言，不删除测试且不改变权限、加密或业务行为。

- [ ] **Step 4: 检查计划的空白和工作区空白错误。**

Run:

```bash
plan=docs/superpowers/plans/2026-07-20-feature-workspaces-clipboard-translation-ocr.md
placeholder_pattern='TODO|TBD|implement later|fill in details|Add appropriate error handling|Write tests for the above'
rg -n "$placeholder_pattern" "$plan" | rg -vF "$placeholder_pattern" || true
git diff --check
```

Expected: 过滤掉扫描命令和“占位符扫描”自检说明中出现的完整模式文本后无匹配，`git diff --check` 无错误。

- [ ] **Step 5: 仅提交计划。**

Run:

```bash
git add docs/superpowers/plans/2026-07-20-feature-workspaces-clipboard-translation-ocr.md
git commit -m "docs: plan feature workspaces"
```

Expected: 提交不包含 `.superpowers/`、用户现有业务骨架或任何无关文件。

### Task 2: 连接三个插件产品并重生成工程

**Files:**
- Modify: `Packages/TouchKit/Tests/TranslationFeatureTests/TranslationFeatureTests.swift:6-10`
- Modify: `Packages/TouchKit/Tests/ClipboardFeatureTests/ClipboardFeatureTests.swift:14-33`
- Modify: `project.yml:Touch.dependencies`
- Modify: `Packages/TouchKit/Tests/FeaturePluginTests/BuiltInFeatureTests.swift`
- Modify: `Touch.xcodeproj`（由 XcodeGen 生成）
- Verify: `Packages/TouchKit/Package.swift:20-22,58-60,78-93`（三个 product、target 和 `FeaturePluginTests` 依赖已在既有骨架中声明；仅在实际缺失时修改）

- [ ] **Step 1: 在任何筛选测试前解除 TouchKit 测试编译基线。**

SwiftPM 会先编译关联的测试 target；因此本步骤同时修复 `TranslationFeatureTests.swift:8` 和 `ClipboardFeatureTests.swift:19,25,27,32`，不是扩张 Task 2 的功能范围，而是执行任何 `swift test --filter` 前必要的包级编译前置。

在 `testRequiresMacOS15()` 中先等待状态，再传给 XCTest assertion：

```swift
let initialState = await plugin.initialState()
XCTAssertEqual(initialState, .restricted(message: "需要 macOS 15 才能使用系统离线翻译"))
```

在 `ClipboardFeatureTests.swift` 中将每个异步结果先存为局部变量，再保留原有的 assertion：

```swift
let repeated = try await repo.record(.text("重复"))
XCTAssertEqual(first.id, repeated.id)

let matchingContent = try await repo.search(text: "text-104").first?.1
XCTAssertEqual(matchingContent, "text-104")

let entriesAfterClear = try await repo.entries()
XCTAssertEqual(entriesAfterClear, [ClipboardEntry(id: first.id, createdAt: Date(timeIntervalSince1970: 0), kind: .text, isFavorite: true)])

let ignoresY = await gate.shouldIgnore(fingerprint: "y")
let ignoresFirstX = await gate.shouldIgnore(fingerprint: "x")
let ignoresSecondX = await gate.shouldIgnore(fingerprint: "x")
XCTAssertFalse(ignoresY)
XCTAssertTrue(ignoresFirstX)
XCTAssertFalse(ignoresSecondX)
```

这只是 Swift 6 下对既有测试 autoclosure 的编译修正：不删除或弱化测试、不改变任何 assertion、不规避权限检查，也不改变剪贴板权限或加密语义。

先运行：

```bash
swift test --package-path Packages/TouchKit --filter testRequiresMacOS15
```

Expected: 此筛选测试真正完成编译并通过；由于两组既有 XCTest 阻断均已先解除，SwiftPM 编译 `ClipboardFeatureTests` 时不再中断，之后才能运行本任务其余筛选测试。

- [ ] **Step 2: 为既有插件骨架补充/保留内置 manifest 回归验证。**

`ClipboardFeature`、`TranslationFeature`、`OCRFeature` product，`FeaturePluginTests` 的模块依赖及三个插件类型已在既有骨架中存在。先在该测试文件加入三个 `@testable import`，再添加或保留下列测试；它是回归验证，不假装会先红：

```swift
import Testing
@testable import ClipboardFeature
@testable import TranslationFeature
@testable import OCRFeature
```

```swift
@Test @MainActor func builtInFeatureManifestsIncludeTextWorkspaces() {
    let plugins: [any FeaturePlugin] = [
        ClipboardFeaturePlugin(),
        TranslationFeaturePlugin(systemVersion: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)),
        OCRFeaturePlugin()
    ]
    #expect(Set(plugins.map(\.manifest.id)) == [
        "me.touch.clipboard", "me.touch.translation", "me.touch.ocr"
    ])
}
```

Run: `swift test --package-path Packages/TouchKit --filter builtInFeatureManifestsIncludeTextWorkspaces`

Expected: 基线修复后通过，确认三个既有插件的 manifest ID 没有回归。

- [ ] **Step 3: 先用可执行的工程配置验证暴露真实缺口。**

不编译 App target，直接检查 `project.yml` 中 `Touch` target 的三个 package product。当前命令应以退出码 `1` 失败，因为三项尚未连入 `Touch.dependencies`：

```bash
awk '
  /^  Touch:$/ { in_touch = 1; next }
  in_touch && /^  [[:alnum:]_]+:$/ { exit }
  in_touch && /product: ClipboardFeature$/ { clipboard = 1 }
  in_touch && /product: TranslationFeature$/ { translation = 1 }
  in_touch && /product: OCRFeature$/ { ocr = 1 }
  END { exit !(clipboard && translation && ocr) }
' project.yml
```

Expected: 当前退出码为 `1`；这是本任务的真实工程连接红灯，且不依赖无法编译的 App target。

- [ ] **Step 4: 连接缺失的 Touch target product，并保留既有 Package 声明。**

确认 `Packages/TouchKit/Package.swift` 和 `FeaturePluginTests` 已有三个 product/依赖；只有发现实际缺失时才补充，不能为制造改动而改写既有骨架。

在 `project.yml` 的 `Touch.dependencies` 增加：

```yaml
- package: TouchKit
  product: ClipboardFeature
- package: TouchKit
  product: TranslationFeature
- package: TouchKit
  product: OCRFeature
```

- [ ] **Step 5: 先请用户关闭 Xcode，再重生成并复验工程连接。**

向用户说明：“将修改 `project.yml` 并重生成 `Touch.xcodeproj`，请先关闭 Xcode，避免 Swift Package 图失效。”确认后运行：

```bash
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -showBuildSettings >/dev/null
awk '
  /^  Touch:$/ { in_touch = 1; next }
  in_touch && /^  [[:alnum:]_]+:$/ { exit }
  in_touch && /product: ClipboardFeature$/ { clipboard = 1 }
  in_touch && /product: TranslationFeature$/ { translation = 1 }
  in_touch && /product: OCRFeature$/ { ocr = 1 }
  END { exit !(clipboard && translation && ocr) }
' project.yml
```

Expected: 工程生成成功，静态连接验证退出码为 `0`，`Touch` target 能解析三个 product；不使用禁用签名或 ad-hoc 签名产出可运行应用。

- [ ] **Step 6: 验证并提交。**

Run:

```bash
swift test --package-path Packages/TouchKit --filter testRequiresMacOS15
swift test --package-path Packages/TouchKit --filter builtInFeatureManifestsIncludeTextWorkspaces
git diff --check
git add Packages/TouchKit/Tests/TranslationFeatureTests/TranslationFeatureTests.swift Packages/TouchKit/Tests/ClipboardFeatureTests/ClipboardFeatureTests.swift project.yml Touch.xcodeproj Packages/TouchKit/Tests/FeaturePluginTests/BuiltInFeatureTests.swift
# 仅当 Step 4 发现实际缺失并修改时：git add Packages/TouchKit/Package.swift
git commit -m "build: connect workspace feature products"
```

Expected: 先解除两组基线测试的编译阻断，再通过两个筛选测试和工程连接验证；提交只含本任务的包级测试编译基线修正、工程连接、生成工程及实际发生的 Package/回归测试改动。

### Task 3: 完成 Markdown 预览目录模型和 DOM 桥接

**Files:**
- Modify: `Packages/TouchKit/Sources/MarkdownPreviewFeature/MarkdownOutline.swift`
- Modify: `Packages/TouchKit/Tests/MarkdownPreviewFeatureTests/MarkdownOutlineTests.swift`
- Modify: `TouchApp/FeatureArea/MarkdownPreviewPanelController.swift`
- Create: `TouchTests/FeatureArea/MarkdownPreviewOutlineBridgeTests.swift`

- [ ] **Step 1: 写失败测试，要求使用浏览器实际 anchor。**

```swift
func testOutlineKeepsRenderedAnchorInsteadOfRebuildingSourceAnchor() {
    let state = MarkdownOutlineBuilder().build(
        renderedHeadings: [.init(level: 2, title: "重复", anchor: "rendered-7")],
        mode: .split
    )
    guard case let .available(headings) = state else { return XCTFail() }
    XCTAssertEqual(headings.first?.id, "rendered-7")
}

func testEditingIsRestrictedWithoutSourceParsing() {
    XCTAssertEqual(
        MarkdownOutlineBuilder().build(renderedHeadings: [], mode: .editing),
        .restricted(message: "切换到阅读或分栏模式以查看目录")
    )
}
```

- [ ] **Step 2: 验证失败。**

Run: `swift test --package-path Packages/TouchKit --filter MarkdownOutlineTests`

Expected: `RenderedMarkdownHeading` 和带 anchor 的 `build` 尚未存在而失败。

- [ ] **Step 3: 实现只读预览目录模型。**

```swift
public struct RenderedMarkdownHeading: Equatable, Sendable {
    public let level: Int
    public let title: String
    public let anchor: String
}

public func build(renderedHeadings: [RenderedMarkdownHeading], mode: MarkdownWorkspaceMode) -> MarkdownOutlineState {
    guard mode != .editing else { return .restricted(message: "切换到阅读或分栏模式以查看目录") }
    return .available(renderedHeadings.enumerated().compactMap { index, item in
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...6).contains(item.level), !title.isEmpty, !item.anchor.isEmpty else { return nil }
        return MarkdownHeading(id: item.anchor, level: item.level, title: title, sourceIndex: index)
    })
}
```

保留 tuple 重载给现有 fixture；生产代码只能传入 DOM 的真实 anchor。

- [ ] **Step 4: 从 WebKit 获取标题并实现滚动桥接。**

渲染完成和防抖后的 `scroll` 事件执行：

```swift
Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6')).map((node, index) => ({
  level: Number(node.tagName.slice(1)), title: node.textContent || '',
  anchor: node.id || `touch-heading-${index}`
}))
```

渲染 HTML 时只给无 `id` 的 DOM 标题加 `touch-heading-<index>`；点击目录调用 `document.getElementById(anchor)?.scrollIntoView(...)`。测试确认 Markdown 源文件哈希不变。

- [ ] **Step 5: 验证并提交。**

Run:

```bash
swift test --package-path Packages/TouchKit --filter MarkdownOutlineTests
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/MarkdownPreviewOutlineBridgeTests
git add Packages/TouchKit/Sources/MarkdownPreviewFeature/MarkdownOutline.swift Packages/TouchKit/Tests/MarkdownPreviewFeatureTests/MarkdownOutlineTests.swift TouchApp/FeatureArea/MarkdownPreviewPanelController.swift TouchTests/FeatureArea/MarkdownPreviewOutlineBridgeTests.swift
git commit -m "feat: derive markdown outline from preview"
```

Expected: 标题源自预览 DOM，跳转只滚动预览，Markdown 文件零改动。

### Task 4: 构建主题化 Markdown 左侧目录抽屉

**Files:**
- Modify: `TouchApp/FeatureArea/MarkdownPreviewPanelController.swift`
- Modify: `TouchApp/Appearance/ThemeInteractionStyles.swift`
- Create: `TouchTests/FeatureArea/MarkdownOutlineDrawerTests.swift`
- Modify: `TouchUITests/LauncherSmokeTests.swift`

- [ ] **Step 1: 为抽屉会话状态和无障碍标识写失败测试。**

```swift
func testOutlineDrawerIsRememberedForControllerSession() {
    let model = MarkdownOutlineDrawerModel()
    XCTAssertFalse(model.isPresented)
    model.toggle()
    XCTAssertTrue(model.isPresented)
    model.update(mode: .editing, headings: [])
    XCTAssertTrue(model.isPresented)
    XCTAssertEqual(model.state, .restricted(message: "切换到阅读或分栏模式以查看目录"))
}
```

UI fixture 要求有 `markdown.outline.toggle`、`markdown.outline.item.<anchor>` 和 `markdown.outline.restricted`，并断言纯编辑模式不可跳转。

- [ ] **Step 2: 验证失败。**

Run: `xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/MarkdownOutlineDrawerTests`

Expected: 抽屉 model、主题图标按钮和 identifier 尚未存在而失败。

- [ ] **Step 3: 实现抽屉和图标操作。**

抽屉固定约 240pt 宽，以主题 surface、柔和阴影和短动效呈现。条目左缩进为 `CGFloat(level - 1) * 12`；活动项同时使用加粗文字、圆角背景和前景色。新增或复用自定义图标按钮：

```swift
ThemeIconButton(
    systemName: "list.bullet.indent",
    tooltip: "目录",
    accessibilityLabel: "打开目录",
    action: model.toggle
)
.accessibilityIdentifier("markdown.outline.toggle")
```

在 `.reading`、`.split` 显示真实目录；`.editing` 保持会话开关但显示受限说明。降低透明度使用不透明 surface，减少动态效果禁用位移/缩放。

- [ ] **Step 4: 验证并提交。**

Run:

```bash
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/MarkdownOutlineDrawerTests
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchUITests/LauncherSmokeTests
git add TouchApp/FeatureArea/MarkdownPreviewPanelController.swift TouchApp/Appearance/ThemeInteractionStyles.swift TouchTests/FeatureArea/MarkdownOutlineDrawerTests.swift TouchUITests/LauncherSmokeTests.swift
git commit -m "feat: add markdown outline drawer"
```

Expected: 三主题中抽屉展开/关闭、跳转和活动高亮均通过，编辑模式只有受限说明。

### Task 5: 强化加密剪贴板仓库和数据恢复

**Files:**
- Modify: `Packages/TouchKit/Sources/ClipboardFeature/ClipboardModels.swift`
- Modify: `Packages/TouchKit/Sources/ClipboardFeature/EncryptedClipboardRepository.swift`
- Modify: `Packages/TouchKit/Tests/ClipboardFeatureTests/ClipboardFeatureTests.swift`

- [ ] **Step 1: 写图片、上限、清空和钥匙串隔离的失败测试。**

Task 2 已完成 `ClipboardFeatureTests.swift:19,25,27,32` 的包级 XCTest 编译基线修正；本任务不重复修改或提交这些行。以下红绿循环以已可编译的 `ClipboardFeatureTests` 为起点。

```swift
func testImageRoundTripsAndFavoritesSurviveOrdinaryClear() async throws {
    let repository = try await makeRepository()
    let image = Data([0x89, 0x50, 0x4E, 0x47])
    let entry = try await repository.record(.image(image))
    try await repository.setFavorite(true, id: entry.id)
    try await repository.clearOrdinaryHistory()
    let storedContent = try await repository.content(for: entry.id)
    XCTAssertEqual(storedContent, .image(image))
}

func testResetDeletesOnlyTouchClipboardKey() async throws {
    let provider = RecordingKeyProvider()
    let repository = try EncryptedClipboardRepository(databaseURL: temporaryURL(), keyProvider: provider)
    try await repository.resetPluginData()
    XCTAssertEqual(provider.deletedAccounts, ["encryption-key-v1"])
}
```

补充测试：第二次相同内容只更新、不重复；第 101 条淘汰最旧非收藏项；`clearAll()` 不删密钥，`resetPluginData()` 才删除专属 key；损坏密文为 `.invalidCiphertext`；搜索只解密文本。

- [ ] **Step 2: 验证失败。**

Run: `swift test --package-path Packages/TouchKit --filter ClipboardFeatureTests`

Expected: 图片、可观察的密钥删除范围或错误映射尚未满足而失败。

- [ ] **Step 3: 实现无明文内容的 SQLite 存储。**

`entries` schema 固定为 `id, created, favorite, kind, fingerprint, payload`；`payload` 永远为 AES-GCM `combined`，`fingerprint` 是 SHA-256 去重键。钥匙串查询必须精确限定为：

```swift
[kSecClass as String: kSecClassGenericPassword,
 kSecAttrService as String: "me.touch.launcher.clipboard",
 kSecAttrAccount as String: "encryption-key-v1"]
```

不使用宽泛 Keychain 查询、不枚举钥匙串、不修改任何其他 service/account。数据库使用既有 `FeatureStorageFactory` 的 `Features/me.touch.clipboard/` 命名空间；打开失败抛 `.corruptStore`，让 UI 提供“清除并重建该插件数据”。

- [ ] **Step 4: 验证并提交。**

Run:

```bash
swift test --package-path Packages/TouchKit --filter ClipboardFeatureTests
git add Packages/TouchKit/Sources/ClipboardFeature/ClipboardModels.swift Packages/TouchKit/Sources/ClipboardFeature/EncryptedClipboardRepository.swift Packages/TouchKit/Tests/ClipboardFeatureTests/ClipboardFeatureTests.swift
git commit -m "feat: secure clipboard history storage"
```

Expected: 文本/图片加密往返、100 条淘汰、收藏保留、删除/清空和回写闸门通过；提交只包含本任务的两个生产文件与本任务新增的 Clipboard 测试变化，不重复包含 Task 2 已提交的 XCTest 编译基线修正。

### Task 6: 接入系统剪贴板监听和剪贴板工作台

**Files:**
- Create: `TouchApp/FeatureArea/ClipboardPasteboardMonitor.swift`
- Create: `TouchApp/FeatureArea/ClipboardPanelController.swift`
- Create: `TouchApp/FeatureArea/ClipboardWorkspaceView.swift`
- Create: `TouchTests/FeatureArea/ClipboardPasteboardMonitorTests.swift`
- Create: `TouchUITests/ClipboardWorkspaceTests.swift`

- [ ] **Step 1: 为回写防重入和工作台操作写失败测试。**

```swift
func testCopyWritebackIsIgnoredExactlyOnce() async throws {
    let gate = ClipboardWritebackGate()
    let monitor = ClipboardPasteboardMonitor(pasteboard: fakePasteboard, gate: gate, repository: repository)
    try await monitor.copy(.text("验证码 123456"))
    try await monitor.pollOnce()
    let entriesAfterWriteback = try await repository.entries()
    XCTAssertEqual(entriesAfterWriteback.count, 0)
    fakePasteboard.writeText("验证码 123456")
    try await monitor.pollOnce()
    let entriesAfterExternalCopy = try await repository.entries()
    XCTAssertEqual(entriesAfterExternalCopy.count, 1)
}
```

UI 测试写入文本和 PNG fixture 后验证 `clipboard.search`、`clipboard.filter.image`、`clipboard.clear.all`，并确认图片只有可见行请求解码。

- [ ] **Step 2: 验证失败。**

Run: `xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/ClipboardPasteboardMonitorTests`

Expected: monitor、工作台和 identifier 尚未存在而失败。

- [ ] **Step 3: 实现仅文本/图片的监听器。**

以 `NSPasteboard.changeCount` 轮询，优先 `.string`，其次 `.png` 或 `NSImage.tiffRepresentation` 规范化为 PNG。写回复制前：

```swift
let fingerprint = crypto.fingerprint(content.data)
await gate.markWriteback(fingerprint: fingerprint)
pasteboard.clearContents()
pasteboard.setString(text, forType: .string)
```

图片使用 `.setData(_:forType: .png)`。下一次相同 fingerprint 只消费一次；外部重新复制相同内容仍可入库。监听器不申请屏幕录制或辅助功能权限，也不记录内容。

- [ ] **Step 4: 实现主题化剪贴板窗口。**

顶部放自定义搜索 field、文本/图片筛选和图标工具栏；列表惰性解密/解码图片。复制、收藏、删除、清空均用带 tooltip、VoiceOver label、焦点状态的 `ThemeIconButton`。清空普通、收藏、全部均显示自定义确认层；“清空全部”调用 `clearAll()`，不删除密钥。控制器设置：

```swift
window.isMovableByWindowBackground = false
window.delegate = self
```

`windowWillClose` 停止监听、释放引用并恢复启动器；不得通过永久 `window.level` 覆盖其他窗口。

- [ ] **Step 5: 验证并提交。**

Run:

```bash
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/ClipboardPasteboardMonitorTests
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchUITests/ClipboardWorkspaceTests
git add TouchApp/FeatureArea/ClipboardPasteboardMonitor.swift TouchApp/FeatureArea/ClipboardPanelController.swift TouchApp/FeatureArea/ClipboardWorkspaceView.swift TouchTests/FeatureArea/ClipboardPasteboardMonitorTests.swift TouchUITests/ClipboardWorkspaceTests.swift
git commit -m "feat: add clipboard workspace"
```

Expected: 搜索、复制、收藏、删除、清空、图片惰性加载和回写防重入通过，搜索输入保留 `⌘A`、`⌘C`、`⌘V`。

### Task 7: 实现 macOS 15 Apple 离线翻译 Provider

**Files:**
- Create: `Packages/TouchKit/Sources/TranslationFeature/AppleOnDeviceTranslationProvider.swift`
- Modify: `Packages/TouchKit/Sources/TranslationFeature/TranslationFeature.swift`
- Modify: `Packages/TouchKit/Tests/TranslationFeatureTests/TranslationFeatureTests.swift`

- [ ] **Step 1: 使用 fake backend 写失败状态机测试。**

```swift
func testProviderMapsDownloadAndUnsupportedAvailability() async {
    let provider = AppleOnDeviceTranslationProvider(backend: FakeBackend(
        availability: [.installed, .needsDownload, .unsupported]
    ))
    let installedAvailability = await provider.availability(sourceLanguageCode: "en", targetLanguageCode: "zh-Hans")
    let needsDownloadAvailability = await provider.availability(sourceLanguageCode: "en", targetLanguageCode: "ja")
    let unsupportedAvailability = await provider.availability(sourceLanguageCode: "en", targetLanguageCode: "xx")
    XCTAssertEqual(installedAvailability, .installed)
    XCTAssertEqual(needsDownloadAvailability, .needsDownload)
    XCTAssertEqual(unsupportedAvailability, .unsupported)
}

func testMacOS14ProviderNeverCallsBackend() async throws {
    let backend = FakeBackend(availability: [.installed])
    let provider = AppleOnDeviceTranslationProvider(
        systemVersion: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0), backend: backend
    )
    let availability = await provider.availability(sourceLanguageCode: nil, targetLanguageCode: "en")
    XCTAssertEqual(availability, .requiresMacOS15)
    do {
        _ = try await provider.translate("x", sourceLanguageCode: nil, targetLanguageCode: "en")
        XCTFail("Expected macOS 14 translation to fail")
    } catch {
        XCTAssertEqual(error as? TranslationProviderError, .requiresMacOS15)
    }
    let backendCallCount = await backend.callCount
    XCTAssertEqual(backendCallCount, 0)
}
```

- [ ] **Step 2: 验证失败。**

Run: `swift test --package-path Packages/TouchKit --filter TranslationFeatureTests`

Expected: Provider、backend 协议和 macOS 14 短路尚未存在而失败。

- [ ] **Step 3: 添加可替换的 Apple backend。**

```swift
public protocol AppleTranslationBackend: Sendable {
    func supportedLanguages() async -> [TranslationLanguage]
    func availability(source: String?, target: String) async -> TranslationAvailability
    func prepare(source: String?, target: String) async throws
    func translate(text: String, source: String?, target: String) async throws -> TranslationOutput
}
```

`AppleOnDeviceTranslationProvider` 在 `majorVersion < 15` 时直接返回/抛 `.requiresMacOS15`，绝不调用 backend。真实 macOS 15 backend 用 `TranslationSession` 和 `LanguageAvailability` 映射 `.installed`、`.needsDownload`、`.unsupported`；仅用户主动点击时才调 `prepareTranslation()`；取消映射 `.cancelled`。不引入 `URLSession`、`.network` capability、云端 key 或大模型实现。

- [ ] **Step 4: 验证插件受限态和未来扩展边界。**

保持 `TranslationFeaturePlugin.initialState()`：

```swift
.restricted(message: "需要 macOS 15 才能使用系统离线翻译")
```

测试断言 `identifier == "apple.on-device"`，manifest 不含 `.network`，另一个 fake `TranslationProvider` 可以不改 UI 会话模型地替换。

- [ ] **Step 5: 验证并提交。**

Run:

```bash
swift test --package-path Packages/TouchKit --filter TranslationFeatureTests
git add Packages/TouchKit/Sources/TranslationFeature/AppleOnDeviceTranslationProvider.swift Packages/TouchKit/Sources/TranslationFeature/TranslationFeature.swift Packages/TouchKit/Tests/TranslationFeatureTests/TranslationFeatureTests.swift
git commit -m "feat: add on-device translation provider"
```

Expected: 测试不依赖真实语言包或网络，macOS 14 永远不会发生翻译调用。

### Task 8: 建立截图文字捕获 Broker 和临时文件清理

**Files:**
- Create: `TouchApp/Screenshot/ScreenTextCaptureBroker.swift`
- Create: `TouchTests/Screenshot/ScreenTextCaptureBrokerTests.swift`
- Modify: `TouchApp/App/AppDelegate.swift`

- [ ] **Step 1: 写取消、无文字、超时和临时图片删除的失败测试。**

```swift
func testCaptureDeletesTemporaryImageAfterRecognition() async throws {
    let fileStore = SpyTemporaryCaptureStore()
    let broker = ScreenTextCaptureBroker(selection: selection, recognizer: recognizer, fileStore: fileStore)
    let captureResult = try await broker.captureText()
    XCTAssertEqual(captureResult.text, "Hello")
    XCTAssertEqual(fileStore.deletedURLs, [fileStore.createdURL])
}

func testCaptureWithoutTextThrowsNoTextAndDoesNotOpenWindow() async {
    do {
        _ = try await broker.captureText()
        XCTFail("Expected no text error")
    } catch {
        XCTAssertEqual(error as? ScreenTextCaptureError, .noText)
    }
}
```

- [ ] **Step 2: 验证失败。**

Run: `xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/ScreenTextCaptureBrokerTests`

Expected: broker、受控临时文件 store 和 test double 尚未存在而失败。

- [ ] **Step 3: 复用既有截图选区与 OCR 服务实现窄代理。**

`ScreenTextCaptureBroker` 遵守 `ScreenTextCapturing`，有任务时抛 `.busy`，不改变普通截图保存、标注、钉图和历史。核心清理逻辑必须为：

```swift
let temporaryURL = try await temporaryStore.write(image)
defer { temporaryStore.remove(temporaryURL) }
let result = try await recognizer.recognize(fileURL: temporaryURL)
guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw ScreenTextCaptureError.noText
}
return ScreenTextCaptureResult(text: result.text, recognizedLanguageCode: result.languageCode)
```

权限缺失返回 `.permissionRequired`；调用方只能显示摘要并跳转 `设置 → 权限`，不得在功能窗口发起授权。取消调用 `cancelCapture()`，日志不得含 `result.text`。

- [ ] **Step 4: 注入主应用、验证并提交。**

Run:

```bash
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/ScreenTextCaptureBrokerTests
git add TouchApp/Screenshot/ScreenTextCaptureBroker.swift TouchTests/Screenshot/ScreenTextCaptureBrokerTests.swift TouchApp/App/AppDelegate.swift
git commit -m "feat: broker temporary screen text capture"
```

Expected: 成功、无文字、失败、取消均删除本次临时文件，且无文字时不创建结果窗口。

### Task 9: 构建上下原文/译文的离线翻译窗口

**Files:**
- Create: `TouchApp/FeatureArea/TranslationPanelController.swift`
- Create: `TouchApp/FeatureArea/TranslationWorkspaceView.swift`
- Create: `TouchTests/FeatureArea/TranslationWorkspaceTests.swift`
- Create: `TouchUITests/TranslationWorkspaceTests.swift`

- [ ] **Step 1: 写翻译会话和语言包下载的失败测试。**

```swift
func testChangingTargetRetainsSourceAndRequestsTranslation() async throws {
    let provider = FakeTranslationProvider(output: .init(
        sourceText: "hello", translatedText: "你好", detectedSourceLanguageCode: "en"
    ))
    let model = TranslationWorkspaceModel(provider: provider)
    await model.load(text: "hello", recognizedLanguageCode: "en")
    await model.selectTarget("zh-Hans")
    XCTAssertEqual(model.sourceText, "hello")
    XCTAssertEqual(model.translatedText, "你好")
    XCTAssertEqual(provider.requests, [("hello", "en", "zh-Hans")])
}
```

补充：`.needsDownload` 只有点击“下载语言包”才调用 `prepare`；`.unsupported` 保留原文；关闭或取消映射为可重试错误；macOS 14 不创建截图任务。

- [ ] **Step 2: 验证失败。**

Run: `xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/TranslationWorkspaceTests`

Expected: workspace model 和窗口尚未存在而失败。

- [ ] **Step 3: 实现窗口和主题化语言控件。**

窗口有上部原文、中央“自动：识别语言 → 用户目标语言”胶囊与交换图标、下部译文。复制动作采用：

```swift
ThemeIconButton(systemName: "doc.on.doc", tooltip: "复制原文", accessibilityLabel: "复制原文") {
    pasteboard.write(model.sourceText)
}
.accessibilityIdentifier("translation.source.copy")
```

目标语言只由用户选；交换不修改 OCR 原文。用 `Task` 保存翻译工作，关闭或取消时 `task.cancel()`；语言包按钮只调 Provider 的 `prepare`。主题化状态块替代默认 `ProgressView`；编辑区不拦截 `⌘C`、`⌘V`、`⌘A`。

- [ ] **Step 4: 执行窗口生命周期和 UI 验证。**

控制器创建原生标题栏窗口，设置 `isMovableByWindowBackground = false`，`windowWillClose` 恢复启动器。所有图标提供 tooltip、VoiceOver、键盘焦点和 identifier。

Run:

```bash
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/TranslationWorkspaceTests
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchUITests/TranslationWorkspaceTests
```

Expected: 上下结构、语言状态、复制、取消、系统要求提示和编辑快捷键通过。

- [ ] **Step 5: 提交。**

Run:

```bash
git add TouchApp/FeatureArea/TranslationPanelController.swift TouchApp/FeatureArea/TranslationWorkspaceView.swift TouchTests/FeatureArea/TranslationWorkspaceTests.swift TouchUITests/TranslationWorkspaceTests.swift
git commit -m "feat: add on-device translation workspace"
```

### Task 10: 构建无缩略图的独立 OCR 工作台

**Files:**
- Create: `TouchApp/FeatureArea/OCRWorkspacePanelController.swift`
- Create: `TouchApp/FeatureArea/OCRWorkspaceView.swift`
- Create: `TouchTests/FeatureArea/OCRWorkspaceTests.swift`
- Create: `TouchUITests/OCRWorkspaceTests.swift`
- Modify: `TouchApp/App/AppDelegate.swift`

- [ ] **Step 1: 写 OCR→翻译只传文字的失败测试。**

```swift
func testTranslateRoutesEditedTextWithoutStartingAnotherCapture() async throws {
    let router = TextWorkflowRouter()
    let recorder = RequestRecorder()
    await router.registerTranslationHandler { await recorder.record($0) }
    let model = OCRWorkspaceModel(text: "初稿", recognizedLanguageCode: "zh-Hans", router: router)
    model.text = "校对后的文字"
    try await model.translate()
    let request = await recorder.value
    XCTAssertEqual(request?.text, "校对后的文字")
    XCTAssertEqual(request?.source, .ocrWorkspace)
}
```

UI fixture 要断言窗口中不存在 `ocr.thumbnail`、`screenshot.recognition.preview` 和图片视图；存在 `ocr.editor`、`ocr.copy`、`ocr.translate`、`ocr.recapture`。

- [ ] **Step 2: 验证失败。**

Run: `xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/OCRWorkspaceTests`

Expected: OCR workspace 类型、控制器和 identifier 尚未存在而失败。

- [ ] **Step 3: 实现编辑优先的 OCR 窗口。**

`OCRWorkspaceView` 只有标题、主题化状态/错误、`TextEditor`（`ocr.editor`）和复制/翻译/重新截图图标；不得引用 `ScreenshotRecognitionResultPanel`，不得保存缩略图、临时图片或 OCR 历史。翻译动作必须构造：

```swift
try await router.routeToTranslation(.init(
    text: text,
    source: .ocrWorkspace,
    recognizedLanguageCode: recognizedLanguageCode
))
```

重新截图先保留上一次校对文本直到新识别成功；失败显示可恢复错误。关闭窗口只释放 transient capture state，不调用任何持久化仓库。

- [ ] **Step 4: 从主应用接入 Router 和生命周期。**

应用只注册一个 `TextWorkflowRouter` 翻译 handler：handler 在 main actor 展示翻译窗口，绝不调用 `captureText()`。翻译和 OCR 各自入口都先调用 broker；`.permissionRequired` 只跳转 `showSettings(section: .permissions)`。两个窗口均 `isMovableByWindowBackground = false`，关闭恢复启动器。

- [ ] **Step 5: 验证并提交。**

Run:

```bash
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/OCRWorkspaceTests
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchUITests/OCRWorkspaceTests
git add TouchApp/FeatureArea/OCRWorkspacePanelController.swift TouchApp/FeatureArea/OCRWorkspaceView.swift TouchTests/FeatureArea/OCRWorkspaceTests.swift TouchUITests/OCRWorkspaceTests.swift TouchApp/App/AppDelegate.swift
git commit -m "feat: add standalone OCR workspace"
```

Expected: 不显示缩略图，编辑/复制/重新截图工作，OCR→翻译只产生一份请求且没有第二次截图。

### Task 11: 注册插件、功能区分派与统一恢复路径

**Files:**
- Modify: `TouchApp/App/AppDelegate.swift:1-22,140-150,510-541`
- Modify: `TouchApp/Settings/FeatureDetailSettingsView.swift`
- Modify: `TouchApp/Settings/GeneralSettingsView.swift`
- Modify: `TouchTests/WorkspaceApplicationLauncherTests.swift`
- Modify: `TouchUITests/SettingsNavigationTests.swift`

- [ ] **Step 1: 写注册和受限状态失败测试。**

```swift
func testFeatureActionHidesLauncherAndRestoresItWhenWindowCloses() {
    let launcher = SpyLauncher()
    let controller = SpyWorkspaceController(onClose: launcher.show)
    controller.show(from: launcher)
    XCTAssertEqual(launcher.hideCalls, 1)
    controller.close()
    XCTAssertEqual(launcher.showCalls, 1)
}

func testTranslationOnMacOS14ShowsRestrictedStateWithoutCapture() async {
    let capture = SpyScreenTextCapture()
    let launcher = WorkspaceApplicationLauncher(
        capture: capture, systemVersion: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0)
    )
    await launcher.openTranslation()
    let captureCallCount = await capture.calls
    XCTAssertEqual(captureCallCount, 0)
}
```

- [ ] **Step 2: 验证失败。**

Run: `xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/WorkspaceApplicationLauncherTests`

Expected: 三个 feature action 未注册或翻译受限态尚未阻断 capture 而失败。

- [ ] **Step 3: 注册插件和分派窗口。**

在 `AppDelegate.swift` 添加：

```swift
import ClipboardFeature
import OCRFeature
import TranslationFeature
```

把 `ClipboardFeaturePlugin()`、`TranslationFeaturePlugin()`、`OCRFeaturePlugin()` 放入 `FeatureAreaStore` 的插件数组；强引用三个 controller。`handlePresentFeaturePanel` 新增三个 case：剪贴板隐藏启动器后显示，翻译先检查 macOS 15 再 capture，OCR 先 capture。不得改动截图、Finder、Markdown、日历、番茄钟现有分派。

- [ ] **Step 4: 统一设置恢复入口。**

功能详情页只显示屏幕录制/系统要求摘要与“前往权限设置”；跳转调用既有 `showSettings(section: .permissions)`。`GeneralSettingsView` 的 `.permissions` 内容是唯一重检和打开系统设置的位置。剪贴板库/密钥失败只提供“清除并重建剪贴板数据”，调用 `resetPluginData()`；不能清理系统或其他应用的钥匙串项目。

- [ ] **Step 5: 验证并提交。**

Run:

```bash
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests/WorkspaceApplicationLauncherTests
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchUITests/SettingsNavigationTests
git add TouchApp/App/AppDelegate.swift TouchApp/Settings/FeatureDetailSettingsView.swift TouchApp/Settings/GeneralSettingsView.swift TouchTests/WorkspaceApplicationLauncherTests.swift TouchUITests/SettingsNavigationTests.swift
git commit -m "feat: register text workspace features"
```

Expected: 功能区可打开三项功能；关闭恢复启动器；macOS 14 不截图、不联网；权限页仍是唯一恢复入口。

### Task 12: 完整自动化、真实 macOS 验收与交付记录

**Files:**
- Create: `docs/verification/2026-07-20-feature-workspaces-clipboard-translation-ocr.md`
- Modify: `docs/superpowers/specs/2026-07-20-feature-workspaces-clipboard-translation-ocr-design.md:4`

- [ ] **Step 1: 运行完整自动化检查。**

Run:

```bash
swift test --package-path Packages/TouchKit
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchTests
xcodebuild test -project Touch.xcodeproj -scheme Touch -only-testing:TouchUITests
git diff --check
```

Expected: 每项通过；若受签名、权限或 fixture 环境限制，文档记录精确命令、失败阶段和原因，绝不写成通过。

- [ ] **Step 2: 真实验证 macOS 14 受限行为。**

在 macOS 14 打开“翻译”，确认显示“需要 macOS 15 才能使用系统离线翻译”；检查日志和网络活动没有翻译请求；关闭后启动器恢复。

Expected: 不启动截图选区、不请求语言包、不网络降级。

- [ ] **Step 3: 真实验证 macOS 15 Apple 语言包和翻译生命周期。**

对未下载语言对点击“下载语言包”，确认系统管理的下载流程；验证已安装语言翻译、语言对不支持、关闭窗口取消；检查日志无原文/译文。

Expected: 译文不改原文，所有错误可恢复，只使用系统离线能力。

- [ ] **Step 4: 验证真实 OCR、Markdown 和剪贴板。**

```text
1. 在已授权屏幕录制的机器打开“翻译”和“OCR 工作台”，分别选取含文字区域。
2. OCR 窗口只显示编辑文字，没有截图缩略图；编辑后翻译不出现第二次选区。
3. 检查服务临时目录；成功、失败、取消和关闭窗口后均无本次临时图片。
4. 在 Markdown 阅读/分栏验证目录跳转和滚动高亮；纯编辑模式受限且源文件哈希不变。
5. 复制文本、PNG、密码、验证码，重启后验证可搜索复制；收藏跨越 100 条仍保留；清空全部后库为空，系统和其他应用钥匙串项目未变化。
```

Expected: 每项实际完成或明确记录受阻状态；自动化不能替代真实权限、XPC、UI 验证。

- [ ] **Step 5: 记录验收并提交。**

验收文档按“代码与单元测试”、“UI 自动化”、“真实 macOS 14”、“真实 macOS 15”、“已知未验证项”分节，包含 Xcode/系统版本、Apple Development 签名和屏幕录制权限状态。将设计规格第 4 行更新为“已实施，验收见对应记录”。

Run:

```bash
git diff --check
git add docs/verification/2026-07-20-feature-workspaces-clipboard-translation-ocr.md docs/superpowers/specs/2026-07-20-feature-workspaces-clipboard-translation-ocr-design.md
git commit -m "docs: verify feature workspaces"
```

Expected: 文档只报告实际运行过的验证和未验证项。

## 实施计划自检

### 规格覆盖

- Markdown H1–H6、抽屉、跳转、滚动高亮、阅读/分栏可用、编辑受限、仅预览 DOM：Task 3–4。
- 文本/图片剪贴板、搜索、复制、收藏、清空、100 条、密码/验证码、回写防重入、专属钥匙串与加密：Task 5–6。
- macOS 15 Apple Translation、自动原文语言、手动目标语言、语言包、macOS 14 受限、无网络回退、取消和 Provider 边界：Task 7、9、11。
- 截图优先翻译/OCR、临时文件删除、无文字/权限/超时恢复、OCR 无缩略图、编辑/复制/翻译/重新截图、无第二次截图：Task 8–10。
- 三主题、图标 tooltip/VoiceOver/焦点、标题栏拖动限定、编辑快捷键、启动器恢复、统一权限页：Task 4、6、9–11。
- 自动化与真实 macOS 验收、日志不泄露敏感内容：Task 12。

### 占位符扫描

实际采用 `placeholder_pattern='TODO|TBD|implement later|fill in details|Add appropriate error handling|Write tests for the above'` 与 `rg -vF "$placeholder_pattern"` 过滤扫描命令和本自检说明自身所含的完整模式文本；过滤后本计划不含该类占位语，也没有“类似某任务”的省略步骤。

### 类型一致性

- OCR→翻译统一使用 `TextTranslationRequest(version:text:source:recognizedLanguageCode:)`。
- 截图文字捕获统一使用 `ScreenTextCapturing.captureText()`、`cancelCapture()` 和 `ScreenTextCaptureResult`。
- 翻译替换边界统一使用 `TranslationProvider`，系统实现为 `AppleOnDeviceTranslationProvider`。
- Markdown 目录生产路径统一使用 `RenderedMarkdownHeading(level:title:anchor:)`，不从 Markdown 源文件补算锚点。
