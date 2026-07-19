import { useEffect, useState } from "react";
import {
  ArrowRight,
  Command,
  DownloadSimple,
  DotsThree,
  FolderOpen,
  ImageSquare,
  List,
  MagnifyingGlass,
  Palette,
  PushPin,
  ShieldCheck,
  X,
} from "@phosphor-icons/react";
import { siteConfig } from "./config.js";

const assetURL = (fileName) => `${import.meta.env.BASE_URL}assets/${fileName}`;

const features = [
  {
    icon: MagnifyingGlass,
    title: "应用与文件搜索",
    description: "应用、文件与常用动作，在一个入口里快速找到。",
    tone: "blue",
  },
  {
    icon: ImageSquare,
    title: "截图与标注",
    description: "截取屏幕、添加标注、复制或保存，流程更连贯。",
    tone: "violet",
  },
  {
    icon: DotsThree,
    title: "超级右键",
    description: "在 Finder 中新建文件、复制路径并快速打开终端。",
    tone: "indigo",
  },
  {
    icon: PushPin,
    title: "钉图与 OCR",
    description: "将画面留在最前，识别文字与二维码，随用随取。",
    tone: "amber",
  },
  {
    icon: Palette,
    title: "主题与设置",
    description: "日间、黑夜与玻璃主题，让工具适应你的桌面。",
    tone: "periwinkle",
  },
  {
    icon: ShieldCheck,
    title: "本地优先",
    description: "索引、截图历史与偏好保存在本机，不上传文件。",
    tone: "mint",
  },
];

function DownloadLink({
  className = "",
  children,
  compact = false,
  fallbackChildren,
  disabledWhenUnavailable = false,
}) {
  const hasDownload = siteConfig.hasExternalDownload;
  const label = hasDownload ? children : (fallbackChildren ?? children);
  const isAnchor = !hasDownload || siteConfig.downloadURL.startsWith("#");
  const classNames = `${className} ${compact ? "is-compact" : ""}`.trim();

  if (!hasDownload && disabledWhenUnavailable) {
    return (
      <span className={`${classNames} is-disabled`.trim()} aria-disabled="true">
        {label}
      </span>
    );
  }

  return (
    <a
      className={classNames}
      href={hasDownload ? siteConfig.downloadURL : "#install"}
      target={isAnchor ? undefined : "_blank"}
      rel={isAnchor ? undefined : "noreferrer"}
      download={false}
    >
      {label}
    </a>
  );
}

function ProductShot({ src, alt, className = "", onOpen }) {
  return (
    <button
      className={`product-shot ${className}`.trim()}
      type="button"
      onClick={() => onOpen({ src, alt })}
      aria-label={`放大查看：${alt}`}
    >
      <img src={src} alt={alt} loading="lazy" />
      <span className="product-shot__hint">点击放大</span>
    </button>
  );
}

function AppHeader() {
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => {
    const closeMenu = () => setMenuOpen(false);
    window.addEventListener("resize", closeMenu);
    return () => window.removeEventListener("resize", closeMenu);
  }, []);

  return (
    <header className="site-header">
      <div className="site-header__inner">
        <a className="brand" href="#top" aria-label="一念首页">
          <img src={assetURL("brand-logo.svg")} alt="" />
          <span>一念</span>
        </a>

        <button
          className="menu-toggle"
          type="button"
          aria-label={menuOpen ? "关闭导航" : "打开导航"}
          aria-expanded={menuOpen}
          onClick={() => setMenuOpen((current) => !current)}
        >
          {menuOpen ? <X size={22} /> : <List size={22} />}
        </button>

        <nav className={`site-nav ${menuOpen ? "is-open" : ""}`} aria-label="主导航">
          <a href="#features" onClick={() => setMenuOpen(false)}>功能</a>
          <a href="#privacy" onClick={() => setMenuOpen(false)}>隐私</a>
          <a href="#install" onClick={() => setMenuOpen(false)}>安装说明</a>
          <a href="#footer" onClick={() => setMenuOpen(false)}>关于</a>
        </nav>
      </div>
    </header>
  );
}

