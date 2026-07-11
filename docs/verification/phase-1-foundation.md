# 阶段一：启动器基础验收记录

## 状态

待解除 macOS 系统认证会话阻塞后，重跑新增的可访问性 UI 测试并补齐三主题截图。其余质量门槛已通过。

## 验收环境

- 设备：MacBook Air（MacBookAir10,1），Apple M1，16 GB 内存
- 系统：macOS 15.3（24D60）
- Xcode：16.4（16F6）
- Swift：6.1.2
- 统一部署目标：macOS 14.0
- 阶段基线提交：`ea4a87f`

## 已通过项目

| 项目 | 命令或证据 | 结果 |
| --- | --- | --- |
| 部署目标一致性 | `Scripts/check-deployment-targets.sh` | macOS 14.0 一致 |
| 核心单元测试 | `swift test --package-path Packages/TouchKit` | 12 项通过 |
| Debug 构建 | `xcodebuild ... build` | 通过 |
| Release 构建 | `xcodebuild ... -configuration Release ... build` | 通过，arm64 + x86_64 |
| 设置三级导航 | `SettingsNavigationTests` | 通过 |
| 启动页、Tab 与查询保留 | `LauncherSmokeTests` | 通过 |
| 卡片右键入口 | `LauncherSmokeTests` | 通过 |
| 呼出性能 | `Scripts/measure-launcher.sh` | P50 1.528ms，P95 2.267ms |
| 降低透明度 | `--reduce-transparency` 路径及静态检查 | 已实现，UI 测试待系统认证解除后复跑 |
| 减少动态效果 | `accessibilityReduceMotion` | 拖动排序禁用弹簧动画 |

## 待完成证据

- 新增的“所有启动页控件均有 VoiceOver 标签”UI 测试尚未执行。macOS UI Test Runner 连续三次在测试启动前返回：`System authentication is running`。
- 三主题截图由 UI 测试使用 `XCTAttachment` 采集；同样等待系统认证会话结束。
- @电脑运行时的本机控制通道两次返回 `Sky Computer Use native pipe startup failed`，最终人工复验仍需重试。

## 当前阶段边界

- “打开访达”执行真实 Finder 打开动作。
- “截取屏幕”和“超级右键”仍明确显示需要设置/后续阶段接入，不宣称功能已完成。
- 阶段一只验收启动器基础、主题、功能区管理、插件隔离、设置导航、快捷键和性能。

## 已知非阻塞限制

- 开发构建未使用 Developer ID 签名；最终分发阶段再完成签名、公证和 DMG。
- 当前只在 macOS 15.3 实机执行；macOS 14 由统一部署目标和构建检查覆盖，后续仍需独立实机回归。
