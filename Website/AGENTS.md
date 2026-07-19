# Prototype Instructions

Run the local server yourself and open the preview in the browser available to this environment. Do not give the user server-start instructions when you can run it.

Before making substantial visual changes, use the Product Design plugin's `get-context` skill when the visual source is unclear or no longer matches the current goal. When the user gives durable prototype-specific design feedback, preferences, or decisions, record them in `AGENTS.md`.

When implementing from a selected generated mock, treat that image as the source of truth for layout, component anatomy, density, spacing, color, typography, visible content, and hierarchy.

## 一念官网的固定约束

- 产品名称始终使用“一念”，不得出现旧名称“触达”。
- 主宣传语固定为“一念，所想即现”。
- 产品功能截图必须来自真实运行中的 App 或仓库已有的真实验收截图，不得使用生成图冒充产品界面。
- 官网保持纯静态构建，优先兼容 Cloudflare Pages；安装包下载地址通过 `VITE_DOWNLOAD_URL` 注入。
- 当前发布阶段为未签名免费内测版，页面必须明确提示 macOS 首次打开方式。
