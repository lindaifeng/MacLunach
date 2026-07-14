# 触达阶段三：截图、标注与钉图实施计划

**状态（2026-07-14）：实施中。Task 1–3、11 已完成；Task 4–5 已完成主要生产链路与最小单元测试，真实 XPC/实机验收待补；QQ 式选区工具栏已接入，十三类可见标注/效果工具进入捕获链路，服务端另完成模糊、放大镜和非破坏裁剪；“钉至桌面”已形成基础真实窗口链路，其余视频工具继续实施。**

> **执行说明：** 由当前模型自主规划并逐项执行；不使用 Superpowers 技能或子代理。步骤使用 checkbox 跟踪。以参考视频为交互与工具顺序依据；滚动截图和 GIF 录制已纳入本阶段后续任务，不再作为明确排除项。自动化先跑最小相关集合，只在关键节点跑全量回归；XCUI/Computer Use 等纯基础设施问题设置排查上限，并与产品代码缺陷分开记录。

**Goal:** 交付独立、可恢复、全键盘可操作的截图插件：区域、窗口、全屏、多显示器与延时捕获，浮动缩略图、非破坏性标注、OCR、二维码、取色、钉图和本地历史全部可用，并且任何权限或 `ScreenshotService` 故障都不影响启动器、搜索或其他插件。

**Architecture:** 主应用只负责模式入口、区域选择、缩略图、标注编辑器和钉图窗口；捕获、图片编码、OCR、二维码、渲染导出、历史数据库及文件保留由嵌入式 `ScreenshotService.xpc` 执行。主应用与服务只交换版本化 Codable 信封和受插件目录约束的文件引用，不传递大尺寸位图。`ScreenshotClient` 为每个请求设置超时和取消处理，连接失效时重建一次，连续失败交由 `FeatureRegistry` 隔离截图插件。测试使用协议注入的确定性服务和图片 fixture；真实 XPC、ScreenCaptureKit、权限、多屏和 Space 流程另做集成及实机验收。

**Tech Stack:** Swift 6、SwiftUI、AppKit、ScreenCaptureKit、Vision、Core Image、Core Graphics、Uniform Type Identifiers、SQLite3、NSXPCConnection、XCTest、XCUITest、XcodeGen。

---

## 0. 权威边界与既有实现审计

权威需求：

- `docs/superpowers/specs/2026-07-12-touch-launcher-v1-design.md` 第 4、7、10–15、17 节。
- `docs/superpowers/plans/2026-07-12-touch-v1-master-plan.md` 的阶段顺序和全局提交门槛。
- 所有 Target 和 Swift Package 统一支持 macOS 14.0；高版本 API 必须有 macOS 14 路径。
- 启动器搜索过渡继续使用已经确认的 80ms，本阶段不得回改。

现有代码仅包含：

- `ScreenCaptureService.capturePrimaryDisplay()` 在主进程捕获主显示器、PNG 编码并写剪贴板。
- `ScreenshotFeaturePlugin` 检查屏幕录制权限并调用上述服务。
- 截图设置只有“显示标注工具栏、复制剪贴板、显示钉图”三个布尔值。
- `project.yml` 只有应用、单元测试和 UI 测试 Target，没有 XPC 服务。

因此现有 `ScreenCaptureService` 视为可复用原型而非最终服务边界；迁移期间任何可运行路径都必须保持测试覆盖，XPC 垂直链路通过后才删除主进程捕获实现。

## 1. 不可变实现决策

1. **服务边界**：ScreenCaptureKit 捕获、PNG/HEIF/JPEG 编码、Vision OCR/二维码、Core Image 效果、历史 SQLite 和文件保留全部在 `ScreenshotService.xpc`；选择层、窗口交互、剪贴板和拖放在主应用。
2. **数据传输**：XPC 仅传递小型 Codable `Data`；捕获结果先原子写入 `Application Support/Touch/Features/me.touch.screenshot/`，响应只含 ID、尺寸、时间、UTType、校验值和规范化相对路径。客户端拒绝越出插件根目录的路径。
3. **坐标系统**：领域模型统一使用以虚拟桌面左上为原点的像素无关坐标；UI 边界用 point，捕获请求在选中显示器的 `backingScaleFactor` 下转为像素。多显示器合成保留各屏相对位置与缩放元数据，不假定所有屏同一比例。
4. **捕获语义**：区域与全屏以 display filter + source rect 捕获；窗口以 `desktopIndependentWindow` 捕获并通过配置控制阴影；多屏逐屏捕获后在服务内合成。所有 filter 排除触达主应用、XPC 与钉图/缩略图窗口。
5. **权限语义**：只有用户实际触发截图/OCR/取色时才请求屏幕录制权限。状态明确区分未请求、已授权、被拒绝、受限制；自动化用注入 provider，不修改真实 TCC 数据库。
6. **非破坏性编辑**：原始截图永不被标注覆盖；项目保存 `AnnotationDocument` 图层和编辑历史，导出时统一渲染。撤销/重做作用于文档命令，不保存每一步整图副本。
7. **历史与钉图**：历史默认 30 天或 500 张，先达到者生效；删除先进入插件内部 `.Trash`，24 小时后物理删除。钉图源文件由独立引用计数保护，清历史时必须提示是否删除仍被钉住的源文件。
8. **线程与恢复**：只有 UI 状态在 MainActor；服务工作可取消。连接中断自动重连一次，同一启动周期连续三次失败后将截图插件标记故障，用户“重试”才解除；绝不退出主应用。
9. **可测试性**：所有系统依赖都有协议边界；UI 测试通过 `--screenshot-fixture` 使用固定图片、固定屏幕布局和内存剪贴板，真实系统流程不得被 fixture 证据替代。
10. **派生物**：不得提交 `Packages/TouchKit/.build/`、DerivedData、`Touch.xcodeproj/`、捕获图片、历史数据库或性能原始样本。

## 2. 目标文件结构

