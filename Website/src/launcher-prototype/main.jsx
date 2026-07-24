import { useEffect, useMemo, useRef, useState } from "react";
import {
  ArrowRight,
  Calendar,
  Check,
  CheckSquare,
  ClockCounterClockwise,
  Command,
  DotsThree,
  FileText,
  FolderOpen,
  GearSix,
  ImageSquare,
  Keyboard,
  Lightning,
  MagnifyingGlass,
  Moon,
  Palette,
  Sun,
  Timer,
  X,
} from "@phosphor-icons/react";
import "./styles.css";

const assetURL = (fileName) => `/assets/${fileName}`;

const modes = [
  { id: "apps", label: "应用" },
  { id: "files", label: "文件" },
  { id: "actions", label: "动作" },
];

const items = [
  {
    id: "finder",
    category: "apps",
    title: "打开访达",
    subtitle: "在当前工作区打开 Finder",
    meta: "最近使用 · 2 分钟前",
    shortcut: "Q",
    action: "打开",
    color: "green",
    icon: FolderOpen,
    description: "快速回到文件工作区，保持当前窗口层级和位置。",
    detail: ["本地功能", "无需权限", "⌥ Space · Q"],
  },
  {
    id: "tasks",
    category: "apps",
    title: "每日任务",
    subtitle: "查看今天的待办和进度",
    meta: "3 项待处理",
    shortcut: "D",
    action: "查看",
    color: "coral",
    icon: CheckSquare,
    description: "把今天真正要做的事放在一个轻量、安静的工作面里。",
    detail: ["今日清单", "3 项待处理", "⌥ Space · D"],
  },
  {
    id: "pomodoro",
    category: "apps",
    title: "番茄闹钟",
    subtitle: "开始一轮 25 分钟专注",
    meta: "上次专注 18 分钟",
    shortcut: "W",
    action: "开始",
    color: "amber",
    icon: Timer,
    description: "用一轮明确的专注时间，把注意力从启动器带回当前任务。",
    detail: ["25 分钟", "可暂停", "⌥ Space · W"],
  },
  {
    id: "calendar",
    category: "apps",
    title: "节假日历",
    subtitle: "查看接下来可用的休息日",
    meta: "下一个假期 · 12 天后",
    shortcut: "B",
    action: "查看",
    color: "blue",
    icon: Calendar,
    description: "快速查看节假日和调休安排，不离开当前工作上下文。",
    detail: ["本地日历", "2026 年", "⌥ Space · B"],
  },
  {
    id: "markdown",
    category: "files",
    title: "Markdown",
    subtitle: "打开最近编辑的文档",
    meta: "Documents / Notes",
    shortcut: "Z",
    action: "打开",
    color: "violet",
    icon: FileText,
    description: "打开最近使用的 Markdown 文件，继续上次停下的位置。",
    detail: ["最近文件", "Documents", "⌥ Space · Z"],
  },
  {
    id: "parser",
    category: "files",
    title: "解析工具",
    subtitle: "格式化 JSON、XML 或 YAML",
    meta: "上次使用 · 昨天",
    shortcut: "C",
    action: "打开",
    color: "violet",
    icon: Lightning,
    description: "把临时的格式化、转换和检查动作放在手边。",
    detail: ["开发工具", "本地处理", "⌥ Space · C"],
  },
  {
    id: "capture",
    category: "actions",
    title: "截取屏幕",
    subtitle: "进入区域截图和标注",
    meta: "屏幕录制权限已授权",
    shortcut: "A",
    action: "执行",
    color: "coral",
    icon: ImageSquare,
    description: "快速截取屏幕、添加标注，然后复制或保存结果。",
    detail: ["屏幕截图", "权限已授权", "⌥ Space · A"],
  },
  {
    id: "super-right",
    category: "actions",
    title: "超级右键",
    subtitle: "新建文件、复制路径或打开终端",
    meta: "需要 Finder 扩展",
    shortcut: "1",
    action: "设置",
    color: "amber",
    icon: DotsThree,
    description: "在 Finder 当前目录执行常用操作，少绕一步。",
    detail: ["Finder 扩展", "需要启用", "⌥ Space · 1"],
  },
];

