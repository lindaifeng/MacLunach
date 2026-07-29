import { useEffect, useState } from "react";
import {
  ArrowRight,
  ArrowUpRight,
  CheckCircle,
  Command,
  DownloadSimple,
  FolderSimple,
  ImageSquare,
  Keyboard,
  List,
  MagnifyingGlass,
  ShieldCheck,
  Timer,
  Translate,
  X,
} from "@phosphor-icons/react";
import { siteConfig } from "./config.js";

const assetURL = (fileName) => `${import.meta.env.BASE_URL}assets/${fileName}`;
const productURL = (fileName) => assetURL(`product/${fileName}`);

const capabilities = [
  [MagnifyingGlass, "搜索", "应用、文件、动作，一次找到"],
  [ImageSquare, "截图", "截取、标注、识别与钉图"],
  [Timer, "专注", "番茄钟与任务保持同步"],
  [Translate, "文本", "翻译、OCR、Markdown 与解析"],
];

function DownloadLink({ className = "", children, onClick }) {
  const isExternal = siteConfig.hasExternalDownload && !siteConfig.downloadURL.startsWith("#");
  return (
    <a
      className={className}
      href={isExternal ? siteConfig.downloadURL : "#install"}
      target={isExternal ? "_blank" : undefined}
      rel={isExternal ? "noreferrer" : undefined}
      onClick={onClick}
    >
      {children}
    </a>
  );
}

function ProductImage({ src, alt, className = "", onOpen, eager = false }) {
  return (
    <button
      className={`product-image ${className}`.trim()}
      type="button"
      onClick={() => onOpen({ src, alt })}
      aria-label={`放大查看：${alt}`}
    >
      <img src={src} alt={alt} loading={eager ? "eager" : "lazy"} />
      <span className="product-image__zoom">查看真实界面 <ArrowUpRight size={14} /></span>
    </button>
  );
}

function Header() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const close = () => setOpen(false);
    window.addEventListener("resize", close);
    return () => window.removeEventListener("resize", close);
  }, []);

  return (
    <header className="header">
      <div className="shell header__inner">
        <a className="brand" href="#top" aria-label="一念首页">
          <img src={assetURL("brand-logo.png")} alt="" />
          <span>一念</span>
        </a>
        <button className="menu-button" type="button" aria-label={open ? "关闭导航" : "打开导航"} aria-expanded={open} onClick={() => setOpen((value) => !value)}>
          {open ? <X size={22} /> : <List size={22} />}
        </button>
        <nav className={`nav ${open ? "nav--open" : ""}`} aria-label="主导航">
          <a href="#experience" onClick={() => setOpen(false)}>体验</a>
          <a href="#workflows" onClick={() => setOpen(false)}>工作流</a>
          <a href="#privacy" onClick={() => setOpen(false)}>隐私</a>
          <a href="#install" onClick={() => setOpen(false)}>安装</a>
          <DownloadLink className="nav__download" onClick={() => setOpen(false)}>
            下载内测版 <ArrowUpRight size={15} />
          </DownloadLink>
        </nav>
      </div>
    </header>
  );
}

function Hero({ onOpen }) {
  return (
    <section className="hero" id="top">
      <div className="hero__glow hero__glow--one" />
      <div className="hero__glow hero__glow--two" />
      <div className="shell hero__grid">
        <div className="hero__copy" data-reveal>
          <div className="hero__eyebrow"><span /> 原生 macOS 桌面启动器</div>
          <h1>一念，<br /><em>所想即现</em></h1>
          <p className="hero__lede">从一个快捷入口开始，让搜索、截图、任务和 Finder 常用操作，始终贴近你的当前工作。</p>
          <div className="hero__actions">
            <DownloadLink className="button button--primary">
              <DownloadSimple size={19} weight="bold" /> 下载免费内测版
            </DownloadLink>
            <a className="button button--quiet" href="#experience">查看产品体验 <ArrowRight size={18} /></a>
          </div>
          <div className="hero__meta">
            <span><Command size={15} weight="bold" /> ⌥ Space 随时呼出</span>
            <span>{siteConfig.minimumSystem}</span>
          </div>
        </div>
        <div className="hero__showcase" data-reveal>
          <div className="hero__frame">
            <ProductImage
              src={productURL("launcher-actions.png")}
              alt="一念启动器的动作面板真实界面"
              className="hero__image"
              onOpen={onOpen}
              eager
            />
          </div>
          <div className="floating-command floating-command--key">
            <Keyboard size={18} />
            <div><strong>键位布局</strong><span>把常用动作放在指尖</span></div>
          </div>
          <div className="floating-command floating-command--search">
            <MagnifyingGlass size={18} />
            <div><strong>一处搜索</strong><span>应用、文件、动作</span></div>
          </div>
        </div>
      </div>
      <div className="shell hero__capabilities" aria-label="核心能力">
        {capabilities.map(([Icon, title, text]) => (
          <div className="capability" key={title} data-reveal>
            <Icon size={19} weight="duotone" />
            <div><strong>{title}</strong><span>{text}</span></div>
          </div>
        ))}
      </div>
    </section>
  );
}