```text
Packages/TouchKit/
├── Sources/
│   ├── ScreenshotServiceProtocol/
│   │   ├── ScreenshotXPCProtocol.swift
│   │   ├── ScreenshotServiceEnvelope.swift
│   │   └── ScreenshotServiceModels.swift
│   ├── ScreenshotServiceCore/
│   │   ├── ScreenCaptureEngine.swift
│   │   ├── ScreenshotImagePipeline.swift
│   │   ├── ScreenshotHistoryStore.swift
│   │   ├── ScreenshotRecognitionEngine.swift
│   │   ├── AnnotationRenderer.swift
│   │   └── ScreenshotFileStore.swift
│   └── ScreenshotFeature/
│       ├── ScreenshotModels.swift
│       ├── ScreenshotConfiguration.swift
│       ├── ScreenshotClient.swift
│       ├── ScreenshotFeaturePlugin.swift
│       ├── AnnotationDocument.swift
│       └── PinModels.swift
├── Tests/
│   ├── ScreenshotServiceCoreTests/
│   └── ScreenshotFeatureTests/
Services/ScreenshotService/
├── ScreenshotServiceDelegate.swift
├── ScreenshotServiceEndpoint.swift
└── main.swift
TouchApp/Screenshot/
├── ScreenshotEnvironment.swift
├── ScreenshotCoordinator.swift
├── ScreenshotModeMenu.swift
├── SelectionOverlayController.swift
├── SelectionOverlayView.swift
├── ColorPickerController.swift
├── CaptureCountdownPanel.swift
├── FloatingThumbnailController.swift
├── FloatingThumbnailView.swift
├── AnnotationEditorController.swift
├── AnnotationEditorView.swift
├── AnnotationCanvasView.swift
├── PinWindowController.swift
├── PinWindowManager.swift
├── ScreenshotHistoryView.swift
└── ScreenshotSettingsView.swift
TouchTests/Screenshot/
TouchUITests/ScreenshotFlowTests.swift
TouchUITests/ScreenshotSettingsTests.swift
Scripts/measure-screenshot.sh
Services/ScreenshotServiceTests/（仅在 Xcode Target 需要宿主时创建）
```

文件可在实现时按职责进一步拆分，但不得重新把服务职责放回主应用，也不得让截图模块读写其他插件目录。

## 3. 每个代码提交的共同门槛

每个任务的代码提交前均执行：

```bash
swift test --package-path Packages/TouchKit
xcodegen generate
./Scripts/check-deployment-targets.sh
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' \
  -derivedDataPath /tmp/touch-phase3-derived test
xcodebuild -project Touch.xcodeproj -scheme Touch -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/touch-phase3-derived \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
lipo -archs "/tmp/touch-phase3-derived/Build/Products/Release/触达.app/Contents/MacOS/触达"
service_binary="/tmp/touch-phase3-derived/Build/Products/Release/触达.app/Contents/XPCServices/ScreenshotService.xpc/Contents/MacOS/ScreenshotService"
[[ ! -x "$service_binary" ]] || lipo -archs "$service_binary"
git status --short
```

规则：

- 任务中的目标测试必须先证明在缺少实现时失败，再做最小实现。
- 完整测试与 Release 构建必须基于当前待提交代码，不能复用上一提交日志。
- 受真实 TCC、显示器或 Space 影响的场景必须同时保留 fixture 自动化和真实 macOS 操作证据。
- 性能相关增量从首次缩略图链路可运行起，每次执行 `Scripts/measure-screenshot.sh`；P95 回退超过 10% 即停止提交并定位。
- 每次提交只包含一个任务主题；计划 checkbox 与验证文档只在相应证据实际取得后更新。

---

## Task 1：建立版本化截图领域模型、配置迁移和插件目录边界

**依赖：** 无。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenshotModels.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenshotConfiguration.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenshotFeaturePaths.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotFeatureTests/ScreenshotModelsTests.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotFeatureTests/ScreenshotConfigurationTests.swift`
- Modify: `Packages/TouchKit/Package.swift`
- Modify: `TouchApp/FeatureArea/FeatureConfigurationStore.swift`
- Modify: `TouchTests/FeatureConfigurationStoreTests.swift`

- [x] **Step 1：写失败测试**

覆盖：

- 捕获模式 `region/window/fullScreen/allDisplays/ocrRegion/colorPicker`、延时 `0/3/5/10`、窗口阴影、捕获后动作、缩略图超时、导出格式、历史规则、标注默认值和钉图恢复全部 Codable 往返。
- 从当前 v1 三布尔配置迁移到 v2 后保留原值并补齐默认值；损坏数据只重置截图命名空间且留下带时间戳备份。
- 默认历史为 30 天和 500 张，内部回收为 24 小时。
- `ScreenshotFeaturePaths` 规范化相对路径，拒绝 `..`、符号链接逃逸和其他插件目录。
- 领域错误可区分权限、取消、无显示器、目标失效、服务超时、服务中断、编码、存储、迁移和不兼容协议。

- [x] **Step 2：确认失败**

Run: `swift test --package-path Packages/TouchKit --filter Screenshot`

Expected: FAIL，因为领域模型和 v2 配置尚不存在。

- [x] **Step 3：实现最小模型与迁移**

模型必须 `Codable + Equatable + Sendable`；持久化使用显式 schema version，不依赖枚举声明顺序。保留读取 `me.touch.features.me.touch.screenshot.configuration.v1`，成功迁移后原子写 v2，再删除旧键；失败先备份原始 `Data`。将完整截图配置类型放入 `ScreenshotFeature`，主应用只通过该公共类型更新自身命名空间。

- [x] **Step 4：目标验证、共同门槛并提交**

Commit: `feat: define versioned screenshot models`

## Task 2：建立 XPC 协议、嵌入式服务 Target 和连接恢复骨架

**依赖：** Task 1。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotServiceProtocol/ScreenshotXPCProtocol.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotServiceProtocol/ScreenshotServiceEnvelope.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotServiceProtocol/ScreenshotServiceModels.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenshotClient.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotFeatureTests/ScreenshotClientTests.swift`
- Create: `Services/ScreenshotService/main.swift`
- Create: `Services/ScreenshotService/ScreenshotServiceDelegate.swift`
- Create: `Services/ScreenshotService/ScreenshotServiceEndpoint.swift`
- Modify: `Packages/TouchKit/Package.swift`
- Modify: `project.yml`
- Modify: `Scripts/check-deployment-targets.sh`

- [x] **Step 1：写失败测试**

覆盖：

- 协议信封版本不兼容返回结构化错误，不崩溃。
- 请求 ID 与响应 ID 一致，重复回调只完成一次。
- 客户端超时会取消请求并 invalidate 连接。
- 第一次 interruption 自动建新连接并重试幂等请求一次；非幂等请求不盲重放。
- 三次连续失败进入 isolated health state；成功 health check 清零计数。
- XPC allow-list 只接受 `NSData/NSString/NSNumber/NSArray/NSDictionary` 和协议声明类型。

- [x] **Step 2：确认失败**

Run: `swift test --package-path Packages/TouchKit --filter ScreenshotClientTests`

Expected: FAIL，因为协议和客户端不存在。

- [x] **Step 3：实现 ping/cancel/health 垂直链路**

创建 `ScreenshotServiceProtocol` 产品；`@objc ScreenshotXPCProtocol` 暴露单一 `perform(requestData:reply:)` 和 `cancel(requestID:)`，具体动作在 Codable 信封内版本化。XPC Target bundle id 为 `me.touch.launcher.ScreenshotService`、部署目标 14.0，并嵌入 `触达.app/Contents/XPCServices/`。此任务只实现 ping、取消和结构化 unsupported action，不实现捕获。

