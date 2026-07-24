# Scrolling Capture and GIF Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有截图选区链路上实现 QQ 风格手动滚动长截图和区域 GIF 录制，并自动复制结果。

**Architecture:** 将纯图像对齐/拼接和 GIF 会话放入 `ScreenshotFeature`，让 AppKit 协调器负责选区生命周期、HUD 和剪贴板。滚动截图使用多带垂直重叠搜索、像素验证和单向状态机；GIF 使用有界帧会话和 ImageIO 编码。

**Tech Stack:** Swift 6、macOS 14、ScreenCaptureKit/XPC、CoreGraphics/CoreImage、ImageIO、AppKit NSPasteboard。

---

### Task 1: 建立滚动截图算法核心

**Files:**
- Create: `Packages/TouchKit/Sources/ScreenshotFeature/ScrollingCapture.swift`
- Test: `Packages/TouchKit/Tests/ScreenshotFeatureTests/ScrollingCaptureTests.swift`

- [ ] 写测试覆盖重复帧、正常重叠、方向锁定、低置信度拒绝和固定行排除。
- [ ] 实现 `ScrollingFrameAligner`、`ScrollingImageStitcher` 和不可变结果状态；匹配只返回候选，不在低置信度时修改累计图。
- [ ] 用 `CGContext` 按像素复制新增区域，保持 Retina 原始像素；预览通过缩略尺寸生成。
- [ ] 运行 `swift test --package-path Packages/TouchKit --filter ScrollingCaptureTests`。

### Task 2: 建立 GIF 会话与 ImageIO 编码

**Files:**
- Create: `Packages/TouchKit/Sources/ScreenshotFeature/GIFRecording.swift`
- Test: `Packages/TouchKit/Tests/ScreenshotFeatureTests/GIFRecordingTests.swift`

- [ ] 测试 15 FPS 时长、30 秒上限、取消释放和 GIF 可读回。
- [ ] 实现有界帧缓存、采样时间节流、后台编码和 GIF 元数据；不保存鼠标指针。
- [ ] 在超过 30 秒时返回完成原因，在取消时删除临时帧。
- [ ] 运行两个新增测试集，不做全量测试。

### Task 3: 接入捕获服务与协调器

**Files:**
- Modify: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenRecordingAuthorizer.swift`
- Modify: `Packages/TouchKit/Sources/ScreenshotFeature/XPCScreenCaptureService.swift`
- Modify: `TouchApp/Screenshot/ScreenshotCoordinator.swift`
- Modify: `TouchApp/Screenshot/ScreenshotEnvironment.swift`
- Modify: `TouchApp/Screenshot/ScreenshotClipboardWriter.swift`

- [ ] 为区域连续采样增加最小接口，复用现有 XPC 捕获请求，不改变既有单帧协议行为。
- [ ] 将占位扩展路由替换为滚动截图/GIF 会话；完成和取消正确结束任务。
- [ ] 实现完成产物的 PNG/GIF 剪贴板写入，失败时保留旧剪贴板。
- [ ] 把实时状态回调接入选区 HUD/侧边预览；选区遮罩对滚轮采用穿透策略。

### Task 4: 关键里程碑验证

**Files:**
- Modify: `TouchTests/Screenshot/ScreenshotCoordinatorTests.swift`（仅在现有测试边界需要扩展时）
- Modify: `docs/verification/phase-3-screenshot.md`（记录新验证）

- [ ] 用 `swift test --package-path Packages/TouchKit --filter 'ScrollingCaptureTests|GIFRecordingTests'` 验证算法和编码。
- [ ] 使用现有稳定 Apple Development 签名执行一次 `xcodebuild build`，禁止 `CODE_SIGNING_ALLOWED=NO` 产出 App。
- [ ] 最终按用户要求执行一次完整 TouchKit 和 App 测试，记录已知既有失败，不重复运行无关测试。
- [ ] 检查 `git diff` 和 `git status`，确保不覆盖用户已有修改。