function Experience({ onOpen }) {
  return (
    <section className="experience" id="experience">
      <div className="shell">
        <div className="section-intro" data-reveal>
          <span className="section-kicker">PRODUCT EXPERIENCE</span>
          <h2>一个入口，<br />让桌面重新流动起来。</h2>
          <p>不是把功能堆成菜单，而是在需要的时候，把正确的能力带到眼前。</p>
        </div>
        <div className="experience__stage" data-reveal>
          <div className="stage-copy">
            <span className="stage-index">01 / 启动器</span>
            <h3>动作、应用与文件<br />在同一个起点。</h3>
            <p>输入即搜索，Tab 切换范围；保留的功能面板、正在进行的专注，都有清晰状态。</p>
            <div className="stage-points"><span>即时聚焦</span><span>键盘优先</span><span>状态可见</span></div>
          </div>
          <ProductImage src={productURL("launcher-keyboard.png")} alt="一念启动器键盘布局真实界面" onOpen={onOpen} />
        </div>
        <div className="search-pair">
          <article className="search-card search-card--app" data-reveal>
            <div className="search-card__head"><span>02 / 应用搜索</span><MagnifyingGlass size={20} /></div>
            <h3>找应用，<br />不必离开手头工作。</h3>
            <ProductImage src={productURL("application-search.png")} alt="一念应用搜索真实界面" onOpen={onOpen} />
          </article>
          <article className="search-card search-card--file" data-reveal>
            <div className="search-card__head"><span>03 / 文件搜索</span><FolderSimple size={20} /></div>
            <h3>文件也在，<br />不止最近打开的几个。</h3>
            <ProductImage src={productURL("file-search.png")} alt="一念文件搜索真实界面" onOpen={onOpen} />
          </article>
        </div>
      </div>
    </section>
  );
}

function Workflow({ index, eyebrow, title, description, image, alt, align = "left", children, onOpen }) {
  return (
    <article className={`workflow workflow--${align}`} data-reveal>
      <div className="workflow__copy">
        <span className="workflow__index">{index}</span>
        <p className="workflow__eyebrow">{eyebrow}</p>
        <h3>{title}</h3>
        <p className="workflow__description">{description}</p>
        {children}
      </div>
      <div className="workflow__media">
        <ProductImage src={image} alt={alt} onOpen={onOpen} />
      </div>
    </article>
  );
}

function Workflows({ onOpen }) {
  return (
    <section className="workflows" id="workflows">
      <div className="shell">
        <div className="workflows__heading" data-reveal>
          <span className="section-kicker">BUILT FOR THE FLOW</span>
          <h2>把零散的小事，<br />收进顺手的工作流。</h2>
        </div>
        <Workflow
          index="01"
          eyebrow="任务与专注"
          title={<>今天要做什么，<br />现在就开始什么。</>}
          description="每日任务与番茄钟联动：选定任务，进入专注；倒计时结束时，提醒会回到你眼前。"
          image={productURL("daily-tasks.png")}
          alt="一念每日任务真实界面"
          onOpen={onOpen}
        >
          <div className="workflow__tags"><span>任务看板</span><span>番茄计时</span><span>到时提醒</span></div>
        </Workflow>
        <Workflow
          index="02"
          eyebrow="深度专注"
          title={<>留一段完整时间，<br />给真正重要的事。</>}
          description="简洁而有节奏的专注界面，保留进度、时长和休息方式。完成时停在 00:00:00，等你确认下一步。"
          image={productURL("focus-timer.png")}
          alt="一念深度专注番茄钟真实界面"
          align="right"
          onOpen={onOpen}
        >
          <div className="focus-note"><Timer size={18} weight="duotone" /><span>实时倒计时 · 到时主动提醒</span></div>
        </Workflow>
        <div className="utility-grid">
          <article className="utility utility--finder" data-reveal>
            <div className="utility__copy"><span>03 / FINDER</span><h3>右键少绕一步。</h3><p>新建文件、文件夹、复制路径，或在你的终端中打开当前位置。</p></div>
            <ProductImage src={productURL("finder-menu-clean.png")} alt="一念超级右键 Finder 菜单真实界面" onOpen={onOpen} />
          </article>
          <article className="utility utility--translation" data-reveal>
            <div className="utility__copy"><span>04 / TRANSLATE</span><h3>看见文字，马上理解。</h3><p>截图后可直接识别与翻译；需要语言包时提供明确的下载入口。</p></div>
            <ProductImage src={productURL("translation.png")} alt="一念截图翻译真实界面" onOpen={onOpen} />
          </article>
        </div>
        <div className="markdown-strip" data-reveal>
          <div><span>05 / WRITE</span><h3>写下去，也看见最终的样子。</h3><p>Markdown 的编辑、阅读与分栏预览，留给需要清晰思考的时候。</p></div>
          <ProductImage src={productURL("markdown.png")} alt="一念 Markdown 编辑与预览真实界面" onOpen={onOpen} />
        </div>
      </div>
    </section>
  );
}