- [x] **Step 4：真实 XPC 冒烟测试**

构建 Debug 应用，确认：

```bash
find "$APP/Contents/XPCServices" -maxdepth 2 -type d -name '*.xpc'
plutil -p "$APP/Contents/XPCServices/ScreenshotService.xpc/Contents/Info.plist"
```

从测试宿主调用真实 `ping`，杀掉服务进程后再次调用，验证客户端重连且主应用仍存活。自动化日志必须包含服务 PID 变化和同一主应用 PID。

- [x] **Step 5：共同门槛并提交**

Commit: `feat: add recoverable screenshot xpc service`

## Task 3：重构截图插件入口、权限状态和应用级协调器

**依赖：** Task 2。

**Files:**

- Create: `TouchApp/Screenshot/ScreenshotEnvironment.swift`
- Create: `TouchApp/Screenshot/ScreenshotCoordinator.swift`
- Create: `TouchTests/Screenshot/ScreenshotCoordinatorTests.swift`
- Modify: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenshotFeaturePlugin.swift`
- Modify: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenCaptureService.swift`
- Modify: `Packages/TouchKit/Tests/FeaturePluginTests/BuiltInFeatureTests.swift`
- Modify: `TouchApp/FeatureArea/FeatureAreaStore.swift`
- Modify: `Packages/TouchKit/Sources/TouchCore/FeaturePreferences.swift`
- Modify: `Packages/TouchKit/Sources/TouchCore/FeaturePreferencesStore.swift`
- Modify: `Packages/TouchKit/Tests/TouchCoreTests/FeaturePreferencesStoreTests.swift`
- Modify: `TouchApp/App/AppDelegate.swift`
- Modify: `TouchApp/App/TouchApp.swift`
- Modify: `TouchApp/Launcher/LauncherPanelController.swift`
- Modify: `TouchApp/Settings/SettingsWindowController.swift`

- [x] **Step 1：写失败测试**

覆盖：

- 卡片执行只向 coordinator 发出默认模式请求，不在插件 `perform()` 内捕获、编码或写剪贴板。
- 开始捕获前隐藏启动器；取消或失败后按原状态恢复，成功后不错误抢焦点。
- 未请求权限只在用户动作时请求一次；拒绝进入 restricted，设置页重试后可回 available。
- 截图失败不会改变 Finder 插件与搜索环境状态。
- Coordinator 并发收到第二次请求时取消旧流程或明确返回 busy，不叠加选择层。
- “隐藏启动页卡片”和“停用插件”是两个状态；停用后 registry 为 disabled、关闭 XPC 连接并注销截图快捷键，重新启用只恢复截图插件。

- [x] **Step 2：确认失败**

Run: `xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' -derivedDataPath /tmp/touch-phase3-task3 -only-testing:TouchTests/ScreenshotCoordinatorTests test`

Expected: FAIL，因为 app-level coordinator 尚不存在。

- [x] **Step 3：注入单一环境并移除业务单例依赖**

由 `AppDelegate` 创建 `ScreenshotEnvironment` 和一个 `FeatureAreaStore`，显式注入 launcher/settings；禁止截图流程新增 `static shared`。插件只依赖 `ScreenshotActionRouting`。扩展 `FeaturePreferences` 的启用状态并由 `FeatureRegistry` 作为唯一生命周期来源；隐藏卡片不停止服务，停用才停止服务。现有主进程 `capturePrimaryDisplay()` 暂留为受测试保护的回退，Task 4 完成后删除。

- [x] **Step 4：共同门槛并提交**

Commit: `refactor: route screenshot actions through coordinator`

## Task 4：实现 ScreenCaptureKit 捕获引擎和原子文件输出

**依赖：** Task 3。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/ScreenCaptureEngine.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/ScreenshotFileStore.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/DisplayGeometry.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/ScreenCaptureEngineTests.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/ScreenshotFileStoreTests.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/Fixtures/`
- Modify: `Packages/TouchKit/Package.swift`
- Modify: `Services/ScreenshotService/ScreenshotServiceEndpoint.swift`
- Delete after parity: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenCaptureService.swift`

- [x] **Step 1：写失败测试**

覆盖：

- 区域 rect 在负坐标、多屏不同缩放和 Retina 下转换正确且裁剪不越界。
- 窗口捕获生成 `desktopIndependentWindow` filter，并正确控制阴影边距。
- 全屏优先请求指定 display，不偷偷回退主屏。
- 多屏按虚拟桌面布局合成，透明填充屏幕间空洞并记录每屏元数据。
- 触达主程序、XPC、缩略图、编辑器和钉图 window ID 全部进入排除列表。
- 输出先写同目录临时文件，fsync 后原子 rename；编码失败不留下半文件。
- PNG、JPEG、HEIF 输出 UTType、扩展名和 alpha 策略一致。
- 捕获取消会停止工作且不创建历史记录。

- [x] **Step 2：确认失败**

Run: `swift test --package-path Packages/TouchKit --filter ScreenCaptureEngineTests`

Expected: FAIL。

- [x] **Step 3：实现所有像素捕获模式**

ScreenCaptureKit 路径只使用 macOS 14 可用 API。屏幕/窗口枚举与实际 capture 分开，目标在用户确认后消失时返回 `targetUnavailable`。禁止将整张图通过 XPC 返回；服务写入插件 Captures 目录并响应 `ScreenshotArtifact`。

- [ ] **Step 4：集成验证**

使用真实 XPC 分别捕获主屏、第二屏（存在时）、单窗口和固定区域；检查像素尺寸、文件头、校验值、触达窗口不出现在图中。单屏机器必须通过合成 fixture 覆盖多屏，不得伪称真实多屏通过。

- [ ] **Step 5：共同门槛并提交**

Commit: `feat: capture all screenshot targets in xpc`

## Task 5：实现跨屏区域/窗口选择层与全键盘操作

**依赖：** Task 4。

**Files:**

- Create: `TouchApp/Screenshot/SelectionOverlayController.swift`
- Create: `TouchApp/Screenshot/SelectionOverlayView.swift`
- Create: `TouchApp/Screenshot/SelectionGeometry.swift`
- Create: `TouchApp/Screenshot/WindowSnapResolver.swift`
- Create: `TouchTests/Screenshot/SelectionGeometryTests.swift`
- Create: `TouchTests/Screenshot/WindowSnapResolverTests.swift`
- Create: `TouchUITests/ScreenshotSelectionTests.swift`
- Modify: `TouchApp/Screenshot/ScreenshotCoordinator.swift`

- [x] **Step 1：写失败单元与 UI 测试**

覆盖：

