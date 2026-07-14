# 阶段三截图验证记录

## 当前边界（2026-07-14）

阶段三仍在实施，不能标记完成。当前已打通：版本化模型、XPC 服务、ScreenCaptureKit 捕获与原子文件、QQ 式直接拖拽选区、窗口吸附、拖满屏自动推断全屏、选区后工具栏、3/5/10 秒非阻塞可见倒计时与 Esc/插件停用取消链路、`Command+Shift+2` 所有显示器真实捕获及可配置快捷键、真实产物写入系统剪贴板，以及十三类 QQ 可见标注/效果（矩形、圆形、直线、箭头、绘画、荧光笔、文本、数字点、备注、贴纸、马赛克、水印、美化）的预览、撤销/重做、请求传输和最终像素渲染。屏幕取色已接入默认 `Control+Option+C` 快捷键和同一屏幕录制权限链路，提供跨显示器透明取色层、十字光标、QQ 风格像素放大镜、HEX/RGB/HSL、Retina 物理像素定位、边缘避让、Display P3 到标准 sRGB 转换、节流和旧请求取消，单击会以当前点重新采样并复制 HEX，Esc 或停用插件可取消；该链路只返回内存数据，不创建截图文件或历史记录。OCR/二维码链路现也已接通：选区以 `.ocrRegion` 捕获后由 XPC 内 Vision accurate 模式识别，最多并发 2 个任务，支持取消、方向元数据、置信度过滤、历史 OCR 摘要、默认复制文字和可重试结果面板；二维码链接会在主应用重新校验且必须经用户确认后才打开。服务端非破坏性模型与渲染器另已纳入模糊、放大镜、裁剪，共覆盖十六类图层；模糊使用复用的 `CIContext` 与局部 mask，放大镜使用圆形 mask 和倍率限制，裁剪保持左上角 point 坐标、只采用最后一个有效裁剪，并在美化扩边之前执行。文本使用选区内联编辑，数字点自动递增，备注支持换行并以 `Command+Return` 完成；贴纸提供 6 个系统 emoji 预设并在选区内点击放置；马赛克使用自由路径画笔，预览显示棋盘块，最终产物对画笔覆盖区域执行真实像素化且不改变路径外像素；水印提供 4 个文字预设，在完整选区内以透明、倾斜、交错布局重复绘制；美化提供 4 个完整预设，导出时真实扩展四边边距并绘制多色渐变、圆角和阴影。视频中的“钉至桌面”已接入基础真实链路：选择后捕获产物直接创建无边框置顶、等比缩放、可拖动、跨 Space 的独立钉图窗口，右键可复制或关闭。

捕获后工作流也已接通：服务端生成最大 `360×240` 的独立 PNG 缩略图，主应用可按配置执行“复制并显示缩略图”“仅保存”“复制并保存”或“标注”，浮动缩略图支持右下角堆叠、0/3/5/10 秒与永不隐藏、键盘复制/删除/关闭、右键动作、单击标注、双击钉图以及 Finder 文件 promise 拖放。复制会同时提供 PNG、TIFF 和文件 URL；导出、删除与回收仍通过 XPC 服务执行。

尚未完成：滚动截图拼接、GIF 帧录制与编码、翻译；OCR 结果面板尚待真实鼠标/键盘、VoiceOver 和用户实际截图视觉验收；模糊、放大镜、裁剪尚待完整编辑器 UI；捕获后 `.annotate` 当前仍由系统默认图片编辑器打开，不得宣称内建编辑器完成；无历史截图进入 `.Trash` 后尚无独立 TTL 清理；钉图尚待透明度、折叠/展开、穿透恢复、重启持久化；另需 6K 连续导出内存门槛以及完整实机/多屏/可访问性验收。滚动截图与 GIF 已进入真实、可取消的协调器扩展路由，但默认路由仍明确返回未完成状态，不得伪装成功。

## QQ 参考视频

参考文件：`/Users/ldf/Desktop/HapiGo_2026-07-14_01.33.44.mp4`（仅作本机设计证据，不提交仓库）。

