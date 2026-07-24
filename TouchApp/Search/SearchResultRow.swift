import AppKit
import SwiftUI
import TouchCore

enum SearchResultHighlighting {
    static func matchedRanges(in result: SearchResult, query: String) -> [Range<String.Index>] {
        let title = result.title
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !trimmedQuery.isEmpty else { return [] }

        if let range = title.range(
            of: trimmedQuery,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) {
            return [range]
        }

        let needle = normalized(trimmedQuery)
        var needleIndex = needle.startIndex
        var ranges: [Range<String.Index>] = []
        var titleIndex = title.startIndex
        while titleIndex < title.endIndex, needleIndex < needle.endIndex {
            let nextTitleIndex = title.index(after: titleIndex)
            let character = normalized(String(title[titleIndex..<nextTitleIndex]))
            if character.contains(needle[needleIndex]) {
                ranges.append(titleIndex..<nextTitleIndex)
                needle.formIndex(after: &needleIndex)
            }
            titleIndex = nextTitleIndex
        }
        if needleIndex == needle.endIndex { return ranges }

        if SearchRanking.score(result, query: trimmedQuery) > 0 {
            return [title.startIndex..<title.endIndex]
        }
        return []
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .replacingOccurrences(of: " ", with: "")
    }
}

@MainActor
private final class SearchIconCache {
    static let shared = SearchIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func icon(for result: SearchResult) -> NSImage {
        let key = "\(result.kind)-\(result.iconCacheKey)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage
        if result.path.isEmpty {
            let symbolName: String
            switch result.kind {
            case .action: symbolName = "bolt.fill"
            case .application: symbolName = "app"
            case .file: symbolName = "doc"
            }
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                ?? NSImage()
        } else {
            image = NSWorkspace.shared.icon(forFile: result.path)
        }
        image.size = NSSize(width: 34, height: 34)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct SearchResultRow: View {
    let result: SearchResult
    let query: String
    let isSelected: Bool
    let theme: ThemeDefinition
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            resultIcon

            VStack(alignment: .leading, spacing: 3) {
                highlightedTitle
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.text.secondary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if isSelected {
                Text(result.kind == .action ? "↩ 执行" : "↩ 打开  ⌘↩ 显示")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.text.secondary.color)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(isSelected ? theme.card.selectedFill.color : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(theme.accent.color)
                    .frame(width: 2, height: 28)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "已选择" : "")
        .accessibilityAction(.default, action)
        .accessibilityIdentifier("search.result.\(result.id)")
    }

    @ViewBuilder
    private var resultIcon: some View {
        let featurePrefix = "action.feature."
        if result.kind == .action, result.id.hasPrefix(featurePrefix) {
            LauncherFeatureIcon(
                pluginID: String(result.id.dropFirst(featurePrefix.count)),
                fallbackSymbolName: "bolt.fill",
                size: 34,
                fallbackColor: theme.icon.primary.color
            )
        } else {
            Image(nsImage: SearchIconCache.shared.icon(for: result))
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
        }
    }

    private var highlightedTitle: Text {
        let ranges = SearchResultHighlighting.matchedRanges(in: result, query: query)
        guard !ranges.isEmpty else {
            return Text(result.title).foregroundColor(theme.text.primary.color)
        }

        var text = Text("")
        var cursor = result.title.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                text = text + Text(String(result.title[cursor..<range.lowerBound]))
                    .foregroundColor(theme.text.primary.color)
            }
            text = text + Text(String(result.title[range]))
                .foregroundColor(theme.accent.color)
                .bold()
            cursor = range.upperBound
        }
        if cursor < result.title.endIndex {
            text = text + Text(String(result.title[cursor...]))
                .foregroundColor(theme.text.primary.color)
        }
        return text
    }
}