- 拖动创建、八个控制点调整、最小尺寸和屏幕边界约束。
- 按住 Space 拖动整个选区。
- 方向键 1 point、Shift+方向键 10 point；在 Retina 上请求最终像素尺寸正确。
- Esc 取消，Enter 完成；没有选区时 Enter 不捕获。
- 指针进入可见窗口时吸附到窗口 frame，拖动超过阈值解除吸附。
- 光标旁尺寸标签不会越出当前屏且有 VoiceOver 描述。
- 所有 overlay 同时出现在各屏，触达已有窗口在显示 overlay 前隐藏。

- [x] **Step 2：确认失败**

Run: `xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' -derivedDataPath /tmp/touch-phase3-task5 -only-testing:TouchTests/SelectionGeometryTests -only-testing:TouchUITests/ScreenshotSelectionTests test`

Expected: FAIL。

- [x] **Step 3：实现透明无边框 overlay**

每个 `NSScreen` 一个不激活其他应用的 overlay panel，统一由 controller 管理虚拟桌面坐标。选择完成后先关闭全部 overlay，再把规范化请求交给 XPC。窗口吸附使用服务枚举的共享窗口描述，不在 UI 线程调用耗时 ScreenCaptureKit。

- [ ] **Step 4：共同门槛并实机验收**

真实操作鼠标、Space、八点控制、方向键、Shift、Esc、Enter，并在可用多屏与不同缩放下记录截图。当前 XCUITest Runner 停在 `Timed out while enabling automation mode`，Computer Use 无法读取全屏透明 `NSPanel`；两者记录为基础设施限制，不据此判定产品失败，也不继续无限全量重跑。

Commit: `feat: add keyboard accessible screenshot selection`

## Task 6：实现 QQ 式直接拖拽、选区工具栏、延时与扩展捕获入口

**依赖：** Task 5。

**Files:**

- Create: `TouchApp/Screenshot/SelectionToolbarModel.swift`
- Create: `TouchApp/Screenshot/SelectionToolbarLayout.swift`
- Create: `TouchApp/Screenshot/SelectionToolbarView.swift`
- Create: `TouchApp/Screenshot/CaptureCountdownPanel.swift`
- Create: `TouchTests/Screenshot/SelectionToolbarTests.swift`
- Create: `TouchTests/Screenshot/CaptureCountdownTests.swift`
- Create: `TouchUITests/ScreenshotModeTests.swift`
- Modify: `TouchApp/Screenshot/SelectionOverlayController.swift`
- Modify: `TouchApp/Screenshot/ScreenshotCoordinator.swift`
- Modify: `TouchApp/Launcher/GlobalHotKeyController.swift`
- Modify: `TouchApp/FeatureArea/FeatureConfigurationStore.swift`
- Modify: `TouchApp/Settings/ShortcutRecorderView.swift`

- [x] **Step 1：实现 QQ 式直接拖拽和选区后工具栏**

点击截图后直接进入跨屏 overlay，不出现“区域/全屏”前置菜单。用户自行拖动：选区覆盖整块显示器时自动生成 `.display`，否则生成 `.region`；窗口悬停吸附仍生成 `.window`。鼠标松开确认选区后才显示工具栏，创建、移动和调整选区期间隐藏。工具顺序、名称及视频中明确出现的快捷键与参考视频一致；窗口阴影控制位于选区工具栏。

- [x] **Step 2：写最小状态、顺序和几何测试**

覆盖工具顺序、快捷键、工具栏上下避让、拖满屏推断全屏、区域拖拽、窗口阴影传递、Esc/拷贝闭环。当前只把已存在生产代码与已通过的最小测试标记完成；真实视觉验收仍留在 Step 4。

- [ ] **Step 3：实现延时、多屏、滚动截图和 GIF 扩展入口**

3/5/10 秒倒计时不阻塞主线程且可 Esc 取消。多屏与后续滚动截图/GIF 从工具栏或独立快捷键进入，不能重新引入“区域/全屏”前置菜单。全局热键只调度 coordinator；停用插件时注销全部截图快捷键。

增量状态（2026-07-14）：3/5/10 秒可见 HUD、设置入口、主线程非阻塞等待、Esc 与插件停用取消、倒计时结束后立即请求 XPC 捕获均已实现；所有显示器截图现提供默认 `Command+Shift+2` 独立快捷键，配置页可重录并检测插件内外冲突，协调器会读取当前显示器列表并发送真实 `.allDisplays` 请求，产物写入剪贴板。滚动截图与 GIF 工具栏项也已从 UI 占位提示进入可取消的协调器扩展路由，且不会误捕获静态图片。当前关键组合回归 47 个测试通过。滚动截图拼接与 GIF 帧录制/编码尚未完成，因此本 Step 保持未勾选。

- [ ] **Step 4：共同门槛并实机验收**

真实验证直接拖拽区域、拖满屏、窗口吸附与阴影、工具栏避让、延时取消、多屏和各扩展入口。XCUI 自动化模式和 Computer Use 透明 panel 识别失败按基础设施问题限时排查，改用可复核的最小单元/集成证据并保留真实操作待办。

Commit: `feat: add qq-style screenshot selection toolbar`

## Task 7：实现屏幕取色

**依赖：** Task 5。

**Files:**

- Create: `TouchApp/Screenshot/ColorPickerController.swift`
- Create: `TouchApp/Screenshot/ColorPickerLoupeView.swift`
- Create: `TouchTests/Screenshot/ColorFormattingTests.swift`
- Create: `TouchUITests/ScreenshotColorPickerTests.swift`
- Modify: `Packages/TouchKit/Sources/ScreenshotServiceCore/ScreenCaptureEngine.swift`
- Modify: `TouchApp/Screenshot/ScreenshotCoordinator.swift`

- [x] **Step 1：写失败测试**

覆盖 sRGB/Display P3 到标准 sRGB 的转换、HEX/RGB/HSL 文本、Retina 像素定位、边缘采样、Esc 取消、单击复制。像素 loupe 不显示触达自身内容，连续采样有节流且旧请求可取消。

- [x] **Step 2：实现 1×1/小区域 SCK 取样和 loupe**

不得使用绕过权限的私有 API；没有屏幕录制权限时与截图共用单一引导。

增量状态（2026-07-14）：已完成默认 `Control+Option+C` 快捷键、跨显示器透明取色层、十字光标、约 30fps 连续采样、旧请求取消与响应防回跳、Retina 物理像素定位、屏幕边缘放大镜避让、Display P3 到标准 sRGB 转换、HEX/RGB/HSL 展示、单击重新采样并复制 HEX、Esc/插件停用取消，以及 XPC 排除触达自身窗口；取色只返回内存数据，不创建截图文件或历史记录。恢复验证后，颜色模型 2 个测试、`ScreenCaptureEngineTests` 17 个测试、`ColorPickerControllerTests` 与 `ScreenshotCoordinatorTests` 25 个测试均为 0 失败。最新 Debug 应用和已知色块已通过 Computer Use 启动，但其合成 `Control+Option+C` 仍不能触发 Carbon 全局快捷键，且透明取色 panel 无法由 AX 稳定识别；该限制已达到排查上限，不作为产品缺陷。Step 3 保留真实键盘、边缘视觉及可用硬件上的跨屏验收待办，不阻塞后续服务层开发。

