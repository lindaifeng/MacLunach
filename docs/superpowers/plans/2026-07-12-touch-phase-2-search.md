# 触达阶段二：应用与文件搜索 Implementation Plan

**状态（2026-07-13）：已完成。** 自动化、双架构 Release、性能与真实 macOS 操作验收均已完成；证据见 `docs/verification/phase-2-search.md`。

> **执行说明：** 由当前模型自主规划并逐项执行；不使用 Superpowers 技能或子代理。步骤使用 checkbox 跟踪。

**Goal:** 在不阻塞启动器的前提下交付应用启动、本地文件索引、键盘搜索与 Finder 定位。

**Architecture:** 搜索是启动器核心而非插件。应用发现和文件索引在后台执行；文件索引使用用户独立 SQLite 与 FSEvents 增量更新，协调器只在主线程发布可取消的查询状态。文件索引失败只显示可恢复空状态，应用搜索与三个功能插件继续可用。

**Tech Stack:** Swift 6、SwiftUI、AppKit、NSWorkspace、SQLite3、FSEvents、NSMetadataQuery、XCTest、XCUITest、XcodeGen。

---

## 已确认边界

- 统一部署目标保持 macOS 14.0；不引入 macOS 15 专属 API。
- V1 只索引文件名和元数据，不读取正文；不尝试复刻 Everything 的 NTFS MFT/USN 方案。
- 默认根目录是桌面、文稿、下载；额外目录和外置卷由用户从设置页主动添加。
- SQLite 位于 Application Support/Touch/Search/file-index.sqlite，所有读写运行在 actor 内，不与插件数据混用。
- 首轮扫描每 500 项提交一次，已写入批次立即可搜；FSEvents 丢失事件时只重扫受影响根目录。
- 本阶段不实现截图、Finder 扩展或 XPC；文件结果只使用系统 Finder 定位和 Quick Look。

## 文件结构

| 路径 | 责任 |
| --- | --- |
| Packages/TouchKit/Sources/TouchCore/SearchModels.swift | 查询、结果、索引状态和错误模型。 |
| Packages/TouchKit/Sources/TouchCore/SearchRanking.swift | 标准化、拼音键、模糊评分与排序。 |
| Packages/TouchKit/Sources/TouchCore/FileIndexStore.swift | SQLite schema、迁移、写入、查询和损坏隔离。 |
| Packages/TouchKit/Sources/TouchCore/FileIndexScanner.swift | 后台枚举、排除规则、渐进扫描。 |
| Packages/TouchKit/Sources/TouchCore/FileEventMonitor.swift | FSEvents 事件合并和局部重扫。 |
| Packages/TouchKit/Sources/TouchCore/ApplicationCatalog.swift | 应用发现、使用统计和启动。 |
| TouchApp/Search/SearchEnvironment.swift | 应用、文件索引和设置装配。 |
| TouchApp/Search/SearchCoordinator.swift | 去抖、取消、结果编排与键盘选择。 |
| TouchApp/Search/SearchResultRow.swift | 结果行与匹配高亮。 |
| TouchApp/Search/SearchResultsView.swift | 搜索结果、空状态和键盘动作。 |
| TouchApp/Search/FileIndexSettingsView.swift | 索引目录、状态、排除和重建。 |
| TouchUITests/SearchFlowTests.swift | 启动器搜索流程 UI 回归。 |
| TouchUITests/SearchSettingsTests.swift | 搜索设置 UI 回归。 |
| Scripts/measure-search.sh | 百万记录 Release 查询 P95 门槛。 |

## Task 1: 建立搜索模型与排名

**Files:**
- Create: Packages/TouchKit/Sources/TouchCore/SearchModels.swift
- Create: Packages/TouchKit/Sources/TouchCore/SearchRanking.swift
- Create: Packages/TouchKit/Tests/TouchCoreTests/SearchRankingTests.swift

- [x] **Step 1: 写失败测试**

    @Test func exactAndPrefixMatchesPrecedeFuzzyMatches() {
        let results = [
            SearchResult.fixture(title: "Finder", kind: .application),
            SearchResult.fixture(title: "Find My", kind: .application),
            SearchResult.fixture(title: "Calendar", kind: .application)
        ]
        #expect(SearchRanking.sort(results, query: "find").map(\.title) == ["Finder", "Find My", "Calendar"])
    }

    @Test func normalizerAcceptsPinyinInitials() {
        let item = SearchResult.fixture(title: "访达", pinyin: "fang da", initials: "fd", kind: .application)
        #expect(SearchRanking.score(item, query: "fd") > 0)
    }

- [x] **Step 2: 确认测试失败**

Run: swift test --package-path Packages/TouchKit --filter SearchRankingTests