function Hero({ onOpen }) {
  return (
    <section
      className="hero"
      id="top"
      style={{ "--hero-background": `url("${assetURL("hero-background.png")}")` }}
    >
      <div className="hero__inner page-shell">
        <div className="hero__copy" data-reveal>
          <p className="eyebrow">原生 macOS 桌面启动器</p>
          <h1>一念，<br />所想即现</h1>
          <p className="hero__lede">
            不离开当前工作，就能找到应用与文件、完成截图，
            以及调用常用的 Finder 工具。
          </p>
          <div className="hero__actions">
            <a className="button button--primary" href="#download">
              <DownloadSimple size={19} weight="bold" />
              下载免费内测版
            </a>
            <a className="text-link" href="#install">
              查看安装说明 <ArrowRight size={16} />
            </a>
          </div>
          <p className="download-meta">
            {siteConfig.minimumSystem} · {siteConfig.version} · 开发签名、未公证
          </p>
        </div>

        <div className="hero__visual" data-reveal>
          <ProductShot
            src={assetURL("launcher-search.png")}
            alt="一念日间主题启动器真实界面"
            className="hero-shot"
            onOpen={onOpen}
          />
          <div className="shortcut-chip" aria-label="Option 加空格呼出">
            <Command size={15} />
            <span>⌥ Space</span>
            <small>随时呼出</small>
          </div>
        </div>
      </div>
    </section>
  );
}

function FeatureOverview() {
  return (
    <section className="feature-overview" id="features" aria-labelledby="feature-overview-title">
      <div className="page-shell">
        <div className="section-heading section-heading--compact" data-reveal>
          <p className="eyebrow">一个入口，少一点切换</p>
          <h2 id="feature-overview-title">把常用能力放到手边</h2>
        </div>
        <div className="feature-grid">
          {features.map(({ icon: Icon, title, description, tone }) => (
            <article className="feature-item" key={title} data-reveal>
              <span className={`feature-icon feature-icon--${tone}`}>
                <Icon size={27} weight="regular" />
              </span>
              <div>
                <h3>{title}</h3>
                <p>{description}</p>
              </div>
            </article>
          ))}
        </div>
      </div>
    </section>
  );
}

function SearchSection({ onOpen }) {
  return (
    <section className="story-section" aria-labelledby="search-title">
      <div className="page-shell story-grid">
        <div className="story-copy" data-reveal>
          <span className="chapter">01 · 搜索</span>
          <h2 id="search-title">先搜一下，<br />应用和文件都在手边。</h2>
          <p>
            默认快捷键呼出后，搜索框立即聚焦。应用、文件和常用动作共享一个入口，
            键盘选择，回车打开，不打断手上的事情。
          </p>
          <ul className="quiet-list">
            <li>应用与文件分区搜索</li>
            <li>键盘导航与快捷执行</li>
            <li>索引异常不影响应用搜索</li>
          </ul>
        </div>
        <div className="story-media story-media--cool" data-reveal>
          <ProductShot
            src={assetURL("launcher-search.png")}
            alt="一念应用与文件搜索入口真实界面"
            onOpen={onOpen}
          />
        </div>
      </div>
    </section>
  );
}

function ScreenshotSection({ onOpen }) {
  return (
    <section className="story-section story-section--tinted" aria-labelledby="screenshot-title">
      <div className="page-shell story-grid story-grid--reverse">
        <div className="story-media story-media--slate" data-reveal>
          <ProductShot
            src={assetURL("screenshot-annotation.png")}
            alt="一念截图标注编辑器真实界面"
            onOpen={onOpen}
          />
        </div>
        <div className="story-copy" data-reveal>
          <span className="chapter">02 · 截图</span>
          <h2 id="screenshot-title">截图之后，<br />标注、识别、钉图一步完成。</h2>
          <p>
            从选区到标注，再到复制、保存和钉在桌面，流程保持连贯。
            需要文字时再调用 OCR，不必在多个应用之间来回切换。
          </p>
          <ul className="quiet-list">
            <li>区域、窗口、全屏与多显示器捕获</li>
            <li>常用标注工具与撤销重做</li>
            <li>OCR、二维码识别与钉图</li>
          </ul>
        </div>
      </div>
    </section>
  );
}