- [ ] **Step 3：共同门槛并实机验收**

用已知色块核对 HEX/RGB/HSL；验证不同色彩空间显示器（可用时）和权限拒绝。

Commit: `feat: add screen color picker and ocr region entry`

## Task 8：实现历史数据库、文件生命周期与内部回收区

**依赖：** Task 4。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/ScreenshotHistoryStore.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/ScreenshotRetentionController.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/ScreenshotHistoryStoreTests.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/ScreenshotRetentionControllerTests.swift`
- Modify: `Services/ScreenshotService/ScreenshotServiceEndpoint.swift`

- [x] **Step 1：写失败测试**

覆盖：

- SQLite schema version、迁移、事务与损坏库隔离备份。
- 新捕获元数据（时间、point/pixel 尺寸、模式、相对路径、OCR 摘要、pin 引用）原子插入。
- 时间范围、宽高范围和 OCR 文本组合搜索。
- 30 天/500 张先达到者清理；关闭历史时捕获后按配置保留或删除临时文件。
- 删除进入 `.Trash/<id>/`，24 小时内可恢复，超过后物理删除。
- 清空历史可选择保留钉图源；失败回滚数据库与文件移动。
- 所有 SQL 使用绑定参数，路径永不越出插件根。

- [x] **Step 2：确认失败并实现 actor store**

历史数据库独占 `History/history.sqlite`，不复用搜索数据库。服务启动和每次捕获后做有上限的清理，不在主线程运行。

增量状态（2026-07-14）：已完成独立 SQLite v2 actor store、v1 迁移、损坏库及 WAL/SHM 隔离、绑定参数查询、组合搜索、pin 引用保护、`.Trash/<id>/` 恢复与过期物理删除、事务化批量移动回滚，以及 30 天/最大条数先达到者清理。历史配置已显式随 XPC 捕获请求传输，区域和所有显示器路径均接入；服务启动时限量清理过期回收区，每次成功捕获后在历史启用时原子入库并执行限量保留策略。历史故障只记录诊断，不覆盖已经成功的截图响应。路径同时拒绝遍历、绝对路径及中间符号链接越界。由于主进程必须先读取产物完成复制或钉图，`keepsFilesWhenDisabled == false` 不会在 XPC 响应前删除文件；该分支已在保留控制器单元测试覆盖，服务集成需等待客户端完成确认或临时文件 TTL 后再启用。

- [x] **Step 3：共同门槛并提交**

Commit: `feat: add recoverable screenshot history store`

## Task 9：实现 OCR、二维码识别及后台识别队列

**依赖：** Task 8。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/ScreenshotRecognitionEngine.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/ScreenshotRecognitionEngineTests.swift`
- Add: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/Fixtures/ocr-zh-en.png`
- Add: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/Fixtures/qr.png`
- Modify: `Services/ScreenshotService/ScreenshotServiceEndpoint.swift`
- Modify: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenshotClient.swift`
- Modify: `TouchApp/Screenshot/ScreenshotCoordinator.swift`

- [x] **Step 1：写失败测试**

覆盖中英文混排 OCR、空图、旋转方向、取消、低置信度过滤、多二维码、无二维码、非法 URL 仅作为文本返回。识别完成后更新历史 OCR 字段；任务失败保留原截图并返回可重试错误。

- [x] **Step 2：确认失败并实现 Vision 队列**

OCR 区域入口复用 Task 5 的选区，生成 recognition 请求而不是普通缩略图动作。使用 `VNRecognizeTextRequest` accurate 模式和 `VNDetectBarcodesRequest`；服务内限制并发，响应包含文本块和规范化坐标。OCR 区域模式默认复制识别文本，并提供“查看原图/重试”；二维码结果需用户确认后才打开 URL。

- [ ] **Step 3：共同门槛并实机验收**

对真实中文、英文、二维码各验证一次；记录识别耗时和误差，不上传图片。

增量状态（2026-07-14）：Vision accurate OCR、二维码识别、图片方向元数据、置信度过滤、阅读顺序、XPC recognition 载荷、历史 OCR 摘要更新和默认最多 2 个并发的后台队列均已接通。排队任务取消会立即移出等待队列，不再泄漏许可。OCR 入口复用拖拽选区并使用 `.ocrRegion` 捕获，默认复制文本；结果面板支持文字/二维码列表、复制、查看原图和重新识别，识别失败仍保留原图。二维码只有重新校验为带主机名的 HTTP(S) 地址时才显示打开动作，且打开前必须由用户在系统确认框确认。真实 Vision fixture 已验证中英文、数字、EXIF 旋转、空图和双二维码，单次测试耗时约 0.5–0.8 秒且断言无识别误差；TouchKit 全量 133 个测试通过，应用层协调器与工具栏 36 个测试通过。结果面板的真实鼠标/键盘、VoiceOver 和用户实际截图视觉验收仍待人工完成，因此 Step 3 保持未勾选。

Commit: `feat: recognize screenshot text and qr codes`

## Task 10：实现浮动缩略图、剪贴板、拖放和捕获后动作

**依赖：** Task 4、8、9。

**Files:**

- Create: `TouchApp/Screenshot/FloatingThumbnailController.swift`
- Create: `TouchApp/Screenshot/FloatingThumbnailView.swift`
- Create: `TouchApp/Screenshot/ScreenshotPasteboardWriter.swift`
- Create: `TouchTests/Screenshot/FloatingThumbnailStateTests.swift`
- Create: `TouchUITests/ScreenshotThumbnailTests.swift`
- Modify: `TouchApp/Screenshot/ScreenshotCoordinator.swift`

- [ ] **Step 1：写失败单元和 UI 测试**

覆盖：

- 默认复制并在捕获所在屏右下角显示缩略图；不会落到 Dock/菜单栏外。
- 捕获后动作：仅保存、复制并保存、直接标注、不显示缩略图。
- 单击标注、双击钉图、Command+C、拖到 Finder/其他应用、右键保存/另存为/OCR/钉图/删除。
- 单击与双击判定不会同时执行；拖动取消点击。
- 0/3/5/10 秒或永不自动隐藏；超时仅隐藏，不删除历史。
- 多个连续截图按队列/堆叠策略显示，键盘可聚焦并操作。
- 剪贴板同时提供 PNG/TIFF 与文件 URL，失败时不清空用户原剪贴板。

- [ ] **Step 2：确认失败并实现 panel**

使用无边框非激活 `NSPanel`，缩略图读服务生成的小图而非同步解码原始大图。拖放使用 `NSFilePromiseProvider`，另存为通过安全保存面板；所有文件操作都走 ScreenshotClient。

- [ ] **Step 3：建立首个性能基准**

创建 `Scripts/measure-screenshot.sh`，在 Release + fixture 和真实捕获各采样至少 30 次，记录服务返回到缩略图首帧的 P50/P95；从此任务起门槛为 P95 < 300ms。

- [ ] **Step 4：共同门槛并实机验收**

分别拖入 Finder、TextEdit/预览可接收区域；验证右键动作、超时与多屏定位。

Commit: `feat: add floating screenshot workflow`

## Task 11：实现非破坏性标注文档、命令历史和项目持久化

**依赖：** Task 1、8。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotFeature/AnnotationDocument.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotFeature/AnnotationLayer.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotFeature/AnnotationCommandHistory.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotFeatureTests/AnnotationDocumentTests.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotFeatureTests/AnnotationCommandHistoryTests.swift`
- Modify: `Packages/TouchKit/Sources/ScreenshotServiceCore/ScreenshotFileStore.swift`

