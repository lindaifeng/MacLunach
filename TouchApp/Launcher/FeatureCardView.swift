import AppKit
import SwiftUI
import TouchFeatureAPI

struct FeatureCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let plugin: any FeaturePlugin
    let shortcut: TouchFeatureAPI.KeyboardShortcut
    let state: FeatureState
    let theme: ThemeDefinition
    let action: () -> Void
    let edit: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                LauncherFeatureIcon(
                    pluginID: plugin.manifest.id,
                    fallbackSymbolName: plugin.manifest.symbolName,
                    size: 38,
                    fallbackColor: theme.icon.primary.color
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(plugin.manifest.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                    if let statusLabel {
                        Label(statusLabel.text, systemImage: statusLabel.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(statusLabel.color)
                    }
                }
                Spacer(minLength: 6)
                Text(shortcut.key.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        theme.shortcut.fill.color,
                        in: shortcutShape
                    )
                    .overlay(shortcutShape.stroke(theme.shortcut.border.color, lineWidth: 1))
            }
            .foregroundStyle(theme.text.secondary.color)
            .padding(.horizontal, 16)
            .frame(width: 260, height: 72)
            .background(
                (isHovered ? theme.card.hoverFill : theme.card.fill).color,
                in: cardShape
            )
            .overlay {
                cardShape
                    .stroke((isHovered ? theme.card.hoverBorder : theme.card.border).color, lineWidth: 1)
            }
            .shadow(
                color: (isHovered ? theme.card.hoverShadow : theme.card.shadow).color.color,
                radius: (isHovered ? theme.card.hoverShadow : theme.card.shadow).radius,
                x: (isHovered ? theme.card.hoverShadow : theme.card.shadow).x,
                y: (isHovered ? theme.card.hoverShadow : theme.card.shadow).y
            )
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .offset(y: isHovered ? theme.motion.hoverOffset : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration), value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(plugin.manifest.name)，键位 \(shortcut.key.uppercased())，右键可修改")
        .accessibilityIdentifier("feature.\(plugin.manifest.id)")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.card.cornerRadius, style: .continuous)
    }

    private var shortcutShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.shortcut.cornerRadius, style: .continuous)
    }

    private var statusLabel: (text: String, symbol: String, color: Color)? {
        switch state {
        case .unloaded:
            return ("正在载入", "ellipsis", .secondary)
        case .available:
            return nil
        case .running:
            return ("执行中", "hourglass", theme.accent.color)
        case .restricted:
            return ("需要授权", "lock.fill", theme.text.permission.color)
        case .failed:
            return ("执行故障 · 点击重试", "exclamationmark.triangle.fill", theme.text.failure.color)
        case .disabled:
            return ("已停用", "pause.circle.fill", .secondary)
        }
    }
}

struct CustomActionCardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    let key: String
    let action: LauncherCustomAction
    let theme: ThemeDefinition
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                actionIcon
                    .frame(width: 38, height: 38)
                    .background(
                        theme.icon.container.color,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(action.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Text(action.kind.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.62))
                }

                Spacer(minLength: 6)

                Text(key.uppercased())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(theme.shortcut.fill.color, in: shortcutShape)
                    .overlay(shortcutShape.stroke(theme.shortcut.border.color, lineWidth: 1))
            }
            .padding(.horizontal, 16)
            .frame(width: 260, height: 72)
            .background(
                (isHovered ? theme.card.hoverFill : theme.card.fill).color,
                in: cardShape
            )
            .overlay {
                cardShape
                    .stroke(
                        (isHovered ? theme.card.hoverBorder : theme.card.border).color,
                        lineWidth: 1
                    )
            }
            .shadow(
                color: (isHovered ? theme.card.hoverShadow : theme.card.shadow).color.color,
                radius: (isHovered ? theme.card.hoverShadow : theme.card.shadow).radius,
                x: (isHovered ? theme.card.hoverShadow : theme.card.shadow).x,
                y: (isHovered ? theme.card.hoverShadow : theme.card.shadow).y
            )
        }
        .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: reduceMotion))
        .offset(y: isHovered ? theme.motion.hoverOffset : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: theme.motion.duration), value: isHovered)
        .onHover { isHovered = $0 }
        .help("\(action.displayTitle) · \(action.kind.title)")
        .accessibilityLabel(
            "\(action.displayTitle)，\(action.kind.title)，键位 \(key.uppercased())"
        )
        .accessibilityIdentifier("launcher.custom-card.\(key.lowercased())")
    }

    @ViewBuilder
    private var actionIcon: some View {
        if [.application, .file, .folder].contains(action.kind),
           FileManager.default.fileExists(atPath: action.target) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: action.target))
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(5)
        } else {
            Image(systemName: action.kind.symbolName)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.icon.primary.color)
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.card.cornerRadius, style: .continuous)
    }

    private var shortcutShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: theme.shortcut.cornerRadius, style: .continuous)
    }
}

struct LauncherFeatureIcon: View {
    let pluginID: String
    let fallbackSymbolName: String
    let size: CGFloat
    let fallbackColor: Color

    var body: some View {
        Group {
            if let assetName = Self.assetNames[pluginID] {
                Image(assetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: fallbackSymbolName)
                    .font(.system(size: size * 0.58, weight: .semibold))
                    .foregroundStyle(fallbackColor)
                    .background(
                        fallbackColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private static let assetNames = [
        "me.touch.finder": "FeatureIconFinder",
        "me.touch.screenshot": "FeatureIconScreenshot",
        "me.touch.super-right": "FeatureIconSuperRight",
        "me.touch.daily-tasks": "FeatureIconDailyTask",
        "me.touch.pomodoro": "FeatureIconPomodoro",
        "me.touch.holiday-calendar": "FeatureIconHolidayCalendar",
        "me.touch.markdown-preview": "FeatureIconMarkdown",
        "me.touch.parser-tools": "FeatureIconParserTools",
        "me.touch.clipboard": "FeatureIconClipboard",
        "me.touch.translation": "FeatureIconTranslation",
        "me.touch.ocr": "FeatureIconOCR"
    ]
}