function FinderSection({ onOpen }) {
  return (
    <section className="story-section" aria-labelledby="finder-title">
      <div className="page-shell finder-layout">
        <div className="story-copy finder-copy" data-reveal>
          <span className="chapter">03 · Finder</span>
          <h2 id="finder-title">超级右键，<br />让常用操作少绕一步。</h2>
          <p>
            在 Finder 当前文件夹里直接新建文件或文件夹、复制路径，
            也可以使用你常用的终端打开当前位置。
          </p>
          <div className="finder-actions" aria-label="超级右键功能">
            <span>新建文件</span>
            <span>新建文件夹</span>
            <span>复制路径</span>
            <span>终端打开</span>
          </div>
        </div>
        <div className="finder-visual" data-reveal>
          <ProductShot
            src={assetURL("shortcut-layout.png")}
            alt="一念快捷键布局与动作设置真实界面"
            onOpen={onOpen}
          />
        </div>
      </div>
    </section>
  );
}

function ThemeSection({ onOpen }) {
  const [theme, setTheme] = useState("day");
  const isDay = theme === "day";
  const currentImage = assetURL(isDay ? "launcher-search.png" : "launcher-night.jpg");

  return (
    <section className="theme-section" aria-labelledby="theme-title">
      <div className="page-shell theme-layout">
        <div className="theme-copy" data-reveal>
          <span className="chapter">04 · 外观与设置</span>
          <h2 id="theme-title">白天或黑夜，<br />都保持安静。</h2>
          <p>
            一念提供默认玻璃、白天与黑夜三套主题。统一设置中心集中管理快捷键、
            权限、功能和本地数据。
          </p>
          <div className="theme-switch" role="group" aria-label="切换主题预览">
            <button
              type="button"
              className={isDay ? "is-active" : ""}
              aria-pressed={isDay}
              onClick={() => setTheme("day")}
            >
              白天
            </button>
            <button
              type="button"
              className={!isDay ? "is-active" : ""}
              aria-pressed={!isDay}
              onClick={() => setTheme("night")}
            >
              黑夜
            </button>
          </div>
        </div>
        <div className={`theme-preview ${isDay ? "is-day" : "is-night"}`} data-reveal>
          <ProductShot
            src={currentImage}
            alt={`一念${isDay ? "白天" : "黑夜"}主题真实界面`}
            onOpen={onOpen}
          />
        </div>
        <div className="settings-preview" data-reveal>
          <ProductShot
            src={assetURL("settings-general.png")}
            alt="一念设置中心真实界面"
            onOpen={onOpen}
          />
        </div>
      </div>
    </section>
  );
}

function PrivacySection() {
  return (
    <section className="privacy-section" id="privacy" aria-labelledby="privacy-title">
      <div className="page-shell privacy-layout" data-reveal>
        <span className="privacy-icon"><ShieldCheck size={31} weight="regular" /></span>
        <div>
          <p className="eyebrow">本地优先</p>
          <h2 id="privacy-title">你的文件，留在你的 Mac。</h2>
          <p>
            文件索引、截图历史、快捷键和主题配置都保存在本机。
            一念不会为了提供基础功能上传你的文件或截图。
          </p>
        </div>
      </div>
    </section>
  );
}