- [x] **Step 1：写失败测试**

覆盖所有 layer 类型：箭头、直线、矩形、圆形、画笔、高亮、文字、编号、马赛克、模糊、放大镜和裁剪；颜色、粗细、字体、透明度、z-order、圆角、阴影、边距、渐变背景均可序列化。覆盖 add/remove/update/reorder/crop 的撤销重做、redo 分支清空、合并连续拖动命令、损坏项目回退原图、未知新字段向前兼容。

- [x] **Step 2：确认失败并实现不可变文档 + 命令栈**

项目 JSON 与原图分离并原子保存；不在 undo stack 内复制位图。保存前始终保留可编辑 layer，导出不修改项目。

- [x] **Step 3：共同门槛并提交**

增量状态（2026-07-14）：已完成不可变 `AnnotationDocument`、覆盖全部既有标注类型的可编辑 `AnnotationLayer`、add/remove/update/reorder/crop 命令历史、undo/redo、连续拖动合并和 redo 分支清空。项目 JSON 与原图分离保存到插件目录 `Projects/`，复用同目录临时文件、`fsync`、`rename` 的原子写入协议；缺失或损坏项目均回退为保留原图引用且无可疑图层的文档，路径解析拒绝越界。目标测试 9 个、TouchKit 全量 151 个及应用单元测试 118 个均无失败（其中真实 XPC 屏幕录制测试因宿主无权限跳过 1 个）；Release 应用与 XPC 均为 `x86_64 arm64`。完整内建编辑器 UI 接入属于后续 Task 14，不在本 Task 内宣称完成。

Commit: `feat: add nondestructive annotation documents`

## Task 12：实现标注渲染器与几何/绘制工具

**依赖：** Task 11。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/AnnotationRenderer.swift`
- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/AnnotationGeometry.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/AnnotationRendererTests.swift`
- Add: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/Fixtures/annotation-golden/`
- Modify: `Services/ScreenshotService/ScreenshotServiceEndpoint.swift`

- [ ] **Step 1：写失败测试**

对箭头、线、矩形、圆、画笔、高亮、文字、自动递增编号做确定性 golden image 或像素区域比较；覆盖 Retina scale、文字基线、空路径、极小图、透明度、颜色空间、layer 顺序和取消。Golden 更新必须人工查看差异，不能用无条件覆盖脚本作为通过手段。

- [ ] **Step 2：实现服务端统一渲染**

Core Graphics/Core Text 渲染保持原图色彩空间，预览和最终导出共用同一 renderer 参数。大图采用 autoreleasepool 和有界内存，不在 XPC 响应中返回位图。

- [ ] **Step 3：共同门槛并提交**

Commit: `feat: render screenshot annotation layers`

## Task 13：实现马赛克、模糊、放大镜、裁剪与图片美化

**依赖：** Task 12。

**增量进度（2026-07-14）：** 马赛克画笔、贴纸、水印和美化已进入同一非破坏性图层链路。模糊、放大镜和裁剪现也已完成领域模型、Codable/XPC 载荷、服务端渲染和尺寸元数据：`CIContext` 跨请求复用；模糊只修改矩形 mask；放大镜按受限倍率在圆形 mask 内重采样；裁剪夹紧到画布、只使用最后一个有效图层并在美化前执行。透明图、非有限参数、极小区域、越界/无效裁剪、多个裁剪、裁剪后美化及 2x Retina point/pixel 产物尺寸已有确定性测试。Task 13 的 Core Image/Graphics 增量已完成；完整编辑器交互属于 Task 14，6K 连续导出内存门槛仍待执行，因此本 Task 暂不整体勾选完成。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotServiceCore/AnnotationEffects.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotServiceCoreTests/AnnotationEffectsTests.swift`
- Modify: `Packages/TouchKit/Sources/ScreenshotServiceCore/AnnotationRenderer.swift`
- Modify: `Packages/TouchKit/Sources/ScreenshotFeature/AnnotationDocument.swift`

- [x] **Step 1：写失败测试**

覆盖马赛克块大小、Gaussian blur 边界裁剪、放大镜倍率与圆形 mask、非破坏裁剪、圆角、阴影、四边边距和多色渐变背景。测试极小/超大区域、透明图、超出画布坐标和无效 crop；渲染结果尺寸与元数据必须确定。

- [x] **Step 2：实现 Core Image/Graphics 效果**

CIContext 在服务内复用；效果使用选区 mask，不改变原始图。渲染失败返回 layer ID 和结构化错误，原项目仍可打开并禁用问题图层。

- [ ] **Step 3：共同门槛与内存检查并提交**

对 6K fixture 连续导出 30 次，记录峰值内存且不得线性增长。

Commit: `feat: add screenshot effects and styling`

## Task 14：实现完整标注编辑器 UI、导出和键盘/VoiceOver

**依赖：** Task 11–13。

**Files:**

- Create: `TouchApp/Screenshot/AnnotationEditorController.swift`
- Create: `TouchApp/Screenshot/AnnotationEditorView.swift`
- Create: `TouchApp/Screenshot/AnnotationCanvasView.swift`
- Create: `TouchApp/Screenshot/AnnotationInspectorView.swift`
- Create: `TouchTests/Screenshot/AnnotationEditorStateTests.swift`
- Create: `TouchUITests/ScreenshotAnnotationTests.swift`

- [ ] **Step 1：写失败 UI 与状态测试**

覆盖全部工具创建/选择/移动/调整，颜色、粗细、字体、透明度，圆角/阴影/边距/渐变，Command+Z/Shift+Command+Z，Delete，裁剪确认/取消，保存/另存/复制/导出 PNG/JPEG/HEIF。工具按钮、画布对象和 inspector 有 VoiceOver 标签；键盘可完成工具选择、微调和导出；减少动态效果下没有强制缩放动画。

