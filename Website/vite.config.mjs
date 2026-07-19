import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const repositoryName = process.env.GITHUB_REPOSITORY?.split("/")[1] ?? "";
const repositoryOwner = process.env.GITHUB_REPOSITORY_OWNER ?? "";
const hasGitHubRepository =
  repositoryName.length > 0 && repositoryOwner.length > 0;
const isGitHubPagesProjectSite =
  hasGitHubRepository &&
  repositoryName.toLowerCase() === `${repositoryOwner.toLowerCase()}.github.io`;

const githubPagesBase =
  process.env.GITHUB_PAGES === "true" && hasGitHubRepository
    ? (isGitHubPagesProjectSite ? "/" : `/${repositoryName}/`)
    : "/";

export default defineConfig({
  base: process.env.VITE_BASE_PATH ?? githubPagesBase,
  optimizeDeps: {
    include: ["react", "react-dom/client"],
  },
  server: {
    host: "0.0.0.0",
    allowedHosts: ["terminal.local"],
    warmup: {
      clientFiles: ["./src/main.jsx"],
    },
  },
  plugins: [react()],
});