Expected: FAIL，因为 SearchResult 和 SearchRanking 尚不存在。

- [x] **Step 3: 实现最小模型和排序器**

    public enum SearchKind: Sendable { case application, file }

    public struct SearchResult: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let path: String
        public let pinyin: String
        public let initials: String
        public let kind: SearchKind
        public let score: Double
    }

    public enum SearchRanking {
        public static func sort(_ results: [SearchResult], query: String) -> [SearchResult] {
            results.sorted {
                let left = score($0, query: query), right = score($1, query: query)
                return left == right
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    : left > right
            }
        }
    }

评分顺序固定为完全匹配、前缀、拼音/首字母、子序列模糊匹配，再叠加调用方给出的最近使用与频率分数；空查询返回空数组。

- [x] **Step 4: 验证并提交**

Run: swift test --package-path Packages/TouchKit --filter SearchRankingTests

Expected: PASS。

    git add Packages/TouchKit
    git commit -m "feat: add search models and ranking"

## Task 2: 建立可恢复的 SQLite 文件索引

**Files:**
- Create: Packages/TouchKit/Sources/TouchCore/FileIndexStore.swift
- Create: Packages/TouchKit/Tests/TouchCoreTests/FileIndexStoreTests.swift

- [x] **Step 1: 写失败测试**

    @Test func storeFindsPrefixAndPartialFileName() async throws {
        let store = try FileIndexStore.temporary()
        try await store.upsert([
            .fixture(path: "/tmp/项目/设计说明.md"),
            .fixture(path: "/tmp/项目/日报.txt")
        ])
        #expect(try await store.search("设计", limit: 10).map(\.fileName) == ["设计说明.md"])
    }

    @Test func deletingRootRemovesOnlyItsRows() async throws {
        let store = try FileIndexStore.temporary()
        try await store.upsert([.fixture(path: "/a/one.txt"), .fixture(path: "/b/two.txt")])
        try await store.delete(root: "/a")
        #expect(try await store.search("", limit: 10).map(\.path) == ["/b/two.txt"])
    }

- [x] **Step 2: 确认测试失败**

Run: swift test --package-path Packages/TouchKit --filter FileIndexStoreTests

Expected: FAIL，因为索引存储不存在。

- [x] **Step 3: 实现 actor 隔离的数据库**

建立 files 表（path 唯一、root_path、file_name、normalized_name、content_type、size、created_at、modified_at、is_directory）和 roots 表；对 normalized_name、root_path 建索引。所有 SQL 使用 bind 参数；查询先以 LIKE 限定候选，再交给 SearchRanking 排序。

    public actor FileIndexStore {
        public func upsert(_ records: [FileIndexRecord]) throws
        public func search(_ query: String, limit: Int) throws -> [FileIndexRecord]
        public func delete(root: String) throws
        public func statistics() throws -> FileIndexStatistics
    }

遇到 SQLITE_CORRUPT 时原子移动旧库到 file-index.corrupt-timestamp.sqlite，创建新库并返回 needsRebuild，绝不让文件索引错误使应用搜索失效。

- [x] **Step 4: 验证并提交**

Run: swift test --package-path Packages/TouchKit --filter FileIndexStoreTests

Expected: PASS。

    git add Packages/TouchKit
    git commit -m "feat: add recoverable file index store"

## Task 3: 实现后台扫描与 FSEvents 增量更新

**Files:**
- Create: Packages/TouchKit/Sources/TouchCore/FileIndexScanner.swift
- Create: Packages/TouchKit/Sources/TouchCore/FileEventMonitor.swift
- Create: Packages/TouchKit/Tests/TouchCoreTests/FileIndexScannerTests.swift
- Create: Packages/TouchKit/Tests/TouchCoreTests/FileEventMonitorTests.swift

- [x] **Step 1: 写失败测试**

    @Test func scannerExcludesCachesAndTrash() async throws {
        let scan = try await FileIndexScanner.scan(root: fixtureRoot, exclusions: [.cacheDirectories, .trash])
        #expect(scan.records.contains { $0.path.contains("/.Trash/") } == false)
    }

    @Test func eventMonitorCoalescesDescendantEvents() {
        #expect(FileEventMonitor.coalescedRoots(["/a/b/one", "/a/b/two", "/a/c"]) == ["/a/b", "/a/c"])
    }

- [x] **Step 2: 确认测试失败**

Run: swift test --package-path Packages/TouchKit --filter FileIndex

Expected: FAIL，因为扫描器和事件监控器不存在。

- [x] **Step 3: 实现后台工作和局部重扫**