function Privacy() {
  return (
    <section className="privacy" id="privacy">
      <div className="shell privacy__inner" data-reveal>
        <div className="privacy__mark"><ShieldCheck size={34} weight="duotone" /></div>
        <div><span className="section-kicker">LOCAL FIRST</span><h2>你的工作，留在你的 Mac。</h2></div>
        <p>文件索引、截图历史、快捷键与偏好都保存在本机。基础功能不依赖上传你的文件或屏幕内容。</p>
        <ul><li><CheckCircle size={16} weight="fill" /> 本地索引</li><li><CheckCircle size={16} weight="fill" /> 本地截图历史</li><li><CheckCircle size={16} weight="fill" /> 可恢复的权限状态</li></ul>
      </div>
    </section>
  );
}

function Install() {
  return (
    <section className="install" id="install">
      <div className="shell install__panel" data-reveal>
        <div className="install__copy"><span className="section-kicker">GET STARTED</span><h2>让一念，<br />从下一次呼出开始。</h2><p>当前为免费开发测试版。下载后将一念拖入“应用程序”，首次打开请在 macOS“隐私与安全性”中选择“仍要打开”。</p></div>
        <div className="install__action">
          <DownloadLink className="button button--download"><DownloadSimple size={20} weight="bold" /> 下载一念 {siteConfig.version}</DownloadLink>
          <small>适用于 {siteConfig.minimumSystem} · 开发签名、尚未公证</small>
          <a href="https://github.com/lindaifeng/MacLunach/releases" target="_blank" rel="noreferrer">在 GitHub Releases 查看版本 <ArrowUpRight size={14} /></a>
        </div>
      </div>
    </section>
  );
}

function Lightbox({ image, onClose }) {
  useEffect(() => {
    if (!image) return undefined;
    const onKeyDown = (event) => { if (event.key === "Escape") onClose(); };
    document.body.classList.add("lightbox-open");
    window.addEventListener("keydown", onKeyDown);
    return () => { document.body.classList.remove("lightbox-open"); window.removeEventListener("keydown", onKeyDown); };
  }, [image, onClose]);
  if (!image) return null;
  return <div className="lightbox" role="dialog" aria-modal="true" aria-label={image.alt} onMouseDown={onClose}><button type="button" className="lightbox__close" onClick={onClose} aria-label="关闭大图"><X size={22} /></button><img src={image.src} alt={image.alt} onMouseDown={(event) => event.stopPropagation()} /></div>;
}

export function App() {
  const [lightboxImage, setLightboxImage] = useState(null);
  useEffect(() => {
    const elements = Array.from(document.querySelectorAll("[data-reveal]"));
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) { elements.forEach((element) => element.classList.add("is-visible")); return undefined; }
    const observer = new IntersectionObserver((entries) => entries.forEach((entry) => { if (entry.isIntersecting) { entry.target.classList.add("is-visible"); observer.unobserve(entry.target); } }), { threshold: 0.1 });
    elements.forEach((element) => observer.observe(element));
    return () => observer.disconnect();
  }, []);

  return <><Header /><main><Hero onOpen={setLightboxImage} /><Experience onOpen={setLightboxImage} /><Workflows onOpen={setLightboxImage} /><Privacy /><Install /></main><footer className="footer"><div className="shell footer__inner"><a className="brand" href="#top"><img src={assetURL("brand-logo.png")} alt="" /><span>一念</span></a><p>一念，所想即现。</p><span>© 2026 一念</span></div></footer><Lightbox image={lightboxImage} onClose={() => setLightboxImage(null)} /></>;
}
