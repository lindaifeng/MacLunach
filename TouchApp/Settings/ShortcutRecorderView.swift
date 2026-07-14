import AppKit
import SwiftUI
import TouchFeatureAPI

struct ShortcutRecorderView: View {
    var title = "快捷键"
    let shortcut: TouchFeatureAPI.KeyboardShortcut
    let errorMessage: String?
    let onCapture: (TouchFeatureAPI.KeyboardShortcut) -> Void

    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button(isRecording ? "请按下组合键…" : shortcut.displayValue) {
                    isRecording.toggle()
                    isRecording ? startMonitoring() : stopMonitoring()
                }
                .accessibilityIdentifier("settings.shortcut-recorder")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if isRecording {
                Text("快捷键需包含 Command、Option、Control 或 Shift。按 Esc 取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            guard let captured = TouchFeatureAPI.KeyboardShortcut(event: event) else { return event }
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
}

private extension TouchFeatureAPI.KeyboardShortcut {
    init?(event: NSEvent) {
        var modifiers: Set<Modifier> = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        guard !modifiers.isEmpty,
              let characters = event.charactersIgnoringModifiers,
              let key = characters.first,
              !key.isWhitespace else { return nil }
        self.init(modifiers: modifiers, key: String(key))
    }
}

struct ShortcutEditorView: View {
    @EnvironmentObject private var featureStore: FeatureAreaStore
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    let featureID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("修改快捷键")
                .font(.title2.bold())
            ShortcutRecorderView(
                shortcut: featureStore.shortcut(for: featureID),
                errorMessage: errorMessage
            ) { shortcut in
                errorMessage = featureStore.updateShortcut(shortcut, for: featureID)
                if errorMessage == nil { dismiss() }
            }
            Button("取消", action: dismiss.callAsFunction)
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 360)
    }
}
