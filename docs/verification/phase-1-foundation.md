# 阶段一：启动器基础验收记录

## 状态

阶段一验收完成：自动化质量门槛和 @电脑实操均已通过。

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
| 设置三级导航与关闭恢复 | `SettingsNavigationTests` | 通过；关闭设置后恢复此前可见的启动器 |
| 启动页、Tab 与查询保留 | `LauncherSmokeTests` | 通过 |
| 卡片右键入口 | `LauncherSmokeTests` | 通过 |
| 呼出性能 | `Scripts/measure-launcher.sh` | P50 15.605ms，P95 20.601ms |
| 降低透明度与 VoiceOver 标签 | `LauncherSmokeTests.testLauncherControlsExposeLabelsWithReducedTransparency` | 通过 |
| 减少动态效果 | `accessibilityReduceMotion` | 拖动排序禁用弹簧动画 |
| 三主题视觉截图 | `LauncherSmokeTests.testCaptureThreeThemeSnapshots` | 通过，见下方图片 |
| 完整 UI 回归 | `xcodebuild -project Touch.xcodeproj -scheme Touch -configuration Debug -destination 'platform=macOS' test` | 6 项通过 |

## 三主题截图

![主题一](assets/touch-theme-1.png)

![主题二](assets/touch-theme-2.png)

![主题三](assets/touch-theme-3.png)

## @电脑实操证据

- 启动页在实机正常显示，三张功能卡均可见，毛玻璃主题视觉正常。
- 通过设置按钮进入设置窗口，再关闭窗口；启动器恢复显示。该流程在实操中发现问题后已修复，并由新增 UI 测试覆盖。
- 搜索框输入 `finder` 后按 Tab，模式从“应用”切换为“文件”，关键词保持不丢失。
- 点击主题按钮后主题正常切换。
- 右击“打开访达”卡片，出现“修改快捷键 / 隐藏功能 / 恢复默认”菜单。
- 点击“打开访达”后，实机 Finder（`com.apple.finder`）处于运行状态。

## 当前阶段边界

- “打开访达”执行真实 Finder 打开动作，已完成实机验证。
- “截取屏幕”和“超级右键”仍明确显示需要设置/后续阶段接入，不宣称功能已完成。
- 阶段一只验收启动器基础、主题、功能区管理、插件隔离、设置导航、快捷键和性能。

## 已知非阻塞限制

- 开发构建未使用 Developer ID 签名；最终分发阶段再完成签名、公证和 DMG。
- 当前只在 macOS 15.3 实机执行；macOS 14 由统一部署目标和构建检查覆盖，后续仍需独立实机回归。