FileIndexScanner 用 FileManager.enumerator 在非主 actor 扫描，跳过 .Trash、Library/Caches、系统根、显式排除与无权限目录；每 500 项写入并经 AsyncStream<FileIndexProgress> 上报。监控器遇到 mustScanSubDirs、userDropped 或 kernelDropped 时请求根目录重扫；普通事件只 upsert 或删除对应 URL。Spotlight 只补充标签、内容类型和 iCloud 占位状态，不读取正文。

    public enum FileIndexEvent: Sendable { case changed(URL), rescanRequired(URL) }

    public protocol FileEventMonitoring: Sendable {
        func start(roots: [URL], handler: @escaping @Sendable (FileIndexEvent) -> Void)
        func stop()
    }

- [x] **Step 4: 验证并提交**

Run: swift test --package-path Packages/TouchKit --filter FileIndex

Expected: PASS。

    git add Packages/TouchKit
    git commit -m "feat: add incremental file indexing"

## Task 4: 实现应用发现、使用排名和异步启动

**Files:**
- Create: Packages/TouchKit/Sources/TouchCore/ApplicationCatalog.swift
- Create: Packages/TouchKit/Tests/TouchCoreTests/ApplicationCatalogTests.swift
- Modify: TouchApp/App/AppDelegate.swift

- [x] **Step 1: 写失败测试**

    @Test func catalogDeduplicatesBundleIdentifiersAndPrefersUserApplication() async throws {
        let catalog = ApplicationCatalog(workspace: StubWorkspace(applications: [systemFinder, userFinder]))
        #expect(await catalog.refresh().count == 1)
    }

    @Test func usageScoreRaisesRecentlyLaunchedApplication() {
        #expect(ApplicationUsageScore(count: 3, lastLaunched: .now) > ApplicationUsageScore(count: 1, lastLaunched: .distantPast))
    }

- [x] **Step 2: 确认测试失败**

Run: swift test --package-path Packages/TouchKit --filter ApplicationCatalogTests

Expected: FAIL，因为 ApplicationCatalog 不存在。

- [x] **Step 3: 实现安全启动**

扫描 /Applications、/System/Applications、~/Applications，并合并 Launch Services 已知 URL；以 bundle identifier 去重，缓存显示名、路径、图标键、拼音键和使用统计。启动使用 NSWorkspace.openApplication 的异步变体；成功后才更新频率。失败返回 SearchActionError.cannotOpen(path:)，不关闭面板。

- [x] **Step 4: 验证并提交**

Run: swift test --package-path Packages/TouchKit --filter ApplicationCatalogTests

Expected: PASS。

    git add Packages/TouchKit TouchApp/App/AppDelegate.swift
    git commit -m "feat: add application discovery and launch ranking"

## Task 5: 接入协调器、结果界面与键盘流程

**Files:**
- Create: TouchApp/Search/SearchEnvironment.swift
- Create: TouchApp/Search/SearchCoordinator.swift
- Create: TouchApp/Search/SearchResultRow.swift
- Create: TouchApp/Search/SearchResultsView.swift
- Modify: TouchApp/Launcher/LauncherView.swift
- Modify: TouchApp/Launcher/SearchBarView.swift
- Create: TouchUITests/SearchFlowTests.swift

