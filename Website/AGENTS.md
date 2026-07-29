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

## 2026-07-29 官网重设计方向

- 官网使用项目内 `BrandLogo` 作为唯一品牌图标，并使用用户提供的真实“一念”功能截图展示产品能力。
- 视觉基调为深石墨灰与清晰蓝色点缀，强调原生 macOS 工具感；避免模板化浅色 SaaS 页面、紫色点缀和无意义的装饰卡片。
- 首屏要在不滚动的范围内说明产品定位、核心能力与下载入口；截图按“启动、搜索、工作流、系统集成”组织，内容以可验证的真实功能为准。
- 页面必须同时照顾桌面和移动端阅读：图片不得被裁切到难以辨认，按钮、正文和安装提示要有足够对比度与可读性。
- 功能素材应只保留与该能力直接相关的画面；去除测试标注、无关窗口背景与截图边缘残留，官网内和放大预览中的图片四角都必须保持圆角。
