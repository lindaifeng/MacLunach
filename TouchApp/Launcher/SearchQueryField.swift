import AppKit
import SwiftUI

struct SearchQueryField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let textColor: NSColor
    let placeholderColor: NSColor
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> SearchTextView {
        let textView = SearchTextView()
        textView.delegate = context.coordinator
        textView.onTextChange = { [weak coordinator = context.coordinator] value in
            coordinator?.synchronizeText(value)
        }
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.synchronizeFocus(focused)
        }
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byTruncatingTail
        textView.font = .systemFont(ofSize: 18, weight: .medium)
        textView.applyAppearance(
            textColor: textColor,
            placeholderColor: placeholderColor
        )
        textView.placeholderString = placeholder
        textView.setAccessibilityRole(.textField)
        textView.setAccessibilityIdentifier("search.query")
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: SearchTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        textView.applyAppearance(
            textColor: textColor,
            placeholderColor: placeholderColor
        )
        textView.placeholderString = placeholder
        if text.isEmpty, !textView.string.isEmpty {
            textView.string = ""
            textView.unmarkText()
            textView.needsDisplay = true
        } else if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }

        if !isFocused {
            guard textView.window?.firstResponder === textView else { return }
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window?.firstResponder === textView else { return }
                textView.window?.makeFirstResponder(nil)
            }
            return
        }

        guard textView.window?.firstResponder !== textView else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView, textView.window?.firstResponder !== textView else { return }
            textView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            synchronizeText(textView.string)
        }

        func textDidBeginEditing(_ notification: Notification) {
            synchronizeFocus(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            synchronizeFocus(false)
        }

        func synchronizeText(_ value: String) {
            guard text.wrappedValue != value else { return }
            text.wrappedValue = value
        }

        func synchronizeFocus(_ value: Bool) {
            guard isFocused.wrappedValue != value else { return }
            isFocused.wrappedValue = value
        }
    }
}

@MainActor
final class SearchTextView: NSTextView {
    var onTextChange: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
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
        if let font {
            typingAttributes[.font] = font
        }
        typingAttributes[.foregroundColor] = textColor
        needsDisplay = true
    }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder { onFocusChange?(true) }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder { onFocusChange?(false) }
        return resignedFirstResponder
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            normalizedInput(string),
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        notifyTextChange()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(normalizedInput(string), replacementRange: replacementRange)
        notifyTextChange()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isSelectAll(event) {
            selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isSelectAll(event) {
            selectAll(nil)
            return
        }
        super.keyDown(with: event)
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
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    private func notifyTextChange() {
        needsDisplay = true
        onTextChange?(string)
    }

    private func normalizedInput(_ value: Any) -> NSAttributedString {
        let attributedString: NSMutableAttributedString
        if let value = value as? NSAttributedString {
            attributedString = NSMutableAttributedString(attributedString: value)
        } else {
            attributedString = NSMutableAttributedString(string: String(describing: value))
        }

        let range = NSRange(location: 0, length: attributedString.length)
        guard range.length > 0 else { return attributedString }

        attributedString.addAttributes(
            [
                .font: font ?? NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: textColor ?? .white
            ],
            range: range
        )
        applyChineseBaselineAdjustment(to: attributedString)
        return attributedString
    }

    private func isSelectAll(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers == .command
            && (event.keyCode == 0 || event.charactersIgnoringModifiers?.lowercased() == "a")
    }

    private func applyChineseBaselineAdjustment(to string: NSMutableAttributedString) {
        let value = string.string
        value.enumerateSubstrings(
            in: value.startIndex..<value.endIndex,
            options: [.byComposedCharacterSequences]
        ) { substring, substringRange, _, _ in
            guard let substring, let scalar = substring.unicodeScalars.first,
                  Self.isChineseIdeograph(scalar) else { return }
            string.addAttribute(
                .baselineOffset,
                value: -1,
                range: NSRange(substringRange, in: value)
            )
        }
    }

    private static func isChineseIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}
