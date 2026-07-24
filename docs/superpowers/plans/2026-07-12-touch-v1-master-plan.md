# 触达 V1 总体实施路线图

> **执行说明：** 由当前模型依据路线图自主规划并执行；不使用 Superpowers 技能或子代理。持续性工程规则仍用 checkbox（`- [ ]`）表示。

**Goal:** 交付一个原生、丝滑、插件隔离的 macOS 桌面启动器，包含应用/文件搜索、三个功能插件、截图工作流、Finder 超级右键、三套主题和完整设置中心。

**Architecture:** 主应用只承载启动器壳层、搜索、功能区、设置导航和插件生命周期。第一方功能通过 `FeaturePlugin` 接入，截图和文件操作运行于独立 XPC 服务，Finder 菜单运行于独立扩展；全部目标统一 macOS 14.0 部署基线。

**Tech Stack:** Swift 6、SwiftUI、AppKit、ScreenCaptureKit、Vision、Quick Look、FSEvents、SQLite3、XPC、Finder Sync Extension、ServiceManagement、XCTest、XCUITest、XcodeGen。

---

## 1. 阶段拆分

### 阶段一：原生壳层与插件基础

**状态：已完成。** 验证记录：`docs/verification/phase-1-foundation.md`。

详细计划：`docs/superpowers/plans/2026-07-12-touch-phase-1-foundation.md`

交付：

- 可构建、可测试的 macOS 14 工程。
- 菜单栏常驻、`Option + Space` 呼出和多屏定位。
- 用户确认的毛玻璃启动页。
- 三套可切换主题。
- `FeaturePlugin`、`FeatureRegistry` 和插件状态隔离。
- 功能区统一管理以及三级设置导航。
- 三个内置功能卡片；“打开访达”真实可用。

验收门槛：发布构建可运行，快捷键呼出 P95 小于 120ms，单元测试和 UI 冒烟测试通过。

### 阶段二：应用与文件搜索

**状态：已完成。** 验证记录：`docs/verification/phase-2-search.md`。

详细计划：`docs/superpowers/plans/2026-07-12-touch-phase-2-search.md`。

交付：

- Launch Services 应用发现、图标缓存、拼音和使用频率排名。
- SQLite 文件名索引、首次增量可搜、FSEvents 更新和 Spotlight 补充。
- 应用/文件 Tab 切换、键盘导航、Quick Look 和 Finder 定位。
- 索引权限、排除规则、外置卷、重建和诊断设置。

验收门槛：100 万索引记录查询 P95 小于 50ms，索引过程不阻塞启动器，文件变化正确增删改。

### 阶段三：截图、标注与钉图

**状态：计划已创建，实施中（Task 1 待开始）。**

详细计划：`docs/superpowers/plans/2026-07-12-touch-phase-3-screenshot.md`。

交付：

- ScreenCaptureKit 区域、窗口、全屏、多屏和延时截图。
- 浮动缩略图、拖拽、复制、保存和捕获后动作。
- 非破坏性标注图层、撤销重做和图片美化。
- OCR、二维码识别、取色、截图历史和钉图。
- 独立 `ScreenshotService` XPC 服务及故障恢复。

验收门槛：截图完成到缩略图出现 P95 小于 300ms，XPC 服务崩溃不关闭启动器，权限拒绝流程可恢复。

### 阶段四：超级右键

**状态：规划完成，待阶段三验收后开始实现。**

详细计划见 `docs/superpowers/plans/2026-07-12-touch-phase-4-super-right.md`。

交付：

- FeatureManifest v2、通用设置宿主和插件作用域存储。
- Finder Sync Extension 上下文菜单。
- `FileActionService` XPC 服务。
- 复制路径、打开终端、新建文件、新建文件夹和剪切五个首版功能。
- 功能开关与排序、内置及自定义文件格式、剪切冲突处理。

验收门槛：Finder 菜单构建 P95 小于 80ms；剪切移动、跨卷和冲突策略通过集成测试；服务失败不影响其他插件。

### 阶段五：系统集成与更新

**状态：待阶段依赖满足后开始。**

详细计划将在阶段四通过验收后创建为 `docs/superpowers/plans/2026-07-12-touch-phase-5-system-integration.md`。

交付：

- SMAppService 开机启动。
- 权限中心、存储清理、诊断包和隐私脱敏。
- 签名、公证和应用内更新。
- 插件版本、健康状态和存储占用统一展示。

验收门槛：全新安装、升级、权限拒绝、更新失败和数据迁移路径均可恢复。

### 阶段六：发布质量验收

**状态：待阶段依赖满足后开始。**

详细计划将在阶段五通过验收后创建为 `docs/superpowers/plans/2026-07-12-touch-phase-6-release.md`。

交付：

