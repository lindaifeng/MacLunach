# 一念（Touch）项目协作与上下文说明

本文件是本仓库提供给 Codex、Claude Code 及其他大模型的项目初始化上下文。每次开始处理任务前，应先阅读本文件，并根据任务需要阅读 `docs/superpowers/` 下对应的设计规格和实施计划。

## 1. 项目概述

**一念**（工程名：`Touch`）是一个面向 macOS 的原生桌面启动器，目标是提供快捷呼出的启动面板、应用与文件搜索、截图工作流、Finder“超级右键”、功能插件管理、设置中心和统一主题系统。

产品原则：

- 快速：通过 `Option + Space` 呼出，启动和搜索不能被后台索引、截图或插件故障阻塞。
- 原生：使用 macOS 能力完成窗口、搜索、截图、Finder 集成和系统服务，但业务能力必须有清晰的模块边界。
- 可恢复：权限缺失、索引失败、XPC 断开或扩展不可用时，给出可恢复状态，不影响其他功能。
- 可测试：核心业务放入本地 Swift Package，使用协议注入和确定性 fixture 测试；系统能力再做集成验证。
- 统一视觉：所有页面和组件必须遵循项目主题、间距、层级、状态和动效规范，禁止出现默认系统样式拼接出的界面。

## 2. 技术栈与工程基线

- Swift 6，启用严格并发检查。
- SwiftUI：页面和组件界面。
- AppKit：`NSPanel`、窗口控制、全局快捷键、Finder/系统交互及必要的系统级能力。
- macOS 最低版本：14.0。
- ScreenCaptureKit：屏幕、窗口和区域捕获。
- Vision、Core Image、Core Graphics、ImageIO：OCR、二维码、图像处理、渲染及 GIF 编码。
- SQLite3、FSEvents、Spotlight/`NSMetadataQuery`：文件索引和增量更新。
- XPC：截图服务与文件操作服务的进程隔离。
- Finder Sync Extension：Finder 右键菜单。
- XCTest、XCUITest：单元、集成和 UI 测试。
- XcodeGen：仅用于从 `project.yml` 重新生成 `Touch.xcodeproj`，不是日常编译工具。

工程主要目标：

| Target | 用途 |
| --- | --- |
| `Touch` | 主应用：启动器、搜索、功能区、设置、截图协调和插件生命周期 |
| `ScreenshotService` | 独立截图 XPC 服务，执行捕获、编码、识别、渲染、历史和文件保留 |
| `FileActionService` | 独立文件操作 XPC 服务，执行新建文件、文件夹、复制路径等动作 |
| `FinderExtension` | Finder Sync 扩展，提供“超级右键”菜单 |
| `TouchTests` | 主应用单元测试 |
| `TouchUITests` | 主应用 UI 测试 |
| `TouchKit` | 本地 Swift Package，承载可测试协议、核心、插件和服务模块 |

## 3. 当前实现状态（2026-07-17）

- 阶段一“原生壳层与插件基础”：已完成，验收记录见 `docs/verification/phase-1-foundation.md`。
- 阶段二“应用与文件搜索”：已完成，验收记录见 `docs/verification/phase-2-search.md`。
- 阶段三“截图、标注与钉图”：主要生产链路已实现，真实 XPC、权限、多屏和持续录制等仍按计划逐项验收；滚动长截图和 GIF 录制有单独设计与计划。
- 阶段四“超级右键”：主链路已实现并完成真实 Finder 验证，当前菜单包含：
  - 新建文件（纯文本、Markdown、RTF、JSON、XML、YAML、CSV、HTML、Swift、Python 等格式）；
  - 新建文件夹；
  - 复制路径；
  - 在终端中打开。
- 超级右键的默认终端可在“设置 → 功能区 → 超级右键”中选择，当前支持已安装的 Terminal、iTerm2、Warp、Ghostty、WezTerm、Alacritty、kitty；设置页只展示当前机器已安装的终端。
- 阶段五“系统集成与更新”和阶段六“发布质量验收”：尚未完成。

不要把“Finder 右键菜单中未显示主应用窗口”当作失败：超级右键动作会通过中继唤起主应用和 XPC 服务，主应用使用 `NSWorkspace.OpenConfiguration` 的 `activates = false` 后台启动，不应抢夺 Finder 焦点或弹出启动面板。

## 4. 总体架构