确认的工具顺序：矩形、圆形、直线、箭头、绘画、荧光笔、文本、数字点、备注、贴纸、马赛克、水印、美化、滚动截图、GIF 录制、文字识别、翻译、钉至桌面、取消、拷贝。

确认的快捷键仅包括：`R/O/L/T/1/N/P/Esc`。未在视频中确认的箭头、绘画、荧光笔快捷键不擅自添加。

## 自动化证据

- QQ 工具栏与几何最小集合：13 个测试通过。
- 剪贴板与协调器闭环：13 个测试通过，日志 `/tmp/touch-qq-copy-unit-rerun.log`。
- 标注领域模型与 Core Graphics/Core Text 最终渲染：13 类标注/效果均纳入同一非破坏性模型；`swift test --package-path Packages/TouchKit --filter 'Annotation'` 最新 11 个测试通过，包含贴纸/水印/美化序列化与最终像素绘制、马赛克块大小序列化、局部像素化、路径外像素不变、Retina 左上角坐标，以及美化后确定的扩展尺寸。
- 贴纸目录提供 6 个互不重复、系统可渲染的 emoji 预设；水印目录提供“触达、机密、仅供内部使用、草稿”4 个互不重复的文字预设。
- 马赛克应用层最小回归：`SelectionAnnotationTests` 6 个测试通过，结果 `/tmp/touch-qq-mosaic-app/Logs/Test/Test-Touch-2026.07.14_11-11-33-+0800.xcresult`；证明工具入口已映射到 `.mosaic` 且坐标/块大小进入捕获请求。
- 贴纸/水印应用层最小回归：`SelectionAnnotationTests` 与 `SelectionToolbarTests` 共 17 个测试通过，结果 `/tmp/touch-qq-watermark-app/Logs/Test/Test-Touch-2026.07.14_11-27-19-+0800.xcresult`；证明贴纸点击放置、水印全选区边界、预设参数和捕获相对坐标进入同一请求链路。
- 美化最小回归：Swift `beautify` 定向模型、渲染与捕获引擎集成共 3 个测试通过；App 层 `SelectionAnnotationTests` 与 `SelectionToolbarTests` 共 19 个测试通过，结果 `/tmp/touch-qq-beautify-app/Logs/Test/Test-Touch-2026.07.14_11-45-45-+0800.xcresult`。证明 4 个完整预设、全选区效果图层、捕获相对坐标、圆角/阴影/多色渐变和扩展后的 point/pixel 产物尺寸均进入真实链路。
- 高级效果最小回归：`AnnotationEffectsTests` 6 个测试通过，覆盖局部高斯模糊、圆形放大镜、裁剪坐标与尺寸、越界/无效参数、透明图、多个裁剪取最后一个及“先裁剪后美化”；`ScreenCaptureEngineTests.cropUpdatesStoredArtifactDimensions` 验证 2x Retina 产物同时写入 60×50 point 与 120×100 pixel 元数据。
- 钉图协调器与工具栏最小回归：`ScreenshotCoordinatorTests` 与 `SelectionToolbarTests` 共 22 个测试通过，结果 `/tmp/touch-qq-pin-app/Logs/Test/Test-Touch-2026.07.14_12-11-45-+0800.xcresult`；证明 `.pin` 完成动作不覆盖剪贴板并把真实产物交给置顶窗口管理器。
- 延时截图最小回归：`CaptureCountdownTests` 与 `ScreenshotCoordinatorTests` 共 16 个测试通过，结果 `/tmp/touch-qq-countdown-fresh/Logs/Test/Test-Touch-2026.07.14_12-41-01-+0800.xcresult`；证明无延时不创建 HUD，3/5/10 秒生成递减秒数，设置中的延时与输出格式进入协调器，倒计时完成后 XPC 立即捕获，停用插件可取消倒计时且不会产生截图。
- 多屏快捷键与扩展入口：所有显示器默认快捷键为 `Command+Shift+2`，配置模型定向 4 个测试通过；应用层关键组合回归 47 个测试通过，结果 `/tmp/touch-phase3-task6-final-derived/Logs/Test/Test-Touch-2026.07.14_13-17-13-+0800.xcresult`。覆盖所有显示器 ID 进入 `.allDisplays` 请求并复制产物、滚动截图/GIF 工具栏动作进入扩展路由且不产生静态截图、倒计时、选区几何、十三类标注和剪贴板闭环。首次构建暴露 Swift 6 `Sendable` 编译错误，根因是扩展路由跨 `Task` 捕获但协议未声明 `Sendable`；修复业务类型约束后通过，属于产品代码缺陷而非 XCUI 基础设施问题。
- 屏幕取色定向证据：恢复验证后，`ScreenshotColorModelsTests` 2 个测试通过，`ScreenCaptureEngineTests` 17 个测试通过；`ColorPickerControllerTests` 与 `ScreenshotCoordinatorTests` 共 25 个测试、0 失败，结果 `/tmp/touch-phase3-task7-color-resume-derived/Logs/Test/Test-Touch-2026.07.14_19-07-49-+0800.xcresult`。覆盖颜色格式、Display P3 到标准 sRGB、Retina/边缘采样、排除触达窗口、XPC 请求响应、协调器单击复制与 Esc/停用取消。最新 Debug 应用与 `/tmp/touch-color-fixture.png` 已真实启动；Computer Use 能操作预览色块，但合成 `Control+Option+C` 未触发 Carbon 快捷键，点击后剪贴板仍为预设哨兵，故没有把自动化基础设施失败记录成产品失败。真实键盘、跨屏及四边四角 loupe 视觉验收仍待人工完成；无不同色彩空间显示器时不得宣称该硬件矩阵通过。
- 历史与文件生命周期：`ScreenshotHistoryStoreTests` 和 `ScreenshotRetentionControllerTests` 共 10 个测试通过，覆盖 schema v1→v2、损坏库隔离、元数据与 OCR 组合搜索、30 天/最大条数联合策略、pin 保护、回收/恢复/过期清除、批量失败回滚、历史关闭策略及符号链接越界防护。历史配置 Codable 向后兼容 2 个模型测试通过；TouchKit 关键节点全量回归 121 个测试通过。`ScreenshotService` 独立构建成功，区域和所有显示器协调器配置传递 2 个测试通过，结果 `/tmp/touch-phase3-task8-derived/Logs/Test/Test-Touch-2026.07.14_19-35-45-+0800.xcresult`。服务启动限量清理过期回收区，捕获后限量入库/清理；历史故障与截图成功响应隔离。历史关闭且要求删除时，为避免 XPC 返回前产物失效，服务暂不提前删除，待客户端完成确认或临时文件 TTL 链路后接入。
- OCR 与二维码：`ScreenshotRecognitionEngineTests` 10 个测试通过，覆盖真实中英文/数字、EXIF 旋转、空图、双二维码、非法 URL、低置信度过滤、关闭二维码、运行中取消、最大并发 2 和排队取消不泄漏许可；真实 Vision fixture 单次约 0.5–0.8 秒，断言内容无误差。XPC 客户端、服务 Endpoint、历史 OCR 更新及协调器 `.ocrRegion` 流程已接通；识别成功默认复制并展示结果，失败保留原图并提供重试。应用层 `ScreenshotCoordinatorTests` 与 `SelectionToolbarTests` 共 36 个测试通过，结果 `/tmp/touch-phase3-task9-derived/Logs/Test/Test-Touch-2026.07.14_20-07-08-+0800.xcresult`。
- 浮动缩略图与捕获后动作：TouchKit 的 `ScreenshotClientTests`、`ScreenshotArtifactFileControllerTests`、`ScreenshotRetentionControllerTests` 共 27 个测试通过；应用层 `FloatingThumbnailStateTests`、`ScreenshotCoordinatorTests`、`ScreenshotPasteboardWriterTests` 最新共 41 个测试、0 失败，覆盖不同高度累计堆叠和极端宽高比尺寸边界。此前 39 个测试的完整结果为 `/tmp/touch-phase3-task10-derived/Logs/Test/Test-Touch-2026.07.14_20-57-09-+0800.xcresult`；最新 41 个测试虽由 `xcodebuild` 报告 `TEST SUCCEEDED`，但 Xcode 在保存新 xcresult 时另有 `mkstemp`/CAS 文件系统警告。Release fixture 真实创建缩略图并完成复制，连续 30 次 `ScreenshotArtifactToThumbnailFrame` 的 P50 为 13.091 ms、P95 为 15.287 ms，低于 300 ms 门槛；脚本为 `Scripts/measure-screenshot.sh`，现已对单样本设置超时并在首个无测量结果时停止。该结果只证明 fixture 链路，不代替真实 ScreenCaptureKit 性能验收。
- TouchKit 关键全量回归：当前 133 个测试通过；部署目标检查为 macOS 14.0 一致。
- 捕获引擎产物集成：`ScreenCaptureEngineTests.annotationsAreRenderedIntoStoredArtifact` 通过，重新读取原子写入文件并验证标注像素，证明不是仅有 overlay 预览。
- 标注坐标、文本载荷、undo/redo 与协调器请求传递：最新最小 Xcode 测试通过；结果位于 `/tmp/touch-qq-text-tools/Logs/Test/`，日志 `/tmp/touch-qq-text-tools-final.log`。
- 关键组合回归：SelectionToolbar、SelectionGeometry、SelectionAnnotation、ScreenshotClipboardWriter、ScreenshotCoordinator 共 32 个测试通过，结果位于 `/tmp/touch-qq-final-nine-tools/Logs/Test/`，日志 `/tmp/touch-qq-final-nine-tools.log`。

