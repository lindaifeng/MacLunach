# 一念流程隐患与日历体验修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 修复 Finder 中继、功能窗口、设置权限、搜索状态和停用功能的用户流程问题，并将节假日日历改为连续纵向月份浏览。

**Architecture:** 保留现有宿主和插件边界，在 TouchKit 中补齐可测试的请求生命周期与节日数据模型；在 TouchApp 中增加轻量窗口协调和状态反馈；日历 UI 使用 SwiftUI 的 `ScrollViewReader + LazyVStack`，每个月独立渲染。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Package Testing、XCTest/XCUITest。

---

### Task 1: Finder 中继过期与幂等

**Files:**
- Modify: `Packages/TouchKit/Sources/FileActionServiceProtocol/*`、`Packages/TouchKit/Sources/SuperRightFeature/FileActionServiceClient.swift`
- Modify: `Extensions/FinderExtension/*` 与主应用 relay 接收代码
- Test: `Packages/TouchKit/Tests/*` 中 FileAction relay 测试

- [ ] 写一个过期请求测试：创建时间超过有效期时主应用拒绝执行，并返回可诊断错误。
- [ ] 写一个重复 requestID 测试：第二次消费返回幂等结果，不重复调用文件动作。
- [ ] 运行对应 Package 测试，确认先失败。
- [ ] 给 envelope 增加时间戳、过期时间和 requestID；实现原子终态/删除和消费前校验。
- [ ] 运行对应测试并确认通过。

### Task 2: 统一功能窗口生命周期和层级

**Files:**
- Modify: `TouchApp/FeatureArea/*PanelController.swift`、`TouchApp/FeatureArea/FeaturePanelLifecycle.swift`（如需新增）
- Modify: `TouchApp/App/AppDelegate.swift`
- Test: `TouchTests` 中窗口路由/恢复逻辑测试

- [ ] 写窗口失焦后启动器可恢复、原生关闭可恢复、普通窗口层级一致的行为测试。
- [ ] 运行测试确认失败。
- [ ] 将失焦隐藏改为显式回调，所有 controller 的 `orderOut` 经过统一协调器；统一普通窗口 `level`，移除番茄钟 `orderFrontRegardless` 和永久高层级。
- [ ] 运行测试确认通过并检查所有功能 controller 的调用点。

### Task 3: 设置页真实动作与权限状态

**Files:**
- Modify: `TouchApp/Settings/GeneralSettingsView.swift`
- Modify: `TouchApp/App/AppDelegate.swift`、截图/索引服务的公开状态接口
- Test: `TouchTests` 或 Package 核心状态测试

- [ ] 为更新检查、索引清理分别写状态变更测试（加载、成功、失败、重试）。
- [ ] 运行测试确认失败。
- [ ] 接入已有更新/索引服务；按钮显示进度和结果，失败提供重试；没有可用服务时禁用并给出说明。
- [ ] 将权限行改为统一状态枚举和恢复动作，至少覆盖屏幕录制、日历、通知、文件/Finder 扩展；保留重新检测。
- [ ] 运行测试确认通过。

### Task 4: 搜索模式与停用功能一致性

**Files:**
- Modify: `TouchApp/Search/SearchCoordinator.swift`、`TouchApp/Launcher/SearchBarView.swift`
- Modify: `TouchApp/FeatureArea/FeatureAreaStore.swift`、相关快捷键分配视图
- Test: `TouchTests` 搜索与 FeatureAreaStore 测试

- [ ] 写 Tab 切换保留 query、停用插件不出现在卡片/动作搜索的测试。
- [ ] 运行测试确认失败。
- [ ] 为每个 SearchMode 保存 query；`visiblePlugins` 和快捷键分配过滤 disabled；执行路径返回 disabled 提示。
- [ ] 运行测试确认通过。

### Task 5: 日历连续月份和节日强化

**Files:**
- Modify: `TouchApp/FeatureArea/HolidayCalendarPanelController.swift`
- Modify: `Packages/TouchKit/Sources/HolidayCalendarFeature/HolidayCalendarFeaturePlugin.swift`
- Test: `Packages/TouchKit/Tests/FeaturePluginTests/BuiltInFeatureTests.swift`、`TouchUITests/LauncherSmokeTests.swift`

- [ ] 写 2027 节日数据和月份流可定位当前月份的测试。
- [ ] 运行测试确认失败。
- [ ] 将单月网格替换为 `ScrollViewReader`/`LazyVStack` 连续月份；标题随月份变化；“今天”滚动并选中；节日标签按类型使用显著色带和摘要。
- [ ] 补齐 2027 主要法定节假日与调休表；未知年份使用明确基础数据策略。
- [ ] 运行 Package 测试和最小 UI smoke 检查。

### Task 6: 快速回归

- [ ] 运行 `swift test --package-path Packages/TouchKit`。
- [ ] 运行可用的主应用构建/测试命令；若受环境限制，记录具体原因。
- [ ] 运行 `git diff --check`。
- [ ] 汇总已修复项和仍需真机验证项。