```text
主应用 Touch
├── 启动器壳层（NSPanel + SwiftUI）
├── 搜索（应用目录、SQLite 文件索引、FSEvents、Spotlight）
├── 功能区和 FeatureRegistry
├── 设置中心和主题系统
├── 截图协调器 / 标注编辑器 / 钉图窗口
├── ScreenshotService.xpc 客户端
└── FileActionService.xpc / Finder Relay 主应用接收端

TouchKit（本地 Swift Package）
├── TouchFeatureAPI              # 插件协议、manifest、状态、设置、存储
├── TouchCore                    # 搜索、索引、主题、偏好和核心模型
├── FinderFeature                # 打开访达等 Finder 功能插件
├── ScreenshotFeature            # 截图领域模型、客户端和插件逻辑
├── ScreenshotServiceProtocol    # 截图 XPC Codable 协议
├── ScreenshotServiceCore        # 截图服务端核心
├── SuperRightFeature            # 超级右键配置和客户端
└── FileActionServiceProtocol    # 文件操作 XPC 协议和版本化信封

系统扩展与服务
├── FinderExtension              # Finder 菜单，独立进程
├── FileActionService.xpc        # 文件动作服务，独立进程
└── ScreenshotService.xpc        # 截图服务，独立进程
```

### 4.1 插件边界

- `FeaturePlugin` 是第一方功能统一入口；`FeatureRegistry` 负责注册、状态隔离、故障隔离和生命周期。
- 插件不得绕过公共协议直接修改其他插件的状态或存储。
- 插件设置通过 `FeatureSettings` 和对应 provider 暴露，持久化使用统一存储工厂/仓库。
- 所有需要用户授权、系统开关或恢复操作的能力，必须统一由“设置 → 权限”管理；功能区设置页只能展示权限状态摘要和“前往权限设置”入口，不能各自承载授权或系统扩展管理界面。
- XPC 请求和响应必须使用版本化 `Codable` 信封，不在跨进程协议中传输大尺寸位图；大文件通过受控文件引用传递。
- XPC 客户端必须有超时、取消、连接失效后的有限重试和故障隔离。

### 4.2 统一权限中心

“设置 → 权限”是全应用唯一的权限与系统扩展管理入口，至少统一管理：

- 屏幕录制、辅助功能、通知、文件与目录访问、完全磁盘访问等系统权限；
- Finder Extension、登录项、后台服务等需要用户在系统设置中启用的系统集成项；
- 每项的“未请求、需要启用、已授权、被拒绝、受限制、通信异常”真实状态。

每个权限项必须提供权限用途说明、当前状态、可执行恢复操作和重新检测。需要跳转系统设置时，由权限页调用对应系统 API 或展示明确步骤；不能在功能区详情页、错误弹窗或 Finder 菜单中重复放置授权按钮。

超级右键的 Finder Extension 归属“设置 → 权限 → Finder 扩展”。超级右键设置页可以显示“已启用 / 未启用 / 通信异常”的摘要，但“管理 Finder 扩展”必须跳转到统一权限页，再由权限页打开 Finder 扩展系统管理界面。

### 4.3 超级右键中继架构

Finder Extension 不能可靠地直接 bootstrap 主应用内嵌的 XPC，因此采用：

```text
FinderExtension
  → 原子请求中继
  → 主应用无激活后台启动
  → FileActionService.xpc
  → 响应中继
  → FinderExtension
```

Debug 构建没有 App Group entitlement 时，中继目录使用 Finder Extension 自己的沙盒容器：

```text
~/Library/Containers/me.touch.launcher.FinderExtension/Data/Library/Application Support/一念/SuperRight/ActionRelay/
```

Release 构建再接入真正的 App Group。不要为了本地 Debug 测试硬编码或伪造 App Group provisioning profile。

## 5. 关键目录与文件

| 路径 | 责任 |
| --- | --- |
| `project.yml` | XcodeGen 工程定义、Target、依赖、签名和 entitlements 配置 |
| `Touch.xcodeproj` | 日常使用的现有 Xcode 工程 |
| `TouchApp/App` | 应用入口、AppDelegate、主应用生命周期 |
| `TouchApp/Launcher` | 启动面板、搜索框、功能卡片、全局快捷键和面板控制 |
| `TouchApp/Search` | 搜索协调、结果列表、文件索引设置和搜索服务 |
| `TouchApp/Screenshot` | 截图捕获协调、选区、标注、缩略图、识别、钉图和导出 |
| `TouchApp/Settings` | 系统设置、功能区设置、插件详情和设置窗口 |
| `TouchApp/Appearance` | 默认玻璃、日间、夜间主题、主题注册表、主题状态和交互样式 |
| `Packages/TouchKit/Sources/TouchFeatureAPI` | 插件公共协议和数据模型 |
| `Packages/TouchKit/Sources/TouchCore` | 搜索、索引、主题、偏好和核心能力 |
| `Packages/TouchKit/Sources/SuperRightFeature` | 超级右键配置、设置 provider、仓库和文件服务客户端 |
| `Packages/TouchKit/Sources/FileActionServiceProtocol` | 文件操作 XPC 协议、模型和版本化 envelope |
| `Packages/TouchKit/Sources/ScreenshotFeature` | 截图插件及截图领域能力 |
| `Packages/TouchKit/Sources/ScreenshotServiceCore` | 截图服务端核心实现 |
| `Extensions/FinderExtension` | Finder 菜单和 Finder 动作派发 |
| `Services/FileActionService` | 文件动作 XPC 服务端 |
| `Services/ScreenshotService` | 截图 XPC 服务端 |
| `TouchTests` / `TouchUITests` | 自动化测试 |
| `Scripts` | 构建、超级右键、性能测量和诊断脚本 |
| `Config` | Debug/Release xcconfig、entitlements |
| `docs/superpowers/specs` | 权威设计规格 |
| `docs/superpowers/plans` | 分阶段实施计划 |
| `docs/verification` | 已完成阶段的验收证据 |

