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
            image = NSImage(systemSymbolName: result.kind == .application ? "app" : "doc", accessibilityDescription: nil)
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
    let palette: ThemePalette
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: SearchIconCache.shared.icon(for: result))
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                highlightedTitle
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(result.subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            if isSelected {
                Text(result.kind == .file ? "↩ 打开  ⌘↩ 显示" : "↩ 打开  ⌘↩ 显示")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(isSelected ? palette.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isSelected ? "已选择" : "")
        .accessibilityAction(.default, action)
        .accessibilityIdentifier("search.result.\(result.id)")
    }

    private var highlightedTitle: Text {
        let ranges = SearchResultHighlighting.matchedRanges(in: result, query: query)
        guard !ranges.isEmpty else {
            return Text(result.title).foregroundColor(palette.primaryText)
        }

        var text = Text("")
        var cursor = result.title.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                text = text + Text(String(result.title[cursor..<range.lowerBound]))
                    .foregroundColor(palette.primaryText)
            }
            text = text + Text(String(result.title[range]))
                .foregroundColor(palette.accent)
                .bold()
            cursor = range.upperBound
        }
        if cursor < result.title.endIndex {
            text = text + Text(String(result.title[cursor...]))
                .foregroundColor(palette.primaryText)
        }
        return text
    }
}