function IconButton({ label, children, onClick, active = false }) {
  return (
    <button
      className={`icon-button ${active ? "is-active" : ""}`}
      type="button"
      aria-label={label}
      data-tooltip={label}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

function ResultIcon({ item, large = false }) {
  const Icon = item.icon;
  return (
    <span className={`result-icon result-icon--${item.color} ${large ? "is-large" : ""}`}>
      <Icon size={large ? 28 : 21} weight="regular" />
    </span>
  );
}

function ModeSwitch({ mode, onChange }) {
  return (
    <div className="mode-switch" role="tablist" aria-label="搜索范围">
      {modes.map((option) => (
        <button
          key={option.id}
          className={mode === option.id ? "is-active" : ""}
          type="button"
          role="tab"
          aria-selected={mode === option.id}
          onClick={() => onChange(option.id)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}

function ResultRow({ item, selected, onSelect }) {
  return (
    <button
      className={`result-row ${selected ? "is-selected" : ""}`}
      type="button"
      onClick={() => onSelect(item.id)}
      aria-pressed={selected}
    >
      <ResultIcon item={item} />
      <span className="result-row__copy">
        <strong>{item.title}</strong>
        <small>{item.subtitle}</small>
      </span>
      <span className="result-row__meta">{item.meta}</span>
      <kbd>{item.shortcut}</kbd>
      <ArrowRight className="result-row__arrow" size={18} />
    </button>
  );
}

function DetailPane({ item, onRun }) {
  const Icon = item.icon;

  return (
    <aside className="detail-pane" aria-label="选中功能详情">
      <div className="detail-pane__eyebrow">
        <span>已选功能</span>
        <ClockCounterClockwise size={16} />
      </div>
      <div className="detail-pane__hero">
        <ResultIcon item={item} large />
        <span className="detail-pane__signal">就绪</span>
      </div>
      <h2>{item.title}</h2>
      <p className="detail-pane__description">{item.description}</p>
      <div className="detail-tags">
        {item.detail.map((tag) => <span key={tag}>{tag}</span>)}
      </div>
      <button className="run-button" type="button" onClick={() => onRun(item)}>
        <span>{item.action}</span>
        <span className="run-button__key">Enter</span>
      </button>
      <div className="detail-pane__note">
        <Icon size={16} />
        <span>按 Enter 立即{item.action === "执行" ? "执行" : "打开"}</span>
      </div>
    </aside>
  );
}

function LauncherPrototype() {
  const [mode, setMode] = useState("apps");
  const [query, setQuery] = useState("");
  const [selectedId, setSelectedId] = useState("finder");
  const [isDark, setIsDark] = useState(false);
  const [toast, setToast] = useState("");
  const inputRef = useRef(null);

  const visibleItems = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    return items.filter((item) => {
      const matchesMode = item.category === mode;
      const matchesQuery = !normalizedQuery || [item.title, item.subtitle, item.meta]
        .join(" ")
        .toLowerCase()
        .includes(normalizedQuery);
      return matchesMode && matchesQuery;
    });
  }, [mode, query]);

  const selectedItem = visibleItems.find((item) => item.id === selectedId) ?? visibleItems[0] ?? null;

  useEffect(() => {
    if (selectedItem && selectedItem.id !== selectedId) setSelectedId(selectedItem.id);
  }, [selectedId, selectedItem]);

  useEffect(() => {
    const timer = toast ? window.setTimeout(() => setToast(""), 2400) : undefined;
    return () => window.clearTimeout(timer);
  }, [toast]);

  const runItem = (item) => {
    setToast(`${item.action === "设置" ? "前往设置" : item.action}：${item.title}`);
  };

  const moveSelection = (direction) => {
    if (!visibleItems.length) return;
    const currentIndex = visibleItems.findIndex((item) => item.id === selectedItem?.id);
    const nextIndex = currentIndex < 0
      ? 0
      : (currentIndex + direction + visibleItems.length) % visibleItems.length;
    setSelectedId(visibleItems[nextIndex].id);
  };

  const onSearchKeyDown = (event) => {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      moveSelection(1);
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      moveSelection(-1);
    }
    if (event.key === "Enter" && selectedItem) {
      event.preventDefault();
      runItem(selectedItem);
    }
    if (event.key === "Escape") {
      setQuery("");
      inputRef.current?.focus();
    }
    if (event.key === "Tab") {
      event.preventDefault();
      const current = modes.findIndex((option) => option.id === mode);
      setMode(modes[(current + 1) % modes.length].id);
    }
  };

  return (
    <main className={`prototype-shell ${isDark ? "theme-dark" : "theme-light"}`}>
      <div className="wallpaper" aria-hidden="true" />
      <section className="launcher-window" aria-label="一念启动器面板">
        <header className="launcher-header">
          <div className="brand-lockup">
            <img src={assetURL("brand-logo.svg")} alt="" />
            <div>
              <strong>一念</strong>
              <span>所想即现</span>
            </div>
          </div>
          <div className="window-status">
            <span className="status-dot" />
            <span>本地工作区</span>
            <span className="status-separator" />
            <span>⌥ Space</span>
          </div>
          <div className="header-actions">
            <IconButton label={isDark ? "切换日间主题" : "切换黑夜主题"} onClick={() => setIsDark((value) => !value)}>
              {isDark ? <Sun size={18} /> : <Moon size={18} />}
            </IconButton>
            <IconButton label="外观设置"><Palette size={18} /></IconButton>
            <IconButton label="系统设置"><GearSix size={18} /></IconButton>
          </div>
        </header>

        <div className="search-zone">
          <MagnifyingGlass className="search-zone__icon" size={24} />
          <input
            ref={inputRef}
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={onSearchKeyDown}
            placeholder="搜索应用、文件、动作"
            aria-label="搜索应用、文件、动作"
            autoFocus
          />
          {query && (
            <IconButton label="清除搜索" onClick={() => setQuery("")}>
              <X size={17} />
            </IconButton>
          )}
          <ModeSwitch mode={mode} onChange={setMode} />
        </div>

        <div className="content-layout">
          <section className="results-pane" aria-label="搜索结果">
            <div className="results-heading">
              <div>
                <span className="section-kicker">{query ? "搜索结果" : "常用入口"}</span>
                <h1>{query ? `找到 ${visibleItems.length} 个结果` : "现在就开始"}</h1>
              </div>
              <span className="result-count">{visibleItems.length.toString().padStart(2, "0")}</span>
            </div>
            <div className="result-list">
              {visibleItems.length ? visibleItems.map((item) => (
                <ResultRow
                  key={item.id}
                  item={item}
                  selected={selectedItem?.id === item.id}
                  onSelect={setSelectedId}
                />
              )) : (
                <div className="empty-state">
                  <MagnifyingGlass size={26} />
                  <strong>没有找到匹配结果</strong>
                  <span>试试应用名称或动作关键词</span>
                </div>
              )}
            </div>
            <div className="keyboard-hints">
              <span><kbd>↑</kbd><kbd>↓</kbd> 选择</span>
              <span><kbd>Enter</kbd> 打开</span>
              <span><kbd>Tab</kbd> 切换范围</span>
              <span><kbd>Esc</kbd> 清除</span>
            </div>
          </section>
          {selectedItem ? <DetailPane item={selectedItem} onRun={runItem} /> : (
            <aside className="detail-pane detail-pane--empty"><Keyboard size={28} /><span>选择一个结果查看详情</span></aside>
          )}
        </div>

        <footer className="launcher-footer">
          <div className="footer-tip"><Command size={15} /><span>专注工作，不离开当前窗口</span></div>
          <div className="footer-shortcuts"><span><Keyboard size={14} /> 快捷键已开启</span><span>v1.0.0 beta</span></div>
        </footer>
      </section>
      {toast && <div className="toast"><Check size={16} weight="bold" />{toast}</div>}
    </main>
  );
}

createRoot(document.getElementById("launcher-prototype-root")).render(<LauncherPrototype />);
