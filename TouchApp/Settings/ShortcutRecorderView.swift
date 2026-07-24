import AppKit
import SwiftUI
import TouchCore
import TouchFeatureAPI

struct ShortcutRecorderView: View {
    var title = "快捷键"
    var detail: String?
    var requiresExactlyOneModifier = false
    var allowedModifierCounts: ClosedRange<Int>?
    var emptyTitle = "未设置"
    let shortcut: TouchFeatureAPI.KeyboardShortcut
    let errorMessage: String?
    let theme: ThemeDefinition
    var onClear: (() -> Void)?
    let onCapture: (TouchFeatureAPI.KeyboardShortcut) -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text.primary.color)
                    if isRecording || detail != nil {
                        Text(isRecording ? recordingHint : detail ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text.secondary.color)
                    }
                }
                Spacer()
                HStack(spacing: 6) {
                    if !shortcut.key.isEmpty, let onClear {
                        Button(action: onClear) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(theme.text.weak.color)
                                .frame(width: 26, height: 26)
                                .background(
                                    theme.shortcut.fill.color,
                                    in: RoundedRectangle(
                                        cornerRadius: theme.shortcut.cornerRadius,
                                        style: .continuous
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除\(title)")
                    }

                    Button(isRecording ? "请按下组合键…" : shortcutButtonTitle) {
                        isRecording.toggle()
                        isRecording ? startMonitoring() : stopMonitoring()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isRecording ? theme.accent.color : theme.shortcut.text.color)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        isRecording ? theme.accent.color.opacity(0.14) : theme.shortcut.fill.color,
                        in: RoundedRectangle(cornerRadius: theme.shortcut.cornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: theme.shortcut.cornerRadius, style: .continuous)
                            .stroke(isRecording ? theme.accent.color.opacity(0.7) : theme.shortcut.border.color, lineWidth: 1)
                    }
                    .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: false))
                    .accessibilityIdentifier("settings.shortcut-recorder")
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stopMonitoring() }
    }

    private func startMonitoring() {
        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
            if event.keyCode == 53 {
                Task { @MainActor in
                    isRecording = false
                    stopMonitoring()
                }
                return nil
            }

            guard let captured = TouchFeatureAPI.KeyboardShortcut(
                globalEvent: event,
                allowedModifierCounts: effectiveModifierCounts
            ), (try? HotKeyMapping.carbonValue(for: captured)) != nil else { return nil }
            Task { @MainActor in
                onCapture(captured)
                isRecording = false
                stopMonitoring()
            }
            return nil
        }
    }

    private func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    private var recordingHint: String {
        if effectiveModifierCounts == 1...1 {
            return "请按下一个修饰键与一个主键，Esc 取消。"
        }
        if effectiveModifierCounts == 1...2 {
            return "请按下一至两个修饰键与一个主键，Esc 取消。"
        }
        return "快捷键需包含 Command、Option、Control 或 Shift，Esc 取消。"
    }

    private var effectiveModifierCounts: ClosedRange<Int> {
        allowedModifierCounts ?? (requiresExactlyOneModifier ? 1...1 : 1...4)
    }

    private var shortcutButtonTitle: String {
        shortcut.key.isEmpty ? emptyTitle : shortcut.displayValue
    }
}

private extension TouchFeatureAPI.KeyboardShortcut {
    init?(globalEvent event: NSEvent, allowedModifierCounts: ClosedRange<Int>) {
        var modifiers: Set<Modifier> = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        guard allowedModifierCounts.contains(modifiers.count) else { return nil }
        let key: String
        if event.keyCode == 49 {
            key = "space"
        } else if let characters = event.charactersIgnoringModifiers,
                  let character = characters.first,
                  !character.isWhitespace {
            key = String(character)
        } else {
            return nil
        }
        self.init(modifiers: modifiers, key: key)
    }
}

struct SingleKeyRecorderView: View {
    var title = "功能键位"
    let shortcut: TouchFeatureAPI.KeyboardShortcut
    let errorMessage: String?
    let theme: ThemeDefinition
    let onCapture: (TouchFeatureAPI.KeyboardShortcut) -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.text.primary.color)
                    Text(isRecording ? "请按下一个字母、数字或符号键，Esc 取消。" : "启动器打开且搜索框为空时，按此键直接执行。")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text.secondary.color)
                }
                Spacer()
                Button(isRecording ? "请按键…" : shortcut.key.uppercased()) {
                    isRecording.toggle()
                    isRecording ? startMonitoring() : stopMonitoring()
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isRecording ? theme.accent.color : theme.shortcut.text.color)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    isRecording ? theme.accent.color.opacity(0.14) : theme.shortcut.fill.color,
                    in: RoundedRectangle(cornerRadius: theme.shortcut.cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: theme.shortcut.cornerRadius, style: .continuous)
                        .stroke(isRecording ? theme.accent.color.opacity(0.7) : theme.shortcut.border.color, lineWidth: 1)
                }
                .buttonStyle(ThemePressButtonStyle(theme: theme, reduceMotion: false))
                .accessibilityIdentifier("settings.single-key-recorder")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.text.failure.color)
            }
        }
        .onDisappear { stopMonitoring() }
    }

    private func startMonitoring() {
        stopMonitoring()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    isRecording = false
                    stopMonitoring()
                }
                return nil
            }
            let blockedModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
            guard event.modifierFlags.intersection(blockedModifiers).isEmpty,
                  let characters = event.charactersIgnoringModifiers,
                  let character = characters.first,
                  !character.isWhitespace else { return nil }
            Task { @MainActor in
                onCapture(.init(modifiers: [], key: String(character)))
                isRecording = false
                stopMonitoring()
            }
            return nil
        }
    }

    private func stopMonitoring() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

struct ShortcutEditorView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    let featureID: String

    private var theme: ThemeDefinition {
        ThemeRegistry.shared.definition(for: themeStore.theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("修改快捷键")
                .font(.system(size: 18, weight: .semibold))
            SingleKeyRecorderView(
                shortcut: featureStore.shortcut(for: featureID),
                errorMessage: errorMessage,
                theme: theme
            ) { shortcut in
                errorMessage = featureStore.updateShortcut(shortcut, for: featureID)
                if errorMessage == nil { dismiss() }
            }
            Button("取消", action: dismiss.callAsFunction)
                .foregroundStyle(theme.text.secondary.color)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 340)
    }
}