## 6. 权威设计文档

开始涉及产品行为、架构或界面时，优先阅读以下文档，不要仅凭旧对话猜测：

1. `docs/superpowers/specs/2026-07-12-touch-launcher-v1-design.md`：V1 产品范围、启动器、搜索、截图、超级右键、主题、设置、错误处理、性能和测试策略。
2. `docs/superpowers/specs/2026-07-15-touch-theme-system-design.md`：默认高级玻璃、黑夜、白天三套主题的视觉令牌、状态、动效和可访问性。
3. `docs/superpowers/specs/2026-07-16-feature-plugin-architecture.md`：插件协议、生命周期、设置、存储、故障隔离和未来扩展边界。
4. `docs/superpowers/specs/2026-07-16-scrolling-capture-gif-design.md`：滚动长截图和 GIF 录制设计。
5. `docs/superpowers/plans/2026-07-12-touch-v1-master-plan.md`：阶段总路线和依赖顺序。
6. 对应阶段的 `docs/superpowers/plans/2026-07-12-touch-phase-*.md`：具体任务和验收条件。
7. `docs/verification/`：已完成能力的实际验证记录。

若实现与设计规格冲突，先说明冲突并以最新明确的设计规格为准；不要为了通过编译而删除既有验收能力。

## 7. 界面与视觉规范（强制）

- 项目中所有界面不允许使用原生组件和边框。
- 所有组件必须采用项目统一封装或自定义样式，不得直接暴露 SwiftUI/AppKit 默认控件外观、默认边框、默认 padding、默认颜色或默认交互反馈。
- 所有页面必须保持统一的视觉风格、视觉层级、间距、圆角、颜色、阴影、动效、悬停/聚焦/按下状态和可访问性。
- 优先复用 `TouchApp/Appearance` 的主题定义、语义令牌和交互样式；新增页面不得自行硬编码一套颜色或间距。
- 默认高级玻璃、黑夜、白天三套主题都必须可用；不能只实现某一个主题。
- 需要使用系统 API 完成功能时可以使用 AppKit，但系统 API 只用于能力接入，不得把系统默认控件外观直接作为产品 UI。
- 视觉验收要检查间距、对齐、层级、文字对比度、键盘焦点、VoiceOver 标识、减少动态效果和降低透明度等状态。
- 不要用粗暴增加边框的方式“修复”层级问题；优先使用背景层、透明度、阴影、间距、排版和主题令牌建立层级。

## 8. 开发与代码规则

