import Foundation

public enum MarkdownWorkspaceMode: Sendable { case reading, split, editing }

public struct MarkdownHeading: Identifiable, Equatable, Sendable {
    public let id: String
    public let level: Int
    public let title: String
    public let sourceIndex: Int
    public init(id: String, level: Int, title: String, sourceIndex: Int) { self.id = id; self.level = level; self.title = title; self.sourceIndex = sourceIndex }
}

/// 从预览层读取到的标题。`anchor` 必须来自已渲染页面的真实 DOM，不从 Markdown
/// 源文件重新推导，避免与渲染器实际生成的锚点脱节。
public struct RenderedMarkdownHeading: Equatable, Sendable {
    public let level: Int
    public let title: String
    public let anchor: String

    public init(level: Int, title: String, anchor: String) {
        self.level = level
        self.title = title
        self.anchor = anchor
    }
}

public enum MarkdownOutlineState: Equatable, Sendable {
    case available([MarkdownHeading])
    case restricted(message: String)
}

public struct MarkdownOutlineBuilder: Sendable {
    public init() {}

    /// 生产路径：仅消费预览 DOM 返回的标题和锚点。
    public func build(
        renderedHeadings: [RenderedMarkdownHeading],
        mode: MarkdownWorkspaceMode
    ) -> MarkdownOutlineState {
        guard mode != .editing else {
            return .restricted(message: "切换到阅读或分栏模式以查看目录")
        }

        let headings = renderedHeadings.enumerated().compactMap { index, item -> MarkdownHeading? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let anchor = item.anchor.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...6).contains(item.level), !title.isEmpty, !anchor.isEmpty else { return nil }
            return MarkdownHeading(id: anchor, level: item.level, title: title, sourceIndex: index)
        }
        return .available(headings)
    }

    /// 兼容既有 fixture 的过渡重载；应用中的预览桥不得调用它。
    public func build(renderedHeadings: [(level: Int, title: String)], mode: MarkdownWorkspaceMode) -> MarkdownOutlineState {
        var occurrences: [String: Int] = [:]
        let domHeadings = renderedHeadings.compactMap { item -> RenderedMarkdownHeading? in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...6).contains(item.level), !title.isEmpty else { return nil }
            let base = slug(title)
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let anchor = occurrence == 0 ? base : "\(base)-\(occurrence)"
            return RenderedMarkdownHeading(level: item.level, title: title, anchor: anchor)
        }
        return build(renderedHeadings: domHeadings, mode: mode)
    }

    public func activeHeading(in headings: [MarkdownHeading], visibleOffsets: [String: Double]) -> MarkdownHeading? {
        let candidates = headings.compactMap { heading in visibleOffsets[heading.id].map { (heading, $0) } }
        return candidates.filter { $0.1 <= 24 }.max(by: { $0.1 < $1.1 })?.0 ?? candidates.min(by: { abs($0.1) < abs($1.1) })?.0
    }

    private func slug(_ title: String) -> String {
        let lowered = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        let components = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let value = components.joined(separator: "-")
        return value.isEmpty ? "heading" : value
    }
}
