import Foundation
import ScreenshotFeature

enum SelectionSticker: String, CaseIterable, Equatable, Sendable {
    case smile = "😊"
    case celebrate = "🎉"
    case heart = "❤️"
    case check = "✅"
    case warning = "⚠️"
    case star = "⭐️"

    var title: String {
        switch self {
        case .smile: "微笑"
        case .celebrate: "庆祝"
        case .heart: "喜欢"
        case .check: "完成"
        case .warning: "注意"
        case .star: "重点"
        }
    }

}

enum SelectionWatermark: String, CaseIterable, Equatable, Sendable {
    case touch = "一念"
    case confidential = "机密"
    case internalOnly = "仅供内部使用"
    case draft = "草稿"

    var title: String { rawValue }
}

enum SelectionBeautifyPreset: String, CaseIterable, Equatable, Sendable {
    case cleanLight
    case aurora
    case ocean
    case sunset

    var title: String {
        switch self {
        case .cleanLight: "简洁白"
        case .aurora: "极光紫"
        case .ocean: "海洋蓝"
        case .sunset: "日落橙"
        }
    }

    var style: ScreenshotAnnotationBeautify {
        switch self {
        case .cleanLight:
            .init(
                cornerRadius: 16,
                shadowRadius: 16,
                shadowOpacity: 0.20,
                shadowOffsetX: 0,
                shadowOffsetY: 6,
                insets: .uniform(32),
                backgroundGradient: .init(
                    colors: [
                        .init(red: 0.98, green: 0.99, blue: 1),
                        .init(red: 0.86, green: 0.89, blue: 0.95)
                    ],
                    angleDegrees: 30
                )
            )
        case .aurora:
            .init(
                cornerRadius: 18,
                shadowRadius: 18,
                shadowOpacity: 0.28,
                shadowOffsetX: 0,
                shadowOffsetY: 7,
                insets: .uniform(36),
                backgroundGradient: .init(
                    colors: [
                        .init(red: 0.34, green: 0.20, blue: 0.88),
                        .init(red: 0.66, green: 0.32, blue: 0.92),
                        .init(red: 0.24, green: 0.82, blue: 0.83)
                    ],
                    angleDegrees: 24
                )
            )
        case .ocean:
            .init(
                cornerRadius: 18,
                shadowRadius: 17,
                shadowOpacity: 0.24,
                shadowOffsetX: 0,
                shadowOffsetY: 6,
                insets: .uniform(34),
                backgroundGradient: .init(
                    colors: [
                        .init(red: 0.05, green: 0.33, blue: 0.76),
                        .init(red: 0.10, green: 0.67, blue: 0.91),
                        .init(red: 0.30, green: 0.88, blue: 0.77)
                    ],
                    angleDegrees: 18
                )
            )
        case .sunset:
            .init(
                cornerRadius: 20,
                shadowRadius: 20,
                shadowOpacity: 0.30,
                shadowOffsetX: 0,
                shadowOffsetY: 8,
                insets: .uniform(38),
                backgroundGradient: .init(
                    colors: [
                        .init(red: 0.98, green: 0.38, blue: 0.30),
                        .init(red: 0.98, green: 0.66, blue: 0.26),
                        .init(red: 0.62, green: 0.22, blue: 0.72)
                    ],
                    angleDegrees: -18
                )
            )
        }
    }
}

/// 截图选区确认后显示的 QQ 式工具栏项目。
///
/// 顺序与参考视频保持一致，避免把“区域/全屏”重新做成前置模式菜单。
enum SelectionToolbarItem: String, CaseIterable, Equatable, Sendable {
    case rectangle
    case ellipse
    case line
    case arrow
    case freehand
    case highlighter
    case text
    case numberedMarker
    case callout
    case note
    case sticker
    case mosaic
    case watermark
    case beautify
    case scrollingCapture
    case gifRecording
    case recognizeText
    case translate
    case pin
    case cancel
    case save
    case copy

    enum Kind: Equatable, Sendable {
        case annotation
        case effect
        case captureExtension
        case recognition
        case completion
    }