- [x] **Step 1: 写失败 UI 测试**

    func testTypingQueryReplacesCardsAndEscapeRestoresCards() {
        let app = XCUIApplication()
        app.launchArguments = ["--show-launcher", "--search-fixture"]
        app.launch()
        app.textFields["search.query"].typeText("finder")
        XCTAssertTrue(app.staticTexts["Finder"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["feature.me.touch.finder"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["feature.me.touch.finder"].waitForExistence(timeout: 2))
    }

- [x] **Step 2: 确认测试失败**

Run: xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' -only-testing:TouchUITests/SearchFlowTests/testTypingQueryReplacesCardsAndEscapeRestoresCards test

Expected: FAIL，因为查询尚未显示结果。

- [x] **Step 3: 实现协调与系统动作**

    @MainActor final class SearchCoordinator: ObservableObject {
        @Published private(set) var state = SearchPresentationState.idle
        func update(query: String, mode: SearchMode)
        func moveSelection(by offset: Int)
        func activateSelected(commandModifier: Bool = false)
        func clearOrDismiss() -> SearchDismissal
    }

每次输入取消上一个 Task，等待 40ms 后后台查询；文字存在时以 80ms 交叉淡化显示 SearchResultsView 并隐藏功能卡片，清空后恢复。Esc 首次清空、第二次向面板发送关闭通知；Up/Down 选择、Enter 打开、Command+Enter 调用 NSWorkspace.selectFile、Space 调用 QLPreviewPanel。每一行提供 search.result.<id> accessibility identifier；无结果页给出切换模式、检查范围、重建索引入口。

- [x] **Step 4: 验证并提交**

Run: xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' -only-testing:TouchUITests/SearchFlowTests test

Expected: PASS。

    git add TouchApp TouchUITests
    git commit -m "feat: show searchable application and file results"

## Task 6: 完成搜索设置和恢复路径

**Files:**
- Create: TouchApp/Search/FileIndexSettingsView.swift
- Create: TouchApp/Search/SearchDiagnostics.swift
- Modify: TouchApp/Settings/SettingsRootView.swift
- Create: TouchUITests/SearchSettingsTests.swift

- [x] **Step 1: 写失败设置 UI 测试**

    func testSearchSettingsShowIndexStateAndRebuildAction() {
        let app = XCUIApplication()
        app.launchArguments = ["--open-settings", "--search-fixture"]
        app.launch()
        app.outlines["SettingsSidebar"].staticTexts["搜索"].click()
        XCTAssertTrue(app.staticTexts["索引状态"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["search.rebuild-index"].exists)
    }

- [x] **Step 2: 确认测试失败**

Run: xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' -only-testing:TouchUITests/SearchSettingsTests test

Expected: FAIL，因为搜索设置还是占位内容。

- [x] **Step 3: 实现用户主动授权和索引诊断**

显示根目录、扫描文件数、数据库大小、最后更新时间、状态与排除规则。添加目录仅在用户点击时调起 NSOpenPanel；移除目录调用 FileIndexStore.delete(root:)。重建先停止事件监控、隔离数据库、重扫根目录，运行时显示正在重建，但应用模式始终可用。诊断默认只显示根目录名称和计数，不输出完整文件路径。

- [x] **Step 4: 验证并提交**

Run: xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' -only-testing:TouchUITests/SearchSettingsTests test

Expected: PASS。

    git add TouchApp TouchUITests
    git commit -m "feat: add file index settings and recovery"

## Task 7: 性能、全量回归与 @电脑验收

**Files:**
- Create: Scripts/measure-search.sh
- Create: docs/verification/phase-2-search.md
- Modify: docs/superpowers/plans/2026-07-12-touch-v1-master-plan.md

- [x] **Step 1: 写性能门槛脚本**

脚本创建临时 SQLite，确定性插入 1,000,000 条记录，预热 10 次，测量 100 次 design 与 fd 查询，输出 P50/P95；P95 大于 50ms 时以非零状态退出。

    if (( $(awk "BEGIN { print ($p95 > 50) }") )); then
      print -u2 "Search P95 exceeds 50ms: $p95 ms"
      exit 1
    fi

- [x] **Step 2: 记录基线并优化查询计划**

Run: Scripts/measure-search.sh

Expected: 输出 P50/P95；若超过阈值，使用 EXPLAIN QUERY PLAN 确认命中 normalized_name 索引，再增加覆盖索引 (normalized_name, path, file_name)。不得修改阈值、扩大结果上限或跳过百万级基准。

- [x] **Step 3: 跑阶段质量门槛**

    swift test --package-path Packages/TouchKit
    xcodegen generate
    xcodebuild -project Touch.xcodeproj -scheme Touch -configuration Release -arch arm64 -arch x86_64 build
    xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' test
    Scripts/check-deployment-targets.sh
    Scripts/measure-launcher.sh
    Scripts/measure-search.sh
    git status --short

Expected: 所有命令成功，查询 P95 小于 50ms，工作区干净。

- [x] **Step 4: 用 @电脑实机逐项复测**

验证 Option+Space、应用搜索 Finder 并 Enter 启动、Tab 后文件搜索、Up/Down、Enter、Command+Enter、Space、首次/再次 Esc、添加和移除临时授权目录、创建/改名/删除文件后的索引更新和重建。每次操作后重新读取 UI；问题先加回归测试再修复，修复后重跑本任务全部质量门槛。

- [x] **Step 5: 记录验收并提交**

    git add Scripts docs
    git commit -m "docs: record phase two search verification"

## 计划自检

- 规格第 6 节的应用发现、拼音与使用频率、SQLite 文件名索引、渐进扫描、FSEvents、Spotlight 补充、外置卷选择、状态、重建和失效处理分别映射到 Task 1–7；没有正文全文索引。
- 规格第 5.3 节的 Tab、内容保留、80ms 过渡、键盘导航、Finder 定位、Quick Look 与空状态映射到 Task 5，并在 Task 7 真机复验。
- 搜索保留为核心模块，不向功能插件共享可变状态；SQLite 和 UI 主线程边界明确。
- 已检查计划中没有 TODO、TBD、implement later、fill in details 或 Similar to 占位语；所有任务均列出文件、失败测试、验证命令与提交点。