- macOS 14、macOS 15 和当前正式版回归。
- `arm64` 与 `x86_64` 构建一致性检查。
- 性能、内存、可访问性、多屏、Space 和高刷新率验收。
- 签名、公证、DMG 和发布检查清单。

验收门槛：设计规格第 17 节完整性清单全部映射到自动化测试或人工验收记录。

## 2. 依赖顺序

```text
阶段一 原生壳层与插件基础
  └── 阶段二 应用与文件搜索
        └── 阶段三 截图、标注与钉图
              └── 阶段四 超级右键
                    └── 阶段五 系统集成与更新
                          └── 阶段六 发布质量验收
```

阶段按顺序执行。进入下一阶段前必须满足上一阶段的构建、测试、性能和工作树清洁要求。

## 3. 顶层文件结构

```text
MacLunach/
├── Config/                         构建配置与部署目标
├── Packages/TouchKit/              可单测的核心和第一方功能模块
├── TouchApp/                       macOS 主应用和 SwiftUI/AppKit 壳层
├── Services/ScreenshotService/     截图 XPC 服务
├── Services/FileActionService/     文件操作 XPC 服务
├── Extensions/FinderExtension/     Finder Sync Extension
├── TouchUITests/                    启动器和关键流程 UI 测试
├── Scripts/                         部署版本、签名和性能检查
├── Resources/                      本地化、主题和应用资源
├── docs/superpowers/specs/          已确认设计规格
│   └── 2026-07-16-feature-plugin-architecture.md  功能区插件与市场演进边界
├── docs/superpowers/plans/          实施路线图和阶段计划
└── project.yml                      XcodeGen 工程定义
```

## 4. 全局工程规则

- [ ] 所有 target、package、extension 和 XPC 服务统一 `macOS 14.0`。
- [ ] 所有新功能必须先定义协议和失败语义，再接入 UI。
- [ ] 插件不得读取其他插件的配置目录或数据库。
- [ ] 宿主不得按插件 ID 硬编码设置页面或持有插件私有配置类型。
- [ ] 每个插件必须声明 Feature API 版本、配置版本、能力和执行隔离方式。
- [ ] 第三方扩展不得向主应用或 Finder 扩展注入原生代码。
- [ ] 主线程不得执行文件枚举、SQLite 写入、OCR、图片编码或文件移动。
- [ ] 每个行为变更先写失败测试，再写最小实现。
- [ ] 每个任务完成后运行目标测试并提交单一主题 commit。
- [ ] 每个阶段结束运行全量单元、集成、UI 和 Release 构建。
- [ ] 不使用子代理；所有实施、复核和修复在当前任务中完成。

## 5. 设计规格覆盖映射

| 规格章节 | 实施阶段 | 验证出口 |
|---|---|---|
| 1-3 产品、原则、V1 范围 | 全阶段 | 阶段六发布清单逐项核对 |
| 4 插件架构、隔离和系统版本 | 阶段一、三、四、六 | Registry/XPC 故障测试、部署目标脚本 |
| 5 启动器界面 | 阶段一 | UI 测试、三主题截图、P95 呼出性能 |
| 6 应用和文件搜索 | 阶段二 | 100 万记录基准、FSEvents 集成测试 |
| 7 截图与钉图 | 阶段三 | 捕获流程、标注模型、XPC 恢复和权限测试 |
| 8 超级右键 | 阶段四 | Finder 扩展、文件动作、冲突和撤销测试 |
| 9 主题和动效 | 阶段一、六 | 主题持久化、辅助显示和视觉回归 |
| 10 设置中心 | 阶段一、二、三、四、五 | 三级导航和插件设置隔离 UI 测试 |
| 11 数据存储 | 阶段一至五 | 命名空间、迁移、清理和诊断脱敏测试 |
| 12 错误处理 | 各所属阶段 | 结构化失败测试和恢复记录 |
| 13 性能验收 | 阶段一、二、三、四、六 | Release 构建性能报告 |
| 14 可访问性 | 阶段一、六 | VoiceOver、键盘和系统辅助显示测试 |
| 15 测试策略 | 全阶段 | 单元、集成、UI 和回归测试结果 |
| 16 交付顺序 | 本路线图 | 六个阶段门槛 |
| 17 完整性清单 | 阶段六 | 自动化或人工证据映射 |

## 6. 阶段切换检查

每个阶段结束执行：

```bash
swift test --package-path Packages/TouchKit
xcodegen generate
xcodebuild -project Touch.xcodeproj -scheme Touch -configuration Release -destination 'platform=macOS' build
xcodebuild -project Touch.xcodeproj -scheme Touch -destination 'platform=macOS' test
git status --short
```

预期：所有测试和构建成功，`git status --short` 无输出。