function InstallSection() {
  const steps = [
    {
      icon: DownloadSimple,
      title: "下载安装包",
      description: "从官网获取最新的一念内测版。",
    },
    {
      icon: FolderOpen,
      title: "拖入应用程序",
      description: "打开 DMG，将一念拖入“应用程序”。",
    },
    {
      icon: ShieldCheck,
      title: "首次允许打开",
      description: "前往“隐私与安全性”，点击“仍要打开”。",
    },
  ];

  return (
    <section className="install-section" id="install" aria-labelledby="install-title">
      <div className="page-shell">
        <div className="section-heading" data-reveal>
          <p className="eyebrow">开始使用</p>
          <h2 id="install-title">3 步安装一念</h2>
          <p>当前是开发签名、未公证的免费内测版，首次启动需要手动允许一次。</p>
        </div>

        <div className="install-grid">
          {steps.map(({ icon: Icon, title, description }, index) => (
            <article className="install-step" key={title} data-reveal>
              <div className="install-step__top">
                <span>{String(index + 1).padStart(2, "0")}</span>
                <Icon size={25} />
              </div>
              <h3>{title}</h3>
              <p>{description}</p>
            </article>
          ))}
        </div>

        <div className="install-notice" id="download" data-reveal>
          <div>
            <strong>为什么会出现安全提示？</strong>
            <p>
              当前内测版尚未购买 Apple Developer Program，因此没有 Developer ID 公证。
              请只从一念官网或官方 GitHub Releases 下载。
            </p>
          </div>
          <DownloadLink
            className="button button--primary"
            disabledWhenUnavailable
            fallbackChildren="下载包待发布"
          >
            <DownloadSimple size={19} weight="bold" />
            下载内测版
          </DownloadLink>
        </div>
      </div>
    </section>
  );
}

function Lightbox({ image, onClose }) {
  useEffect(() => {
    if (!image) return undefined;
    const onKeyDown = (event) => {
      if (event.key === "Escape") onClose();
    };
    document.body.classList.add("lightbox-open");
    window.addEventListener("keydown", onKeyDown);
    return () => {
      document.body.classList.remove("lightbox-open");
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [image, onClose]);

  if (!image) return null;

  return (
    <div className="lightbox" role="dialog" aria-modal="true" aria-label={image.alt} onMouseDown={onClose}>
      <button type="button" className="lightbox__close" onClick={onClose} aria-label="关闭大图">
        <X size={22} />
      </button>
      <img src={image.src} alt={image.alt} onMouseDown={(event) => event.stopPropagation()} />
    </div>
  );
}

export function App() {
  const [lightboxImage, setLightboxImage] = useState(null);

  useEffect(() => {
    const elements = Array.from(document.querySelectorAll("[data-reveal]"));
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      elements.forEach((element) => element.classList.add("is-visible"));
      return undefined;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12 },
    );
    elements.forEach((element) => observer.observe(element));
    return () => observer.disconnect();
  }, []);

  return (
    <>
      <AppHeader />
      <main>
        <Hero onOpen={setLightboxImage} />
        <FeatureOverview />
        <div className="product-intro page-shell" data-reveal>
          <span>产品功能介绍</span>
        </div>
        <SearchSection onOpen={setLightboxImage} />
        <ScreenshotSection onOpen={setLightboxImage} />
        <FinderSection onOpen={setLightboxImage} />
        <ThemeSection onOpen={setLightboxImage} />
        <PrivacySection />
        <InstallSection />
      </main>
      <footer className="site-footer" id="footer">
        <div className="page-shell site-footer__inner">
          <a className="brand brand--footer" href="#top">
            <img src={assetURL("brand-logo.svg")} alt="" />
            <span>一念</span>
          </a>
          <p>一念，所想即现。</p>
          <div className="site-footer__links">
            <a href="#privacy">隐私</a>
            <a href="#install">安装说明</a>
            <span>© 2026 一念</span>
          </div>
        </div>
      </footer>
      <Lightbox image={lightboxImage} onClose={() => setLightboxImage(null)} />
    </>
  );
}
