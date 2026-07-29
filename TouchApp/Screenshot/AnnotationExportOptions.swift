import ScreenshotFeature
import SwiftUI
import UniformTypeIdentifiers

/// 标注截图“另存为”的可测试导出状态。格式选择是唯一事实来源，避免保存面板的
/// 文件扩展名、UTType 和实际编码格式彼此不一致。
@MainActor
final class AnnotationExportOptions: ObservableObject {
    @Published var format: ScreenshotImageFormat
    @Published var quality: Double

    init(format: ScreenshotImageFormat = .png, quality: Double = 0.92) {
        self.format = format
        self.quality = Self.clampedQuality(quality)
    }

    var outputOptions: ScreenshotOutputOptions {
        ScreenshotOutputOptions(
            format: format,
            quality: format == .png ? 1 : Self.clampedQuality(quality)
        )
    }

    var contentType: UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heif: .heic
        }
    }

    var preferredFilenameExtension: String {
        switch format {
        case .png: "png"
        case .jpeg: "jpg"
        case .heif: "heic"
        }
    }

    func suggestedFileName(for sourceURL: URL) -> String {
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        return "\(sourceName)-标注.\(preferredFilenameExtension)"
    }

    func replacingExtension(in fileName: String) -> String {
        let pathExtension = (fileName as NSString).pathExtension
        let baseName = pathExtension.isEmpty
            ? fileName
            : (fileName as NSString).deletingPathExtension
        return "\(baseName).\(preferredFilenameExtension)"
    }

    var formatDisplayName: String {
        Self.displayName(for: format)
    }

    var qualityPercentage: Int {
        Int((Self.clampedQuality(quality) * 100).rounded())
    }

    static func displayName(for format: ScreenshotImageFormat) -> String {
        switch format {
        case .png: "PNG（无损）"
        case .jpeg: "JPEG"
        case .heif: "HEIF"
        }
    }

    private static func clampedQuality(_ quality: Double) -> Double {
        guard quality.isFinite else { return 0.92 }
        return min(1, max(0.1, quality))
    }
}

struct AnnotationExportAccessoryView: View {
    @ObservedObject var options: AnnotationExportOptions
    let onFormatChange: (ScreenshotImageFormat) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("格式：")
                AnnotationFormatSelector(selection: formatBinding, onSelect: onFormatChange)
                .accessibilityLabel("导出格式")
                .accessibilityValue(options.formatDisplayName)
                .accessibilityIdentifier("screenshot.annotation.export.format")
            }

            GridRow {
                Text("质量：")
                HStack(spacing: 8) {
                    AnnotationRangeControl(value: $options.quality, in: 0.1...1, step: 0.01)
                        .frame(width: 180)
                        .disabled(options.format == .png)
                        .accessibilityLabel("导出质量")
                        .accessibilityValue(qualityAccessibilityValue)
                        .accessibilityIdentifier("screenshot.annotation.export.quality")
                    Text(qualityLabel)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 330)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("标注截图导出选项")
        .accessibilityIdentifier("screenshot.annotation.export.options")
    }

    private var formatBinding: Binding<ScreenshotImageFormat> {
        Binding(
            get: { options.format },
            set: { format in
                options.format = format
            }
        )
    }

    private var qualityLabel: String {
        options.format == .png ? "无损" : "\(options.qualityPercentage)%"
    }

    private var qualityAccessibilityValue: String {
        options.format == .png ? "PNG 无损" : "百分之 \(options.qualityPercentage)"
    }
}

struct AnnotationFormatSelector: View {
    @Binding private var selection: ScreenshotImageFormat
    private let onSelect: (ScreenshotImageFormat) -> Void

    init(
        selection: Binding<ScreenshotImageFormat>,
        onSelect: @escaping (ScreenshotImageFormat) -> Void
    ) {
        _selection = selection
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ScreenshotImageFormat.allCases, id: \.rawValue) { format in
                Button {
                    selection = format
                    onSelect(format)
                } label: {
                    Text(shortName(for: format))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected(format) ? .white : Color.primary.opacity(0.78))
                        .frame(minWidth: 54)
                        .frame(height: 26)
                        .background(
                            isSelected(format) ? Color.accentColor : Color.primary.opacity(0.08),
                            in: Capsule(style: .continuous)
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .stroke(
                                    isSelected(format) ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.14),
                                    lineWidth: 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AnnotationExportOptions.displayName(for: format))
                .accessibilityAddTraits(isSelected(format) ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.05), in: Capsule(style: .continuous))
    }

    private func isSelected(_ format: ScreenshotImageFormat) -> Bool {
        selection == format
    }

    private func shortName(for format: ScreenshotImageFormat) -> String {
        switch format {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heif: "HEIF"
        }
    }
}
