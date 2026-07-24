# 功能工作台、剪贴板、离线翻译与 OCR 验收记录

## 状态

本记录覆盖 Markdown 预览目录抽屉、加密剪贴板历史、截图优先的系统离线翻译和 OCR 工作台。代码、受影响主应用回归、签名构建和功能区入口的真实界面检查均已执行。

未把尚未执行的真实语言包下载、真实屏幕文字识别或 macOS 14 实机操作写作通过项。

## 验收环境

- 日期：2026-07-21
- 设备：Apple Silicon Mac
- 系统：macOS 15.3（24D60）
- Xcode：16.4（16F6）
- 部署目标：macOS 14.0
- Debug 应用：`.build/xcode-derived-data/Build/Products/Debug/一念.app`
- Bundle ID：`me.touch.launcher`
- 签名：`Apple Development: 1305366530@qq.com (78RXR8XV38)`，Team ID `8YLX494879`

## 已实施能力

### Markdown 预览目录

- 目录只从 WebKit 预览 DOM 的 H1-H6 和实际 anchor 提取；不会解析、格式化或写回 Markdown 源文件。
- 阅读和分栏模式可展开左侧抽屉，点击条目仅滚动预览；编辑模式显示受限说明。
- 预览滚动会同步当前标题的高亮状态。

### 剪贴板

- 后台监听不会随工作台窗口关闭而停止。
- 文本、图片、密码和验证码以应用专属 Keychain 密钥加密后存入专属 SQLite 历史库；不会枚举、读取、修改或删除其他钥匙串项目。
- 正常历史最多保留 100 条，收藏条目不参与淘汰；支持搜索、复制、收藏、删除和清空非收藏记录。
- 重复复制会刷新已有条目的时间，不创建重复数据；复制回写有防重入闸门。
- 已实现旧路径到 `~/Library/Application Support/Touch/Features/me.touch.clipboard/` 的安全迁移，保留 SQLite 的主库、WAL 和 SHM 文件。

### 系统离线翻译

- 功能区入口先进入临时截图选区，OCR 成功后才展示结果窗口；取消、无文字、权限或服务错误不会留下空白窗口。
- 原文语言可自动检测或手动选择，目标语言可手动切换；原文和译文均可复制。
- 仅使用 macOS 15 的 Apple Translation 和由系统管理的语言包；没有 URLSession、云端或大模型翻译回退。
- macOS 14 及更低版本返回明确的“需要 macOS 15”受限状态。

### OCR 工作台

- 功能区入口先截图选区并识别；成功后才显示 OCR 工作台。
- 工作台不保留也不显示截图缩略图，只提供可编辑的校对文本、重新截图、复制和翻译入口。
- OCR 交给翻译时传递当前校对后的纯文字，不会重新截图。

## 自动化与构建证据

| 项目 | 命令或证据 | 结果 |
| --- | --- | --- |
| TouchKit 全量测试 | `swift test --package-path Packages/TouchKit` | XCTest 14/14、Swift Testing 227/227 通过 |
| Markdown 目录模型 | `MarkdownOutlineTests` | 5/5 通过，包含真实渲染 anchor、编辑模式受限和当前标题选择 |
| 剪贴板领域逻辑 | `ClipboardFeatureTests` | 4/4 通过，覆盖加密、去重、收藏、限制、清空、搜索和回写闸门 |
| 翻译领域逻辑 | `TranslationFeatureTests` | 4/4 通过，覆盖 macOS 14 受限与不调用系统会话、纯文字工作流 |
| OCR 插件约束 | `OCRFeatureTests` | 1/1 通过，确认只声明截图和剪贴板写入能力，不声明网络能力 |
| 主应用受影响回归 | `xcodebuild ... -only-testing:TouchTests/FeatureAreaStoreTests/... test` | 4/4 通过：后台监听、数据库迁移、翻译/OCR 均在截图文字成功后才显示结果窗口 |
| 签名 Debug 构建 | `Scripts/test-super-right.sh build` | 通过；主应用、Finder Extension、FileActionService 和 ScreenshotService 均参与构建，使用 Apple Development 签名 |
| 空白错误检查 | `git diff --check` | 通过 |

主应用受影响回归具体覆盖：

1. `testClipboardHistoryMonitoringSurvivesWorkspaceWindowClose`
2. `testClipboardHistoryStorageMigratesLegacyDatabaseIntoFeatureNamespace`
3. `testTranslationWorkspaceCapturesTextBeforeShowingItsResultWindow`
4. `testOCRWorkspaceCapturesTextBeforeShowingItsResultWindow`

## 真实界面检查

在最新签名的 Debug 应用中直接检查启动器，可见 11 个功能卡片；本轮新增入口均已注册并可点击：

- `feature.me.touch.clipboard`，键位 `9`
- `feature.me.touch.translation`，键位 `0`
- `feature.me.touch.ocr`，键位 `-`

剪贴板工作台已实际打开，界面包含“清空非收藏历史”图标动作和“搜索文本历史”输入框；空状态不显示任何剪贴板内容。本次检查不读取或记录真实剪贴板历史，避免暴露密码、验证码或图片内容。

截图识别会读取用户当前屏幕的选区内容。本轮未指定一个可以安全读取的屏幕选区，因此没有执行实际 OCR/翻译文字内容检查；入口的“先截图再展示窗口”时序由上述主应用回归测试验证。

## 已知未验证项

- 当前机器为 macOS 15.3，macOS 14 的受限状态由可测试 Provider 分支覆盖，尚未在独立 macOS 14 实机复测。
- 尚未触发 macOS 系统语言包的首次下载；需要用户选择具体语种并在系统提示中确认下载时，再进行人工验收。当前实现不会改用网络、云端或大模型服务。
- `TouchUITests` 在本机启用 Automation Mode 时于 2026-07-21 超时，测试用例未开始执行；这不是 UI 断言失败。真实界面检查已作为补充证据。
- 全量 `TouchTests` 有 8 项既有失败，均不属于本功能范围：截图权限期望、截图工具栏动作顺序，以及依赖当前运行应用的 `WorkspaceApplicationLauncherTests`。本轮新增和受影响的 4 项回归均通过。
- 全量主应用测试日志仍会报告既有的 `TextWorkflowRouter` 重复实现警告与 XPC/ViewBridge 终止信息；本轮没有通过删除隔离、权限或测试来压制这些日志。

## 证据位置

- TouchKit：`/tmp/touchkit-full-tests-final.log`
- 受影响主应用测试：`/tmp/workspace-affected-tests-final.log`
- 全量主应用测试：`/tmp/touch-full-tests.log`
- UI 自动化启动失败：`/tmp/touch-ui-tests.log`
- Finder/签名构建：`/tmp/super-right-build.log`