    static let referenceOrder: [SelectionToolbarItem] = [
        .rectangle,
        .ellipse,
        .line,
        .arrow,
        .freehand,
        .highlighter,
        .text,
        .numberedMarker,
        .callout,
        .note,
        .sticker,
        .mosaic,
        .watermark,
        .beautify,
        .scrollingCapture,
        .gifRecording,
        .recognizeText,
        .translate,
        .pin,
        .cancel,
        .save,
        .copy
    ]

    /// 新版 Mac QQ 截图将高频标注与完成动作保持在单行工具栏，低频能力收进“更多”。
    static let qqPrimaryOrder: [SelectionToolbarItem] = [
        .rectangle,
        .ellipse,
        .arrow,
        .freehand,
        .text,
        .numberedMarker,
        .callout,
        .mosaic,
        .scrollingCapture,
        .recognizeText,
        .translate,
        .pin,
        .cancel,
        .save,
        .copy
    ]

    static let qqOverflowOrder: [SelectionToolbarItem] = referenceOrder.filter {
        !qqPrimaryOrder.contains($0)
    }

    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .ellipse: "圆形"
        case .line: "直线"
        case .arrow: "箭头"
        case .freehand: "绘画"
        case .highlighter: "荧光笔"
        case .text: "文本"
        case .numberedMarker: "数字点"
        case .callout: "批注"
        case .note: "备注"
        case .sticker: "贴纸"
        case .mosaic: "马赛克"
        case .watermark: "水印"
        case .beautify: "美化"
        case .scrollingCapture: "滚动截图"
        case .gifRecording: "GIF 录制"
        case .recognizeText: "文字识别"
        case .translate: "翻译"
        case .pin: "钉至桌面"
        case .cancel: "取消"
        case .save: "保存"
        case .copy: "拷贝"
        }
    }

    /// 鼠标悬停文案使用用户更熟悉的工具名称。
    var hoverTitle: String {
        switch self {
        case .rectangle: "正方形"
        case .ellipse: "圆形"
        case .text: "文字"
        case .arrow: "箭头"
        case .numberedMarker: "序号"
        case .callout: "批注"
        default: title
        }
    }

    var shortcut: String? {
        switch self {
        case .rectangle: "R"
        case .ellipse: "O"
        case .line: "L"
        case .text: "T"
        case .numberedMarker: "1"
        case .callout: "C"
        case .note: "N"
        case .pin: "P"
        case .cancel: "ESC"
        default: nil
        }
    }

    var accessibilityLabel: String {
        guard let shortcut else { return title }
        return "\(title)，快捷键 \(shortcut)"
    }

    var kind: Kind {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .freehand, .highlighter,
             .text, .numberedMarker, .callout, .note, .sticker:
            .annotation
        case .mosaic, .watermark, .beautify:
            .effect
        case .scrollingCapture, .gifRecording:
            .captureExtension
        case .recognizeText, .translate:
            .recognition
        case .pin, .cancel, .save, .copy:
            .completion
        }
    }

    var systemImageName: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .freehand: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .numberedMarker: "1.circle"
        case .callout: "bubble.left.and.text.bubble.right"
        case .note: "note.text"
        case .sticker: "face.smiling"
        case .mosaic: "square.grid.3x3.fill"
        case .watermark: "drop"
        case .beautify: "wand.and.stars"
        case .scrollingCapture: "scroll"
        case .gifRecording: "record.circle"
        case .recognizeText: "text.viewfinder"
        case .translate: "character.book.closed"
        case .pin: "pin"
        case .cancel: "xmark"
        case .save: "arrow.down.to.line"
        case .copy: "checkmark"
        }
    }

    var supportsQQOptions: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .freehand, .highlighter,
             .text, .numberedMarker, .callout, .note, .sticker, .mosaic:
            true
        default:
            false
        }
    }

    var selectionCompletionAction: ScreenshotSelectionCompletionAction? {
        switch self {
        case .copy:
            .copy
        case .save:
            .save
        case .pin:
            .pin
        case .recognizeText:
            .recognizeText
        case .translate:
            .translate
        case .scrollingCapture:
            .scrollingCapture
        case .gifRecording:
            .gifRecording
        default:
            nil
        }
    }
}