所有 `/tmp` 证据不提交仓库。关键节点再运行 SelectionToolbar、SelectionGeometry、ScreenshotClipboardWriter、ScreenshotCoordinator、SelectionAnnotation 的组合回归；不在每个小改动后运行全量 UI 测试。

## 基础设施限制与产品缺陷区分

- XCUITest Runner 在产品 UI 执行前超时：`Timed out while enabling automation mode.`。这是自动化初始化失败，不能据此判定选区或工具栏产品代码失败。
- Computer Use 能识别普通 Finder 窗口，但读取触达全屏透明截图 `NSPanel` 时持续 `timeoutReached`；降低 level、激活 panel 等 fixture 试验均未改变结果，试验改动已撤销。
- Computer Use 合成 Carbon 全局快捷键对 `Option` 组合不稳定，因此其未触发 `Control+Option+C` 不能作为产品快捷键缺陷证据；真实键盘验收保留给用户。
- Task 10 的 XCUITest Runner 在进入 `ScreenshotThumbnailTests` 测试方法前被 LocalAuthentication 阻止，报错 `Failed to initialize for UI testing`、`System authentication is running.` 和“认证已取消”；结果 `/tmp/touch-phase3-task10-derived/Logs/Test/Test-Touch-2026.07.14_20-57-30-+0800.xcresult`。这是 XCUI 基础设施失败，不是缩略图产品代码失败，当前不再重试。
- Release 真实捕获性能只试跑 1 次即返回 `ScreenshotCoordinatorError.noDisplaysAvailable`，没有生成可用样本；当前签名/屏幕录制授权环境已达到排查上限，不能宣称真实 ScreenCaptureKit 30 次 P95 达标。
- 上述问题均已达到本轮排查上限，不再无限重复全量构建。真实 Finder 文件 promise 拖放、TextEdit/预览接收、右键动作、多屏定位、真实鼠标拖动、工具栏视觉、VoiceOver 和真实 ScreenCaptureKit 30 次性能仍需独立实机记录。

## 测试策略

1. 每个改动先跑最小相关测试。
2. 模型/渲染层使用 Swift Package 测试，避免无关 App/UI 构建。
3. 应用协调与交互状态只跑指定 `TouchTests`。
4. 关键集成节点运行组合单元回归和部署目标检查。
5. 只有产品代码证据指向 UI 问题时才重跑 XCUI；纯基础设施问题限时处理并记录。
