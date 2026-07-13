# 阶段二：应用与文件搜索验收记录

## 状态

阶段二验收完成：应用与文件搜索、SQLite 文件索引、FSEvents 增量更新、设置恢复路径、双架构 Release、性能门槛和真实 macOS 操作流程均已通过。

`Option + Space` 的实现及单元测试保持通过，阶段一已有实机正向证据；本轮 Computer Use 的合成 `Option + Space` 事件未被 Carbon 全局热键稳定接收，因此不把本轮尝试记作新的正向证据，也不据此扩大阶段结论。

## 验收环境

- 设备：MacBook Air（MacBookAir10,1），Apple M1，16 GB 内存
- 系统：macOS 15.3（24D60）
- Xcode：16.4（16F6）
- Swift：6.1.2
- 统一部署目标：macOS 14.0
- 阶段代码提交：`5bbdf5a`（短文件名查询索引与百万记录性能门槛）

## 自动化与构建证据

| 项目 | 命令或证据 | 结果 |
| --- | --- | --- |
| TouchKit 单元/集成测试 | `swift test --package-path Packages/TouchKit` | 41 项通过，0 失败 |
| 主应用单元/集成测试 | `xcodebuild ... -destination 'platform=macOS' test` | TouchTests 33 项通过，0 失败 |
| UI 回归 | 同一完整 `xcodebuild test` | TouchUITests 16 项通过，0 失败 |
| Release 构建 | `xcodebuild ... -configuration Release -arch arm64 -arch x86_64 build CODE_SIGNING_ALLOWED=NO` | 通过 |
| Release 架构 | `lipo -archs 触达.app/Contents/MacOS/触达` | `x86_64 arm64` |
| 部署目标一致性 | `Scripts/check-deployment-targets.sh` | 所有 Target 为 macOS 14.0 |
| 启动器呼出性能 | `Scripts/measure-launcher.sh` | P50 0.842ms，P95 4.596ms，低于 120ms |
| 百万记录 `design` 查询 | `Scripts/measure-search.sh` | P50 3.077ms，P95 3.210ms，低于 50ms |
| 百万记录 `fd` 查询 | `Scripts/measure-search.sh` | P50 3.010ms，P95 3.175ms，低于 50ms |

搜索基准使用 Release 编译、临时 SQLite、确定性插入 1,000,000 条记录、结果上限 80、每个查询预热 10 次并测量 100 次。短查询使用 schema version 2 的单字符/双字符 FTS token 索引；三字符以上继续使用 trigram FTS；含 `%`、`_` 等特殊字符的字面查询继续使用转义后的 `LIKE` 回退。

## 真实 macOS 操作验收

### 应用与 fixture 文件流程

- 应用模式输入 `finder` 后按 Enter，Finder 成为前台应用。
- 按 Tab 切换到文件模式，查询内容保持不变。
- 搜索 `design` 可见 `Design Notes.md` 和 `Design Brief.txt`。
- Up/Down 可改变当前选择。
- 第一次 Esc 清空查询并恢复三张功能卡；第二次 Esc 隐藏启动器面板。
- 对 `Design Brief.txt` 分别执行 Space、Command+Enter、Enter，fixture 动作日志得到：

```text
preview|/tmp/TouchSearchFixture/Design Brief.txt
reveal|/tmp/TouchSearchFixture/Design Brief.txt
open|/tmp/TouchSearchFixture/Design Brief.txt
```

### 真实目录、文件和系统动作

- 从“设置 → 搜索”通过 NSOpenPanel 添加临时目录 `TouchPhase2Manual`。
- 索引计数从 217,788 增至 217,789，真实文件 `design-live.txt` 可被搜索。
- Arrow navigation 后按 Space，系统 Quick Look 显示文件及正文 `Touch phase 2 live quick look verification`。
- Command+Enter 打开 Finder 并选中 `design-live.txt`。
- Enter 使用 TextEdit 打开 `design-live.txt`，窗口 URL 与文件正文正确。

### FSEvents 增量更新

在同一触达进程、启动器保持运行时完成以下验证：

1. 创建 `touch-event-created.txt`：SQLite 出现记录，刷新查询后 UI 出现该文件。
2. 改名为 `touch-event-renamed.txt`：旧路径记录数为 0，新路径记录数为 1，UI 显示新文件名。
3. 删除 `touch-event-renamed.txt`：SQLite 记录数为 0，刷新查询后 UI 显示无结果。

索引数据库位于 `~/Library/Application Support/Touch/Search/file-index.sqlite`。上述操作证明普通文件创建、改名和删除可由 FSEvents 增量同步，不需要重启应用。

### 重建、添加和移除目录

- 从空结果页执行“重建索引”，设置页恢复为“索引已就绪”，显示 217,790 个文件、143.8 MB。
- 重建后 `design-live.txt` 仍可搜索。
- 从设置移除 `TouchPhase2Manual` 后，文件数降至 217,789；SQLite 中该真实文件记录归零，刷新查询后 UI 无结果。
- 临时目录和测试文件已清理，不保留在用户索引范围内。

## 自动化环境恢复记录

首次提交前复跑中，`TouchUITests-Runner` 曾在启用 Automation Mode 时超时，普通 TouchTests 33/33 已通过但 UI 用例未开始。清理残留 Runner 并重启当前用户的 `testmanagerd` 后恢复；另一次尝试受到 Apple Events 权限弹窗干扰，弹窗被拒绝并清除。最终同一完整命令取得 TouchTests 33/33、TouchUITests 16/16 和 `** TEST SUCCEEDED **`，没有为环境问题修改生产代码。

最新 Xcode 在保存 xcresult 活动日志时报告 `mkstemp: No such file or directory` 警告，但测试命令退出码为 0、所有测试汇总完整且 `TEST SUCCEEDED`。本阶段以完整文本日志为主证据。

## 证据位置

- TouchKit：`/tmp/touch-phase2-final-swift-test.log`
- 双架构 Release：`/tmp/touch-phase2-final-release.log`
- 完整主应用与 UI 测试：`/tmp/touch-phase2-final-tests-success.log`
- 部署目标：`/tmp/touch-phase2-final-deployment.log`
- 启动器性能：`/tmp/touch-phase2-final-launcher.log`
- 搜索性能：`/tmp/touch-phase2-final-search.log`
- 最新测试结果目录：`~/Library/Developer/Xcode/DerivedData/Touch-fkldgjwkipajjhbnzkrgxcizzyej/Logs/Test/Test-Touch-2026.07.13_19-27-09-+0800.xcresult`
- Release 应用：`~/Library/Developer/Xcode/DerivedData/Touch-fkldgjwkipajjhbnzkrgxcizzyej/Build/Products/Release/触达.app`

## 已知非阻塞限制

- 当前 Release 使用 `CODE_SIGNING_ALLOWED=NO`，尚未执行 Developer ID 签名、公证和 DMG 打包；这些属于后续系统集成与发布阶段。
- 当前只在 macOS 15.3、Apple M1 实机执行真实操作；macOS 14 由部署目标一致性和构建覆盖，仍需在发布阶段执行独立 macOS 14 实机回归。
- Computer Use 对 Carbon `Option + Space` 合成事件不稳定；本阶段沿用阶段一真实快捷键验收与 `optionSpaceMapsToCarbonValues()` 单元证据，不伪称本轮新增成功证据。
