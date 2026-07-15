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
                Picker("导出格式", selection: formatBinding) {
                    ForEach(ScreenshotImageFormat.allCases, id: \.rawValue) { format in
                        Text(AnnotationExportOptions.displayName(for: format))
                            .tag(format.rawValue)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("导出格式")
                .accessibilityValue(options.formatDisplayName)
                .accessibilityIdentifier("screenshot.annotation.export.format")
            }

            GridRow {
                Text("质量：")
                HStack(spacing: 8) {
                    Slider(value: $options.quality, in: 0.1...1, step: 0.01)
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

    private var formatBinding: Binding<String> {
        Binding(
            get: { options.format.rawValue },
            set: { rawValue in
                guard let format = ScreenshotImageFormat(rawValue: rawValue) else { return }
                options.format = format
                onFormatChange(format)
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