- [ ] **Step 2：确认失败并实现编辑器**

Canvas 只维护轻量预览和文档状态，最终导出走 XPC renderer。关闭有未保存修改时提示保存/放弃/取消；服务失败保留当前项目并提供重试，不能丢 layer。

- [ ] **Step 3：共同门槛、视觉回归与实机验收**

三套主题、浅/深色、降低透明度、增大对比度、VoiceOver、键盘-only 各验收；逐一实际使用所有工具。

Commit: `feat: add complete screenshot annotation editor`

## Task 15：实现钉图窗口、多图、穿透恢复和持久化

**依赖：** Task 8、10。

**增量进度（2026-07-14）：** QQ 工具栏的“钉至桌面”已不再是占位提示。完成选区后会捕获真实产物并交给独立窗口管理器，创建无边框置顶、等比缩放、可拖动、跨 Space 的钉图窗口；多张图按 artifact ID 独立持有，右键支持复制和关闭。透明度、折叠/展开、鼠标穿透与全局恢复、重启持久化和引用计数仍未完成，因此 Task 15 保持未勾选。

**Files:**

- Create: `Packages/TouchKit/Sources/ScreenshotFeature/PinModels.swift`
- Create: `Packages/TouchKit/Tests/ScreenshotFeatureTests/PinModelsTests.swift`
- Create: `TouchApp/Screenshot/PinWindowController.swift`
- Create: `TouchApp/Screenshot/PinWindowManager.swift`
- Create: `TouchApp/Screenshot/PinContentView.swift`
- Create: `TouchTests/Screenshot/PinWindowManagerTests.swift`
- Create: `TouchUITests/ScreenshotPinTests.swift`
- Modify: `Services/ScreenshotService/ScreenshotServiceEndpoint.swift`

- [ ] **Step 1：写失败测试**

覆盖无边框置顶且不进 Dock、拖动、等比缩放、透明度、折叠/展开、复制、关闭、多图独立状态、跨 Space collection behavior。穿透开启后必须能通过菜单栏项或全局快捷键恢复，不能只依赖已穿透窗口。重启恢复需重新映射缺失屏幕并限制到可见区域；关闭恢复设置时不重建窗口。历史清理保护 pin 源并正确维护引用计数。

- [ ] **Step 2：确认失败并实现 manager**

Pin 元数据写入截图插件命名空间，源文件由服务管理。穿透状态在菜单栏显示明显状态和“恢复全部钉图交互”动作；多张 pin 不共享可变窗口状态。

- [ ] **Step 3：共同门槛并实机验收**

实际创建至少三张 pin，跨 Space、重启应用、改变屏幕布局、开启穿透并从菜单恢复；验证复制、折叠、透明度和关闭。

Commit: `feat: add persistent multi-window screenshot pins`

## Task 16：实现截图历史界面和完整插件设置

**依赖：** Task 6、8–15。

**Files:**

- Create: `TouchApp/Screenshot/ScreenshotHistoryView.swift`
- Create: `TouchApp/Screenshot/ScreenshotSettingsView.swift`
- Create: `TouchTests/Screenshot/ScreenshotSettingsTests.swift`
- Create: `TouchUITests/ScreenshotSettingsTests.swift`
- Modify: `TouchApp/Settings/FeatureDetailSettingsView.swift`
- Modify: `TouchApp/FeatureArea/FeatureConfigurationStore.swift`
- Modify: `TouchApp/FeatureArea/FeatureAreaStore.swift`

- [ ] **Step 1：写失败测试**

设置覆盖：各模式快捷键、默认模式、3/5/10 延时、窗口阴影、保存位置安全书签、命名规则预览、格式/质量、捕获后动作、剪贴板、缩略图开关/超时、历史开关/天数/数量、标注默认值、OCR 语言、二维码行为、pin 恢复/跨 Space/默认透明度。历史 UI 覆盖时间、尺寸、OCR 搜索，打开/标注/钉图/复制/删除/恢复、清空和存储占用。

- [ ] **Step 2：实现完整三级设置**

截图设置仍只出现在功能区 → 截取屏幕，不能新增重复顶层入口。保存目录使用 security-scoped bookmark；失效时回退插件目录并提示重新选择。重置截图插件先说明停止服务、清除范围及 pin 影响，只重置截图配置/数据。

- [ ] **Step 3：共同门槛并实机验收**

修改每类设置并重启确认持久化；关闭历史、改变保留规则、清空与恢复各验证一次。

Commit: `feat: complete screenshot settings and history ui`

## Task 17：强化故障隔离、取消、迁移恢复和服务诊断

**依赖：** Task 2–16。

**Files:**

- Modify: `Packages/TouchKit/Sources/ScreenshotFeature/ScreenshotClient.swift`
- Modify: `Packages/TouchKit/Sources/TouchCore/FeatureRegistry.swift`
- Modify: `TouchApp/Screenshot/ScreenshotEnvironment.swift`
- Modify: `TouchApp/FeatureArea/FeatureAreaStore.swift`
- Create: `TouchTests/Screenshot/ScreenshotFailureRecoveryTests.swift`
- Create: `TouchUITests/ScreenshotFailureRecoveryTests.swift`
- Create: `Services/ScreenshotServiceTests/ScreenshotServiceIntegrationTests.swift`
- Modify: `TouchApp/Settings/FeatureAreaSettingsView.swift`
- Modify: `project.yml`

- [ ] **Step 1：写失败故障矩阵测试**

覆盖：权限未请求/拒绝/重新授权；选择期间取消；请求超时；XPC crash；连接 interruption/invalidation；服务版本不兼容；磁盘满；目录无权限；历史 DB 损坏；项目 JSON 损坏；输出目标消失；迁移失败。每种错误都断言当前任务取消、可恢复数据保留、截图插件状态正确、Finder/搜索/启动器仍可操作。

- [ ] **Step 2：实现恢复与隔离**

客户端重连一次；连续三次服务失败后 registry 标记截图插件故障并停止后台识别，设置页显示脱敏诊断和“重新加载服务/恢复默认”。重试只重置截图失败计数，不重新加载其他插件。所有取消从 UI 传到服务任务。

- [ ] **Step 3：真实故障验收**

捕获中 `kill -9` ScreenshotService，确认主应用 PID 不变、当前任务报错、下一次重连；连续三次杀服务确认隔离，再点重试恢复。不得通过模拟进程崩溃替代这项证据。

- [ ] **Step 4：共同门槛并提交**

Commit: `fix: isolate and recover screenshot service failures`

## Task 18：阶段三 Release 性能、跨架构、可访问性与真实 macOS 总验收

**依赖：** Task 1–17 全部完成。

**Files:**

