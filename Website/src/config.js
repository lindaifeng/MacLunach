const configuredDownloadURL = import.meta.env.VITE_DOWNLOAD_URL?.trim();

export const siteConfig = {
  downloadURL: configuredDownloadURL || "#install",
  hasExternalDownload: Boolean(configuredDownloadURL),
  version: import.meta.env.VITE_APP_VERSION?.trim() || "内测版",
  minimumSystem: "macOS 14.0+",
};
