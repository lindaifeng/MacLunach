import AppKit
import SwiftUI

struct SearchQueryField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> SearchTextView {
        let textView = SearchTextView()
        textView.delegate = context.coordinator
        textView.onTextChange = { [weak coordinator = context.coordinator] value in
            coordinator?.synchronizeText(value)
        }
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = true
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byTruncatingTail
        textView.font = .systemFont(ofSize: 18, weight: .medium)
        textView.applyAppearance(
            textColor: .white,
            placeholderColor: NSColor.white.withAlphaComponent(0.56)
        )
        textView.placeholderString = "搜索应用、文件、动作"
        textView.setAccessibilityRole(.textField)
        textView.setAccessibilityIdentifier("search.query")
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: SearchTextView, context: Context) {
        context.coordinator.text = $text
        textView.applyAppearance(
            textColor: .white,
            placeholderColor: NSColor.white.withAlphaComponent(0.56)
        )
        if text.isEmpty, !textView.string.isEmpty {
            textView.string = ""
            textView.unmarkText()
            textView.needsDisplay = true
        } else if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            synchronizeText(textView.string)
        }

        func synchronizeText(_ value: String) {
            guard text.wrappedValue != value else { return }
            text.wrappedValue = value
        }
    }
}

@MainActor
final class SearchTextView: NSTextView {
    var onTextChange: ((String) -> Void)?
    var placeholderString = "" {
        didSet { needsDisplay = true }
    }
    var placeholderColor = NSColor.placeholderTextColor {
        didSet { needsDisplay = true }
    }

    func applyAppearance(textColor: NSColor, placeholderColor: NSColor) {
        self.textColor = textColor
        insertionPointColor = textColor
        self.placeholderColor = placeholderColor
        typingAttributes[.foregroundColor] = textColor
        needsDisplay = true
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        notifyTextChange()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        notifyTextChange()
    }

    override func unmarkText() {
        super.unmarkText()
        notifyTextChange()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: placeholderColor
        ]
        NSString(string: placeholderString).draw(
            at: NSPoint(x: textContainerInset.width + 4, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    private func notifyTextChange() {
        needsDisplay = true
        onTextChange?(string)
    }
}
