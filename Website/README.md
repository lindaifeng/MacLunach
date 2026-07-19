# 一念官网

纯静态 React + Vite 官网，适合部署到 Cloudflare Pages。

## 本地开发

```bash
npm install
npm run dev
```

## 构建

```bash
npm run build
```

构建输出目录为 `dist`。

## 下载地址

复制 `.env.example` 为 `.env.local`，填写安装包地址：

```bash
VITE_DOWNLOAD_URL=https://github.com/your-account/touch-releases/releases/latest
VITE_APP_VERSION=0.1.0
```

未设置 `VITE_DOWNLOAD_URL` 时，下载按钮会跳转到页面内的安装说明，不会指向无效地址。

## Cloudflare Pages

- 构建命令：`npm run build`
- 输出目录：`dist`
- Node.js 版本：20 或更新版本
- 环境变量：`VITE_DOWNLOAD_URL`、`VITE_APP_VERSION`

安装包不要直接放进 Pages。Pages 单文件限制为 25 MiB，建议使用 GitHub Releases，或将 DMG 放进 Cloudflare R2 并绑定自有下载子域名。