- Modify: `Scripts/measure-screenshot.sh`
- Create: `docs/verification/phase-3-screenshot.md`
- Modify: `docs/superpowers/plans/2026-07-12-touch-phase-3-screenshot.md`
- Modify: `docs/superpowers/plans/2026-07-12-touch-v1-master-plan.md`

- [ ] **Step 1：完整自动化**

```bash
swift test --package-path Packages/TouchKit
xcodegen generate
./Scripts/check-deployment-targets.sh
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' \
  -derivedDataPath /tmp/touch-phase3-final test
xcodebuild -project Touch.xcodeproj -scheme Touch -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /tmp/touch-phase3-final \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
lipo -archs "/tmp/touch-phase3-final/Build/Products/Release/触达.app/Contents/MacOS/触达"
lipo -archs "/tmp/touch-phase3-final/Build/Products/Release/触达.app/Contents/XPCServices/ScreenshotService.xpc/Contents/MacOS/ScreenshotService"
```

记录每个 suite 的测试数、退出码、日志路径与 `.xcresult`。任何失败都先定位根因、补测试、修复，再重新执行整个集合。

- [ ] **Step 2：双架构与包结构**

验证主程序和 `ScreenshotService.xpc` 均含 `arm64 x86_64`，所有 bundle 的 deployment target 都是 14.0，XPC 正确嵌入且没有 `.build`、DerivedData 或 XcodeGen 产物进入 Git。

- [ ] **Step 3：Release 性能与资源**

至少 30 次采样并记录 P50/P95：

- 用户完成选区/服务返回到浮动缩略图首帧 P95 < 300ms。
- 4K/6K 图片打开编辑器、添加 layer、撤销重做和导出。
- OCR/二维码耗时作为诊断记录，不阻塞启动器 UI。
- 连续 100 次截图、30 次 6K 导出、10 张 pin 后内存不线性增长。
- 空闲 ScreenshotService 无任务时 CPU 接近 0，主应用总体仍满足空闲 CPU/内存目标。

Debug 数据不得作为门槛证据。

- [ ] **Step 4：真实 macOS 操作验收矩阵**

当前 Codex 亲自操作 Release 应用并记录：

1. 区域、窗口（有/无阴影）、指定全屏、所有显示器。
2. 3/5/10 秒延时与 Esc 取消。
3. 八控制点、Space 移动、1/10px 键盘微调、Enter、窗口吸附。
4. OCR 中英文、二维码确认、取色 HEX/RGB/HSL。
5. 缩略图单击、双击、复制、拖到 Finder/其他应用、右键全部动作和超时。
6. 标注全部工具、撤销重做、样式、美化、裁剪和三种格式导出。
7. 三张以上 pin、缩放/透明度/折叠/复制、穿透恢复、跨 Space、重启恢复。
8. 历史时间/尺寸/OCR 搜索、删除恢复、24 小时策略（测试时钟自动化 + 实机即时部分）、清空与 pin 提示。
9. 权限拒绝、重新授权、XPC crash/重连/隔离，不影响启动器搜索和 Finder 插件。
10. 键盘-only、VoiceOver、减少动态效果、降低透明度、增大对比度。
11. 可用时覆盖多显示器、Retina/非 Retina、不同缩放、全屏应用和多个 Space；环境缺少的硬件/系统组合必须明确标为未验证，不能推断通过。

- [ ] **Step 5：文档、状态和最终阶段提交**

`phase-3-screenshot.md` 必须列出：提交范围、自动化数字、Release 路径、架构、性能原始日志、实机步骤、发现并修复的问题、未覆盖环境和已知限制。仅当本计划所有 checkbox 及验收门槛都有证据时，才把阶段三标为完成并将总体路线图阶段四改为待正式审计。

Commit: `docs: record phase three screenshot verification`

---

## 4. 需求—任务—证据映射

| 规格要求 | 实现任务 | 自动化证据 | 真实操作证据 |
| --- | --- | --- | --- |
| 区域/窗口/全屏/多显示器 | 4–6 | 引擎、坐标、模式 UI 测试 | 各模式和多屏/缩放 |
| 3/5/10 秒延时 | 6 | 测试时钟、UI 测试 | 真实计时与取消 |
| OCR 区域/二维码 | 9 | Vision fixture | 中英文、二维码确认 |
| 屏幕取色 | 7 | 色彩转换/坐标测试 | 已知色块与真实显示器 |
| 隐藏自身、尺寸、八控制点、Space、键盘、吸附 | 5 | 几何 + UI 测试 | 鼠标和键盘完整流程 |
| 默认复制和浮动缩略图全部动作 | 10 | 状态 + XCUITest | 复制、拖放、右键、超时 |
| 12 类标注和非破坏图层 | 11–14 | 序列化、undo、golden、UI | 逐工具编辑和重开项目 |
| 样式与美化 | 11、13、14 | renderer/effect 测试 | inspector 与导出 |
| 钉图完整行为 | 15 | 模型、manager、UI 测试 | 多图、Space、穿透、重启 |
| 30 天/500 张历史、搜索、关闭、清空、24h 回收 | 8、16 | DB/测试时钟/UI 测试 | 搜索、删除恢复、清空 |
| XPC、超时、取消、崩溃恢复与隔离 | 2、17 | client/真实 XPC 集成 | kill 服务、重试、其他插件 |
| macOS 14 与双架构 | 2、18 | target 脚本、universal build | Release app 实机 |
| P95 < 300ms | 10、18 | Release 30+ 样本 | 真实捕获样本 |
| 设置、数据边界、迁移 | 1、16、17 | migration/path/settings tests | 设置持久化与重置 |
| 可访问性与全键盘 | 5、6、10、14、18 | accessibility UI assertions | VoiceOver 与键盘-only |

## 5. 阶段三完成定义

只有同时满足以下条件才允许勾选阶段三完成：

- [ ] Task 1–18 全部完成且每个代码提交前都有当前代码的最新共同门槛日志。
- [ ] 规格第 7 节每个项目均存在生产代码、自动化测试和真实操作记录。
- [ ] `ScreenshotService.xpc` 是实际执行边界，主进程不存在捕获、OCR、导出或历史数据库的旁路实现。
- [ ] 权限拒绝、服务超时、服务崩溃、迁移损坏均可恢复且不会影响启动器/搜索/其他插件。
- [ ] 主程序与 ScreenshotService 的 Release 二进制均为 `arm64 x86_64`，部署目标均为 14.0。
- [ ] 截图完成到缩略图首帧 Release P95 < 300ms。
- [ ] 工作树干净，只保留被 `.gitignore` 忽略的本地产物。
- [ ] `docs/verification/phase-3-screenshot.md` 含完整、可复核证据。

阶段三完成不代表 V1 完成；随后严格进入阶段四超级右键，不得提前标记总体目标完成。