- 所有沟通和代码变更说明使用中文。
- 启动器功能区窗口统一使用 macOS 原生红、黄、绿窗口按钮，并固定在左上角；这是功能区窗口对“不得直接暴露系统默认控件外观”规则的明确例外。打开任一功能区窗口前必须隐藏启动器，用户通过原生关闭按钮关闭功能区窗口后必须重新显示启动器；最小化和放大行为交给 macOS 原生窗口机制。
- 启动器面板与普通功能区窗口必须使用相同的交互窗口层级：用户点击功能区窗口时功能区必须置于启动器之上，点击启动器时启动器也必须置于功能区之上；禁止通过给某一方设置永久更高的普通窗口 `level` 来破坏“当前点击窗口在最前”的原生行为。用户明确启用的置顶功能属于例外，可以使用更高层级。
- 所有带标题栏的窗口只能从顶部标题栏按住拖动，不得通过内容区、卡片、空白背景或表单区域拖动整个窗口；对应 `NSWindow` / `NSPanel` 必须显式设置 `isMovableByWindowBackground = false`。无标题专用浮窗若确需移动，必须提供边界清晰的专用拖动区域，不能把整个交互内容区默认设为窗口拖动区域。
- 所有可编辑文本输入控件必须支持 macOS 标准编辑快捷键：`Command + C` 复制、`Command + V` 粘贴、`Command + A` 全选；自定义 `NSTextView`、SwiftUI 输入框和后续新增输入组件都必须通过 responder chain 或等效实现保留这些能力，窗口或全局快捷键监听不得抢占这些组合键。
- 普通 Swift 代码修改、编译和测试禁止运行 `xcodegen generate`。
- 只有新增/删除编译源文件、增删 Target/Package 或修改 `project.yml` 后，才允许重新生成 `Touch.xcodeproj`。
- 重新生成前必须明确提醒用户关闭 Xcode；生成完成后再重新打开，避免 Xcode 内存中的 Swift Package 图失效。
- 日常构建和测试直接使用现有 `Touch.xcodeproj` 与 `xcodebuild`。
- 遵循 Swift 6 严格并发：跨线程回调要明确隔离；Finder Extension 的 action 不要擅自改成 MainActor 隔离。
- Finder action 必须在 action 开始时同步捕获 Finder 上下文；不要依赖跨进程复制后的 `NSMenuItem.representedObject`。
- 修改 XPC 协议时同步更新协议版本、模型、客户端、服务端和测试，保证旧数据/请求的失败方式可诊断。
- 不得把用户现有改动、未提交代码或其他功能的验收实现 reset、checkout、clean、覆盖或回退。
- 不得为了消除编译错误删除测试、权限检查、故障隔离、日志或可访问性标识。
- 新增文件、Target、Package 或工程配置后，必须验证生成的工程和所有受影响 Target。

## 9. 签名、权限与本地测试

- Debug 可运行构建必须使用钥匙串中的稳定 `Apple Development` 签名。
- 禁止使用 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGN_IDENTITY=-` 或 ad-hoc 签名产出供用户运行的 App、Extension 或 XPC。
- 不要在源码或 `project.yml` 中写死不存在的 Apple ID、Team ID 或 provisioning profile；构建脚本应从本机钥匙串解析可用签名身份。
- 当前稳定签名由脚本自动从钥匙串读取；不要擅自替换用户的签名身份。正式共享能力使用 Release entitlements，Debug 的本地中继不依赖 App Group。
- 所有权限、系统扩展和恢复操作必须统一放在“设置 → 权限”；功能区详情页只显示状态摘要和跳转入口。权限页必须显示真实状态、用途说明和可执行恢复路径，不能显示一个点击后没有动作的“需要授权”。

常用命令：

```bash
# TouchKit 单元测试
swift test --package-path Packages/TouchKit

# 超级右键：首次启用 Finder Extension（通常只需一次）
Scripts/test-super-right.sh setup

# 日常增量构建、注册扩展并重载 Finder（无需重启 Xcode）
Scripts/test-super-right.sh reload

# 只构建 / 查看状态 / 查看日志
Scripts/test-super-right.sh build
Scripts/test-super-right.sh status
Scripts/test-super-right.sh logs

# 检查所有脚本和 Swift 修改的空白问题
git diff --check
```

`Scripts/test-super-right.sh reload` 成功只代表构建、注册、重载 Finder 和签名校验成功，不会主动打开“一念”主窗口，这是预期行为。首次使用 Finder 扩展运行 `setup`；之后通常只需 `reload`，不需要重启 Xcode 或重复授权。

超级右键验证建议：

1. 运行 `Scripts/test-super-right.sh reload`。
2. 在 Finder 中打开一个真实文件夹，右键确认“一念”的四个连续菜单项。
3. 分别验证新建文件、新建文件夹、复制路径、在终端中打开。
4. 在“设置 → 功能区 → 超级右键”中切换默认终端，再重新验证终端动作。
5. 发生问题时查看 `Scripts/test-super-right.sh logs` 或使用 `/usr/bin/log show`，同时检查 ActionRelay 是否有请求/响应残留。
6. 每次 Computer Use/Finder 自动化点击前重新获取当前 accessibility state；其他 Finder 插件会动态改变菜单顺序，不能复用旧的 index。

## 10. 完成任务前的最低验收

根据改动范围选择并执行验证：

- Package/核心逻辑：`swift test --package-path Packages/TouchKit`。
- 主应用或 UI：对应 `xcodebuild test`、`TouchTests`、`TouchUITests`，并进行必要的真实 macOS 操作验证。
- 超级右键：`Scripts/test-super-right.sh reload`，再验证 Finder 菜单和实际文件结果。
- 工程/签名：验证 App、FinderExtension、XPC 的签名和 bundle identifier。
- 所有改动：`git diff --check`。

报告结果时必须区分“代码/单元测试通过”和“真实 Finder、权限、XPC、UI 验证通过”，不能把未执行的验证写成已通过。
