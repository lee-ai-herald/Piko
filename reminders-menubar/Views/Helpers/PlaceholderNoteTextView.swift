import Cocoa
import SwiftUI

// MARK: - Rich Text Formatting Model & Controller

struct NoteFormatState: Equatable {
    var isBold = false
    var isItalic = false
    var isHighlighted = false
    var isUnderlined = false
    var isStrikethrough = false
    var isInlineCode = false
    var headingLevel = 0 // 0 = body, 1 = H1, 2 = H2, 3 = H3

    var hasAnyStyle: Bool {
        isBold || isItalic || isHighlighted || isUnderlined || isStrikethrough || isInlineCode || headingLevel > 0
    }
}

enum NoteFormatAction {
    case toggleBold
    case toggleItalic
    case toggleHighlight
    case toggleUnderline
    case toggleStrikethrough
    case clearFormatting
    case insertMarkdown(MarkdownSnippet)
}

@MainActor
final class NoteFormattingController: ObservableObject {
    @Published var activeFormat = NoteFormatState()
    fileprivate weak var textView: PlaceholderNSTextView?

    func apply(_ action: NoteFormatAction) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.applyFormatAction(action)
    }
}

// MARK: - AppKit-Backed WYSIWYG Markdown & Rich Text Note Editor

/// AppKit-backed multi-line editor featuring:
/// - Sub-pixel-accurate placeholder alignment & full Chinese IME (`hasMarkedText`) safety
/// - Live WYSIWYG Markdown as you type (optional toggle: `#`/`##`/`###`, `**bold**`, `*italic*`,
///   `==highlight==`, `~~strike~~`, `` `code` ``, `- [ ] ` clickable checkboxes, `- ` bullets, `> ` quotes, `---` dividers)
/// - Clickable `☐` / `☑` checkboxes right inside the editor
/// - Rich text formatting (`⌘B`, `⌘I`, `⌘U`, `⇧⌘X`, `⇧⌘H`, `⌘\`) with native Undo/Redo
/// - Smart newline style reset & bullet/numbered/checklist auto-continuation
/// - Selection tracking & right-click "Send selection to Board"
struct PlaceholderNoteTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 13
    var horizontalInset: CGFloat = 12
    var verticalInset: CGFloat = 6
    var lineSpacing: CGFloat = 3
    var isRichTextEnabled: Bool = false
    var isLiveMarkdownEnabled: Bool = false
    var initialRTFData: Data? = nil
    var formattingController: NoteFormattingController? = nil
    var onRichTextChanged: ((String, Data?) -> Void)? = nil
    var onSelectionChanged: ((String) -> Void)? = nil
    /// Callback `(selectedText, splitByLine)` triggered from right-click context menu on selected text.
    var onSendSelectionToBoard: ((String, Bool) -> Void)? = nil

    static let highlightYellowColor = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.16, alpha: 0.46)
    static let inlineCodeBackgroundColor = NSColor.labelColor.withAlphaComponent(0.085)
    static let chineseItalicObliqueness: CGFloat = 0.22

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AutoSizingNoteScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = PlaceholderNSTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = isRichTextEnabled
        textView.isLiveMarkdownEnabled = isRichTextEnabled && isLiveMarkdownEnabled
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 4
        textView.baseFontSize = fontSize
        textView.baseLineSpacing = lineSpacing

        applyBaseConfiguration(to: textView)
        textView.onSendSelectionToBoard = onSendSelectionToBoard
        textView.onFormatChanged = { [weak coordinator = context.coordinator] in
            coordinator?.syncRichTextAndFormat(from: textView)
        }

        if isRichTextEnabled, let rtf = initialRTFData,
           let normalized = Self.normalizedAttributedString(fromRTF: rtf, fontSize: fontSize, lineSpacing: lineSpacing) {
            textView.textStorage?.setAttributedString(normalized)
            context.coordinator.lastSyncedPlainText = normalized.string
        } else {
            let baseAttrs = Self.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttrs))
            context.coordinator.lastSyncedPlainText = text
        }

        textView.typingAttributes = Self.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
        formattingController?.textView = textView
        formattingController?.activeFormat = textView.currentFormatState()

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PlaceholderNSTextView else { return }

        textView.baseFontSize = fontSize
        textView.baseLineSpacing = lineSpacing
        textView.isLiveMarkdownEnabled = isRichTextEnabled && isLiveMarkdownEnabled
        applyBaseConfiguration(to: textView)
        textView.onSendSelectionToBoard = onSendSelectionToBoard
        formattingController?.textView = textView

        // Never overwrite while user is composing with IME (e.g. Chinese Pinyin)
        if !textView.hasMarkedText(), textView.string != text {
            let savedSelection = textView.selectedRanges
            let baseAttrs = Self.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttrs))
            context.coordinator.lastSyncedPlainText = text

            let maxLen = (text as NSString).length
            let clamped = savedSelection.compactMap { value -> NSValue? in
                let r = value.rangeValue
                let loc = min(r.location, maxLen)
                let len = min(r.length, maxLen - loc)
                return NSValue(range: NSRange(location: loc, length: len))
            }
            if !clamped.isEmpty {
                textView.selectedRanges = clamped
            }
            textView.needsDisplay = true
        }
    }

    private func applyBaseConfiguration(to textView: PlaceholderNSTextView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        let resolvedFont = NSFont.systemFont(ofSize: fontSize)

        textView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)
        textView.placeholderText = placeholder
        textView.placeholderFont = resolvedFont
        textView.placeholderParagraphStyle = paragraphStyle
        textView.insertionPointColor = .controlAccentColor

        if !isRichTextEnabled {
            textView.font = resolvedFont
            textView.textColor = .labelColor
            textView.defaultParagraphStyle = paragraphStyle
            textView.typingAttributes = Self.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
        } else {
            textView.defaultParagraphStyle = paragraphStyle
            if textView.typingAttributes[.font] == nil {
                textView.typingAttributes = Self.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
            } else {
                textView.typingAttributes[.paragraphStyle] = textView.typingAttributes[.paragraphStyle] ?? paragraphStyle
            }
        }
    }

    static func baseAttributes(fontSize: CGFloat, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        return [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func headingAttributes(level: Int, baseFontSize: CGFloat, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let size: CGFloat
        let weight: NSFont.Weight
        switch level {
        case 1:
            size = baseFontSize + 5.5
            weight = .bold
        case 2:
            size = baseFontSize + 3.0
            weight = .bold
        default:
            size = baseFontSize + 1.5
            weight = .semibold
        }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacingBefore = level == 1 ? 4 : 2
        paragraphStyle.paragraphSpacing = 2
        return [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func inlineCodeAttributes(baseFontSize: CGFloat, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        return [
            .font: NSFont.monospacedSystemFont(ofSize: max(11, baseFontSize - 1), weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: inlineCodeBackgroundColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func quoteAttributes(baseFontSize: CGFloat, lineSpacing: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.headIndent = 14
        return [
            .font: NSFont.systemFont(ofSize: baseFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]
    }

    static func resolvedFont(size: CGFloat, isBold: Bool, isItalic: Bool) -> NSFont {
        var font = NSFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
        if isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    static func normalizedAttributedString(
        fromRTF data: Data,
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> NSAttributedString? {
        guard let decoded = NSAttributedString(rtf: data, documentAttributes: nil) else {
            return nil
        }

        let result = NSMutableAttributedString(string: decoded.string)
        let fullRange = NSRange(location: 0, length: decoded.length)
        if fullRange.length == 0 {
            return result
        }

        let nsStr = decoded.string as NSString

        decoded.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let chunk = nsStr.substring(with: range)
            let lineRange = nsStr.lineRange(for: NSRange(location: range.location, length: 0))
            let lineStr = nsStr.substring(with: lineRange)

            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isMono = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
            let isBold = traits.contains(.boldFontMask)
            let obliq = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
            let isItalic = traits.contains(.italicFontMask) || obliq > 0.05
            let underlineRaw = (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0
            let strikeRaw = (attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0
            let bgColor = attrs[.backgroundColor] as? NSColor
            let isYellow = NoteMarkdownConverter.isYellowHighlightColor(bgColor)

            // Preserve heading sizes cleanly while normalizing body font size
            let resolvedSize: CGFloat = {
                guard let pt = font?.pointSize else { return fontSize }
                if pt >= fontSize + 4.5 { return fontSize + 5.5 }
                if pt >= fontSize + 2.2 { return fontSize + 3.0 }
                if pt >= fontSize + 1.0 { return fontSize + 1.5 }
                return fontSize
            }()

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = lineSpacing
            if let oldPara = attrs[.paragraphStyle] as? NSParagraphStyle {
                paragraphStyle.headIndent = oldPara.headIndent
                paragraphStyle.firstLineHeadIndent = oldPara.firstLineHeadIndent
                paragraphStyle.paragraphSpacingBefore = oldPara.paragraphSpacingBefore
                paragraphStyle.paragraphSpacing = oldPara.paragraphSpacing
            }

            let resolvedFG: NSColor = {
                if chunk.trimmingCharacters(in: .whitespaces) == "▎" || chunk.trimmingCharacters(in: .whitespaces) == "☑" {
                    return .controlAccentColor
                }
                if lineStr.hasPrefix("────") {
                    return .tertiaryLabelColor
                }
                if lineStr.hasPrefix("▎ ") || (lineStr.hasPrefix("☑ ") && !chunk.contains("☑")) {
                    return .secondaryLabelColor
                }
                return .labelColor
            }()

            var normalizedAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: resolvedFG,
                .paragraphStyle: paragraphStyle
            ]

            if isMono {
                normalizedAttrs[.font] = NSFont.monospacedSystemFont(ofSize: max(11, fontSize - 1), weight: .regular)
                normalizedAttrs[.backgroundColor] = inlineCodeBackgroundColor
            } else {
                normalizedAttrs[.font] = resolvedFont(size: resolvedSize, isBold: isBold, isItalic: isItalic)
                if isItalic {
                    normalizedAttrs[.obliqueness] = NSNumber(value: Double(chineseItalicObliqueness))
                }
                if isYellow {
                    normalizedAttrs[.backgroundColor] = highlightYellowColor
                }
            }

            if underlineRaw != 0 {
                normalizedAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if strikeRaw != 0 {
                normalizedAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }

            result.setAttributes(normalizedAttrs, range: range)
        }
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaceholderNoteTextView
        var lastSyncedPlainText = ""
        private var lastReportedSelection = ""

        init(_ parent: PlaceholderNoteTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderNSTextView else { return }
            textView.processLiveMarkdownIfNeeded()
            syncRichTextAndFormat(from: textView)
            textView.needsDisplay = true
            reportSelection(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderNSTextView else { return }
            reportSelection(for: textView)
            syncFormatState(from: textView)
        }

        func syncRichTextAndFormat(from textView: PlaceholderNSTextView) {
            let plain = textView.string
            lastSyncedPlainText = plain
            if parent.text != plain {
                parent.text = plain
            }
            if parent.isRichTextEnabled {
                let rtf = textView.exportRTFData()
                parent.onRichTextChanged?(plain, rtf)
            }
            syncFormatState(from: textView)
        }

        private func syncFormatState(from textView: PlaceholderNSTextView) {
            guard let controller = parent.formattingController else { return }
            let state = textView.currentFormatState()
            Task { @MainActor in
                if controller.activeFormat != state {
                    controller.activeFormat = state
                }
            }
        }

        private func reportSelection(for textView: NSTextView) {
            guard let onSelectionChanged = parent.onSelectionChanged else { return }
            let selected = textView.currentSelectedSubstring
            if selected != lastReportedSelection {
                lastReportedSelection = selected
                DispatchQueue.main.async {
                    onSelectionChanged(selected)
                }
            }
        }
    }
}

private extension NSTextView {
    var currentSelectedSubstring: String {
        let range = selectedRange()
        guard range.length > 0 else { return "" }
        let nsStr = string as NSString
        guard NSMaxRange(range) <= nsStr.length else { return "" }
        return nsStr.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ensures the underlying `NSTextView` is always at least as tall as the visible scroll viewport
/// so clicking anywhere in an empty note immediately focuses the cursor.
private final class AutoSizingNoteScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let minHeight = contentView.bounds.height
        if abs(textView.minSize.height - minHeight) > 0.5 {
            textView.minSize = NSSize(width: 0, height: minHeight)
            if textView.frame.height < minHeight {
                var frame = textView.frame
                frame.size.height = minHeight
                textView.frame = frame
            }
        }
    }
}

final class PlaceholderNSTextView: NSTextView {
    var placeholderText: String = "" {
        didSet {
            if oldValue != placeholderText { needsDisplay = true }
        }
    }
    var placeholderFont: NSFont = .systemFont(ofSize: 13)
    var placeholderParagraphStyle: NSParagraphStyle = NSParagraphStyle()
    var baseFontSize: CGFloat = 13
    var baseLineSpacing: CGFloat = 3
    var isLiveMarkdownEnabled: Bool = false
    var onSendSelectionToBoard: ((String, Bool) -> Void)?
    var onFormatChanged: (() -> Void)?

    private var isApplyingAutoMarkdown = false

    // MARK: - Live WYSIWYG Markdown Engine (所写即所见)

    func processLiveMarkdownIfNeeded() {
        guard isRichText,
              isLiveMarkdownEnabled,
              !isApplyingAutoMarkdown,
              !hasMarkedText(),
              !(undoManager?.isUndoing ?? false),
              !(undoManager?.isRedoing ?? false),
              let storage = textStorage else {
            return
        }

        let sel = selectedRange()
        guard sel.length == 0, sel.location <= storage.length else { return }

        let nsText = string as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
        let prefixLen = sel.location - lineRange.location
        guard prefixLen > 0 else { return }
        let lineBeforeCaret = nsText.substring(with: NSRange(location: lineRange.location, length: prefixLen))

        isApplyingAutoMarkdown = true
        defer { isApplyingAutoMarkdown = false }

        // 1. Block-level instant transforms triggered on Space at start of line
        if tryApplyBlockMarkdown(lineBeforeCaret: lineBeforeCaret, lineRange: lineRange, caretLocation: sel.location) {
            return
        }

        // 2. Inline instant transforms triggered on closing delimiter
        tryApplyInlineMarkdown(lineBeforeCaret: lineBeforeCaret, lineStart: lineRange.location)
    }

    private func tryApplyBlockMarkdown(lineBeforeCaret: String, lineRange: NSRange, caretLocation: Int) -> Bool {
        guard let storage = textStorage else { return false }
        let clean = PlaceholderNoteTextView.baseAttributes(fontSize: baseFontSize, lineSpacing: baseLineSpacing)
        let prefixRange = NSRange(location: lineRange.location, length: caretLocation - lineRange.location)

        // Headings: "# ", "## ", "### "
        let headingMap: [(String, Int)] = [("### ", 3), ("## ", 2), ("# ", 1)]
        for (trigger, level) in headingMap where lineBeforeCaret == trigger {
            let hAttrs = PlaceholderNoteTextView.headingAttributes(
                level: level,
                baseFontSize: baseFontSize,
                lineSpacing: baseLineSpacing
            )
            if shouldChangeText(in: prefixRange, replacementString: "") {
                storage.replaceCharacters(in: prefixRange, with: "")
                // Also apply heading style to any remaining text on this line
                let updatedLineRange = (string as NSString).lineRange(for: NSRange(location: lineRange.location, length: 0))
                let trimmedLen = ((string as NSString).substring(with: updatedLineRange).trimmingCharacters(in: .newlines) as NSString).length
                if trimmedLen > 0 {
                    storage.setAttributes(hAttrs, range: NSRange(location: updatedLineRange.location, length: trimmedLen))
                }
                didChangeText()
                setSelectedRange(NSRange(location: lineRange.location, length: 0))
                typingAttributes = hAttrs
                return true
            }
        }

        // Unchecked Checkbox: "- [ ] ", "* [ ] ", "[] "
        if lineBeforeCaret == "- [ ] " || lineBeforeCaret == "* [ ] " || lineBeforeCaret == "[] " {
            let replacement = makeCheckboxPrefix(isChecked: false)
            if shouldChangeText(in: prefixRange, replacementString: replacement.string) {
                storage.replaceCharacters(in: prefixRange, with: replacement)
                didChangeText()
                let nextLoc = lineRange.location + replacement.length
                setSelectedRange(NSRange(location: nextLoc, length: 0))
                typingAttributes = clean
                return true
            }
        }

        // Checked Checkbox: "- [x] ", "- [X] "
        if lineBeforeCaret == "- [x] " || lineBeforeCaret == "- [X] " {
            let replacement = makeCheckboxPrefix(isChecked: true)
            if shouldChangeText(in: prefixRange, replacementString: replacement.string) {
                storage.replaceCharacters(in: prefixRange, with: replacement)
                didChangeText()
                let nextLoc = lineRange.location + replacement.length
                setSelectedRange(NSRange(location: nextLoc, length: 0))
                typingAttributes = checkedTextAttributes()
                return true
            }
        }

        // Bullet List: "- ", "* "
        if lineBeforeCaret == "- " || lineBeforeCaret == "* " {
            let bullet = makeBulletPrefix()
            if shouldChangeText(in: prefixRange, replacementString: bullet.string) {
                storage.replaceCharacters(in: prefixRange, with: bullet)
                didChangeText()
                let nextLoc = lineRange.location + bullet.length
                setSelectedRange(NSRange(location: nextLoc, length: 0))
                var listTyping = clean
                let p = NSMutableParagraphStyle()
                p.lineSpacing = baseLineSpacing
                p.headIndent = 13
                listTyping[.paragraphStyle] = p
                typingAttributes = listTyping
                return true
            }
        }

        // Quote Block: "> "
        if lineBeforeCaret == "> " {
            let quote = makeQuotePrefix()
            if shouldChangeText(in: prefixRange, replacementString: quote.string) {
                storage.replaceCharacters(in: prefixRange, with: quote)
                didChangeText()
                let nextLoc = lineRange.location + quote.length
                setSelectedRange(NSRange(location: nextLoc, length: 0))
                typingAttributes = PlaceholderNoteTextView.quoteAttributes(
                    baseFontSize: baseFontSize,
                    lineSpacing: baseLineSpacing
                )
                return true
            }
        }

        // Horizontal Divider: "--- "
        if lineBeforeCaret == "--- " || lineBeforeCaret == "*** " {
            let divider = makeDividerAttributedString(includeTrailingNewline: true)
            if shouldChangeText(in: prefixRange, replacementString: divider.string) {
                storage.replaceCharacters(in: prefixRange, with: divider)
                didChangeText()
                let nextLoc = lineRange.location + divider.length
                setSelectedRange(NSRange(location: nextLoc, length: 0))
                typingAttributes = clean
                return true
            }
        }

        return false
    }

    private func tryApplyInlineMarkdown(lineBeforeCaret: String, lineStart: Int) {
        guard let storage = textStorage else { return }
        let clean = PlaceholderNoteTextView.baseAttributes(fontSize: baseFontSize, lineSpacing: baseLineSpacing)
        let nsLine = lineBeforeCaret as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        enum InlineRule {
            case bold
            case highlight
            case strikethrough
            case inlineCode
            case italic
        }

        let rules: [(String, InlineRule)] = [
            (#"(?<!\*)\*\*([^*\n]+?)\*\*$"#, .bold),
            (#"==([^=\n]+?)==$"#, .highlight),
            (#"~~([^~\n]+?)~~$"#, .strikethrough),
            (#"`([^`\n]+?)`$"#, .inlineCode),
            (#"(?<!\*)\*([^*\s\n](?:[^*\n]*?[^*\s\n])?)\*$"#, .italic)
        ]

        for (pattern, rule) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: lineBeforeCaret, range: fullRange),
                  match.numberOfRanges >= 2 else {
                continue
            }

            let matchRangeInDoc = NSRange(location: lineStart + match.range.location, length: match.range.length)
            let innerText = nsLine.substring(with: match.range(at: 1))
            guard !innerText.isEmpty else { continue }

            var styledAttrs = clean
            switch rule {
            case .bold:
                styledAttrs[.font] = PlaceholderNoteTextView.resolvedFont(size: baseFontSize, isBold: true, isItalic: false)
            case .highlight:
                styledAttrs[.backgroundColor] = PlaceholderNoteTextView.highlightYellowColor
            case .strikethrough:
                styledAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .inlineCode:
                styledAttrs = PlaceholderNoteTextView.inlineCodeAttributes(
                    baseFontSize: baseFontSize,
                    lineSpacing: baseLineSpacing
                )
            case .italic:
                styledAttrs[.font] = PlaceholderNoteTextView.resolvedFont(size: baseFontSize, isBold: false, isItalic: true)
                styledAttrs[.obliqueness] = NSNumber(value: Double(PlaceholderNoteTextView.chineseItalicObliqueness))
            }

            let styled = NSAttributedString(string: innerText, attributes: styledAttrs)
            if shouldChangeText(in: matchRangeInDoc, replacementString: innerText) {
                storage.replaceCharacters(in: matchRangeInDoc, with: styled)
                didChangeText()
                let caretPos = matchRangeInDoc.location + styled.length
                setSelectedRange(NSRange(location: caretPos, length: 0))
                // Reset typingAttributes so subsequent typing is clean body text
                typingAttributes = clean
            }
            return
        }
    }

    // MARK: - Clickable Checkboxes (`☐` <-> `☑`) Right Inside Editor!

    override func mouseDown(with event: NSEvent) {
        if isRichText, tryToggleCheckbox(at: event) {
            return
        }
        super.mouseDown(with: event)
    }

    private func tryToggleCheckbox(at event: NSEvent) -> Bool {
        guard let storage = textStorage,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              storage.length > 0 else {
            return false
        }

        let pointInView = convert(event.locationInWindow, from: nil)
        let pointInContainer = NSPoint(
            x: pointInView.x - textContainerOrigin.x,
            y: pointInView.y - textContainerOrigin.y
        )

        var fraction: CGFloat = 0
        let charIndex = layoutManager.characterIndex(
            for: pointInContainer,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard charIndex < storage.length else { return false }

        let nsStr = string as NSString
        let lineRange = nsStr.lineRange(for: NSRange(location: charIndex, length: 0))
        let lineStr = nsStr.substring(with: lineRange)

        let isUnchecked = lineStr.hasPrefix("☐ ")
        let isChecked = lineStr.hasPrefix("☑ ")
        guard isUnchecked || isChecked else { return false }

        // Only toggle if user clicked directly on the checkbox glyph (index 0 or 1 of the line)
        let offsetInLine = charIndex - lineRange.location
        guard offsetInLine <= 1 else { return false }

        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: lineRange.location, length: 1),
            in: textContainer
        )
        let expandedHitRect = glyphRect.insetBy(dx: -5, dy: -3)
        guard expandedHitRect.contains(pointInContainer) else { return false }

        let nextChecked = isUnchecked
        let symbolRange = NSRange(location: lineRange.location, length: 1)
        let newSymbol = nextChecked ? "☑" : "☐"

        guard shouldChangeText(in: lineRange, replacementString: nil) else { return false }

        storage.beginEditing()
        let symbolAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: baseFontSize + 1),
            .foregroundColor: nextChecked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            .paragraphStyle: checkboxParagraphStyle()
        ]
        storage.replaceCharacters(in: symbolRange, with: NSAttributedString(string: newSymbol, attributes: symbolAttrs))

        let trimmedContentLen = (lineStr.trimmingCharacters(in: .newlines) as NSString).length
        let bodyStart = lineRange.location + 2
        let bodyLen = max(0, trimmedContentLen - 2)
        if bodyLen > 0, bodyStart + bodyLen <= storage.length {
            let bodyRange = NSRange(location: bodyStart, length: bodyLen)
            if nextChecked {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: bodyRange)
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: bodyRange)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: bodyRange)
                storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: bodyRange)
            }
        }
        storage.endEditing()

        didChangeText()
        onFormatChanged?()
        return true
    }

    // MARK: - WYSIWYG Element Builders

    private func checkboxParagraphStyle() -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = baseLineSpacing
        p.headIndent = 16
        return p
    }

    private func makeCheckboxPrefix(isChecked: Bool) -> NSAttributedString {
        let p = checkboxParagraphStyle()
        let result = NSMutableAttributedString(
            string: isChecked ? "☑" : "☐",
            attributes: [
                .font: NSFont.systemFont(ofSize: baseFontSize + 1),
                .foregroundColor: isChecked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                .paragraphStyle: p
            ]
        )
        result.append(NSAttributedString(
            string: " ",
            attributes: [
                .font: NSFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: p
            ]
        ))
        return result
    }

    private func checkedTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: baseFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .paragraphStyle: checkboxParagraphStyle()
        ]
    }

    private func makeBulletPrefix() -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = baseLineSpacing
        p.headIndent = 13
        return NSAttributedString(
            string: "• ",
            attributes: [
                .font: NSFont.systemFont(ofSize: baseFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: p
            ]
        )
    }

    private func makeQuotePrefix() -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = baseLineSpacing
        p.headIndent = 14
        let res = NSMutableAttributedString(
            string: "▎",
            attributes: [
                .font: NSFont.systemFont(ofSize: baseFontSize, weight: .bold),
                .foregroundColor: NSColor.controlAccentColor,
                .paragraphStyle: p
            ]
        )
        res.append(NSAttributedString(
            string: " ",
            attributes: [
                .font: NSFont.systemFont(ofSize: baseFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: p
            ]
        ))
        return res
    }

    private func makeDividerAttributedString(includeTrailingNewline: Bool) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = baseLineSpacing
        p.paragraphSpacingBefore = 2
        p.paragraphSpacing = 2
        let text = NoteMarkdownConverter.dividerLineText + (includeTrailingNewline ? "\n" : "")
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: max(10, baseFontSize - 2)),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: p
            ]
        )
    }

    // MARK: - Rich Text Formatting Engine

    func currentFormatState() -> NoteFormatState {
        guard isRichText, let storage = textStorage else {
            return NoteFormatState()
        }
        let range = selectedRange()
        let attrs: [NSAttributedString.Key: Any]
        if range.length > 0, range.location < storage.length {
            attrs = storage.attributes(at: range.location, effectiveRange: nil)
        } else {
            attrs = typingAttributes
        }
        return formatState(from: attrs)
    }

    private func formatState(from attrs: [NSAttributedString.Key: Any]) -> NoteFormatState {
        let font = attrs[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        let isMono = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
        let isBold = traits.contains(.boldFontMask)
        let obliq = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
        let isItalic = traits.contains(.italicFontMask) || obliq > 0.05
        let isUnderlined = ((attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        let isStrikethrough = ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
        let isHighlighted = NoteMarkdownConverter.isYellowHighlightColor(attrs[.backgroundColor] as? NSColor)

        let headingLevel: Int = {
            guard let pt = font?.pointSize else { return 0 }
            if pt >= baseFontSize + 4.5 { return 1 }
            if pt >= baseFontSize + 2.2 { return 2 }
            if pt >= baseFontSize + 1.0 { return 3 }
            return 0
        }()

        return NoteFormatState(
            isBold: isBold && headingLevel == 0,
            isItalic: isItalic,
            isHighlighted: isHighlighted,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isInlineCode: isMono,
            headingLevel: headingLevel
        )
    }

    func applyFormatAction(_ action: NoteFormatAction) {
        guard isRichText, let storage = textStorage else { return }

        if case .insertMarkdown(let snippet) = action {
            applyWYSIWYGSnippet(snippet)
            return
        }

        let range = selectedRange()
        if range.length == 0 {
            if case .clearFormatting = action {
                typingAttributes = PlaceholderNoteTextView.baseAttributes(
                    fontSize: baseFontSize,
                    lineSpacing: baseLineSpacing
                )
                onFormatChanged?()
                return
            }

            var attrs = typingAttributes
            if attrs[.font] == nil {
                attrs = PlaceholderNoteTextView.baseAttributes(fontSize: baseFontSize, lineSpacing: baseLineSpacing)
            }
            let current = formatState(from: attrs)
            let activeSize = (attrs[.font] as? NSFont)?.pointSize ?? baseFontSize

            switch action {
            case .toggleBold:
                attrs[.font] = PlaceholderNoteTextView.resolvedFont(
                    size: activeSize,
                    isBold: !current.isBold,
                    isItalic: current.isItalic
                )
            case .toggleItalic:
                let nextItalic = !current.isItalic
                attrs[.font] = PlaceholderNoteTextView.resolvedFont(
                    size: activeSize,
                    isBold: current.isBold || current.headingLevel > 0,
                    isItalic: nextItalic
                )
                if nextItalic {
                    attrs[.obliqueness] = NSNumber(value: Double(PlaceholderNoteTextView.chineseItalicObliqueness))
                } else {
                    attrs.removeValue(forKey: .obliqueness)
                }
            case .toggleUnderline:
                if current.isUnderlined {
                    attrs.removeValue(forKey: .underlineStyle)
                } else {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
            case .toggleStrikethrough:
                if current.isStrikethrough {
                    attrs.removeValue(forKey: .strikethroughStyle)
                } else {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            case .toggleHighlight:
                if current.isHighlighted {
                    attrs.removeValue(forKey: .backgroundColor)
                } else {
                    attrs[.backgroundColor] = PlaceholderNoteTextView.highlightYellowColor
                }
            case .clearFormatting, .insertMarkdown:
                break
            }
            attrs[.foregroundColor] = NSColor.labelColor
            typingAttributes = attrs
            onFormatChanged?()
            return
        }

        // Toggle across selected range (supports UndoManager)
        let current = currentFormatState()
        let enable: Bool
        switch action {
        case .toggleBold: enable = !current.isBold
        case .toggleItalic: enable = !current.isItalic
        case .toggleUnderline: enable = !current.isUnderlined
        case .toggleStrikethrough: enable = !current.isStrikethrough
        case .toggleHighlight: enable = !current.isHighlighted
        case .clearFormatting, .insertMarkdown: enable = false
        }

        guard shouldChangeText(in: range, replacementString: nil) else { return }

        storage.beginEditing()
        switch action {
        case .toggleBold:
            storage.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
                let st = formatState(from: attrs)
                let pt = (attrs[.font] as? NSFont)?.pointSize ?? baseFontSize
                let newFont = PlaceholderNoteTextView.resolvedFont(
                    size: pt,
                    isBold: enable,
                    isItalic: st.isItalic
                )
                storage.addAttribute(.font, value: newFont, range: subRange)
            }

        case .toggleItalic:
            storage.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
                let st = formatState(from: attrs)
                let pt = (attrs[.font] as? NSFont)?.pointSize ?? baseFontSize
                let newFont = PlaceholderNoteTextView.resolvedFont(
                    size: pt,
                    isBold: st.isBold || st.headingLevel > 0,
                    isItalic: enable
                )
                storage.addAttribute(.font, value: newFont, range: subRange)
                if enable {
                    storage.addAttribute(
                        .obliqueness,
                        value: NSNumber(value: Double(PlaceholderNoteTextView.chineseItalicObliqueness)),
                        range: subRange
                    )
                } else {
                    storage.removeAttribute(.obliqueness, range: subRange)
                }
            }

        case .toggleUnderline:
            if enable {
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                storage.removeAttribute(.underlineStyle, range: range)
            }

        case .toggleStrikethrough:
            if enable {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: range)
            }

        case .toggleHighlight:
            if enable {
                storage.addAttribute(.backgroundColor, value: PlaceholderNoteTextView.highlightYellowColor, range: range)
            } else {
                storage.removeAttribute(.backgroundColor, range: range)
            }

        case .clearFormatting:
            let clean = PlaceholderNoteTextView.baseAttributes(fontSize: baseFontSize, lineSpacing: baseLineSpacing)
            storage.setAttributes(clean, range: range)

        case .insertMarkdown:
            break
        }
        storage.endEditing()

        didChangeText()
        if range.location < storage.length {
            var synced = storage.attributes(at: range.location, effectiveRange: nil)
            synced[.foregroundColor] = NSColor.labelColor
            typingAttributes = synced
        }
        onFormatChanged?()
    }

    private func applyWYSIWYGSnippet(_ snippet: MarkdownSnippet) {
        guard let storage = textStorage else { return }
        let clean = PlaceholderNoteTextView.baseAttributes(fontSize: baseFontSize, lineSpacing: baseLineSpacing)
        let sel = selectedRange()
        let nsText = string as NSString
        let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineContentLen = (nsText.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString).length

        isApplyingAutoMarkdown = true
        defer { isApplyingAutoMarkdown = false }

        switch snippet {
        case .heading1, .heading2, .heading3:
            let level = snippet == .heading1 ? 1 : (snippet == .heading2 ? 2 : 3)
            let hAttrs = PlaceholderNoteTextView.headingAttributes(
                level: level,
                baseFontSize: baseFontSize,
                lineSpacing: baseLineSpacing
            )
            if lineContentLen > 0 {
                let targetRange = NSRange(location: lineRange.location, length: lineContentLen)
                if shouldChangeText(in: targetRange, replacementString: nil) {
                    storage.setAttributes(hAttrs, range: targetRange)
                    didChangeText()
                }
            }
            typingAttributes = hAttrs
            onFormatChanged?()

        case .checkbox:
            let prefix = makeCheckboxPrefix(isChecked: false)
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if shouldChangeText(in: insertRange, replacementString: prefix.string) {
                storage.insert(prefix, at: lineRange.location)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + prefix.length, length: sel.length))
                typingAttributes = clean
                onFormatChanged?()
            }

        case .bullet:
            let prefix = makeBulletPrefix()
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if shouldChangeText(in: insertRange, replacementString: prefix.string) {
                storage.insert(prefix, at: lineRange.location)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + prefix.length, length: sel.length))
                typingAttributes = clean
                onFormatChanged?()
            }

        case .quote:
            let prefix = makeQuotePrefix()
            let insertRange = NSRange(location: lineRange.location, length: 0)
            let qAttrs = PlaceholderNoteTextView.quoteAttributes(baseFontSize: baseFontSize, lineSpacing: baseLineSpacing)
            if shouldChangeText(in: insertRange, replacementString: prefix.string) {
                storage.insert(prefix, at: lineRange.location)
                if lineContentLen > 0 {
                    storage.setAttributes(qAttrs, range: NSRange(location: lineRange.location + prefix.length, length: lineContentLen))
                }
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + prefix.length, length: sel.length))
                typingAttributes = qAttrs
                onFormatChanged?()
            }

        case .inlineCode:
            let codeAttrs = PlaceholderNoteTextView.inlineCodeAttributes(
                baseFontSize: baseFontSize,
                lineSpacing: baseLineSpacing
            )
            if sel.length > 0 {
                if shouldChangeText(in: sel, replacementString: nil) {
                    storage.setAttributes(codeAttrs, range: sel)
                    didChangeText()
                    typingAttributes = clean
                    onFormatChanged?()
                }
            } else {
                let current = currentFormatState()
                typingAttributes = current.isInlineCode ? clean : codeAttrs
                onFormatChanged?()
            }

        case .divider:
            let isAtLineStart = sel.location == lineRange.location
            let result = NSMutableAttributedString()
            if !isAtLineStart {
                result.append(NSAttributedString(string: "\n", attributes: clean))
            }
            result.append(makeDividerAttributedString(includeTrailingNewline: true))
            if shouldChangeText(in: sel, replacementString: result.string) {
                storage.replaceCharacters(in: sel, with: result)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + result.length, length: 0))
                typingAttributes = clean
                onFormatChanged?()
            }
        }
    }

    func exportRTFData() -> Data? {
        guard isRichText, let storage = textStorage, storage.length > 0 else {
            return nil
        }
        return try? storage.data(
            from: NSRange(location: 0, length: storage.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    // MARK: - Smart Newline & Backspace

    override func deleteBackward(_ sender: Any?) {
        if isRichText {
            let sel = selectedRange()
            if sel.length == 0 {
                let nsText = string as NSString
                let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
                let lineTrimmed = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)
                // If pressing Backspace on an empty heading line, revert to regular body text first
                if lineTrimmed.isEmpty && currentFormatState().headingLevel > 0 {
                    typingAttributes = PlaceholderNoteTextView.baseAttributes(
                        fontSize: baseFontSize,
                        lineSpacing: baseLineSpacing
                    )
                    onFormatChanged?()
                    return
                }
            }
        }
        super.deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        guard isRichText else {
            super.insertNewline(sender)
            return
        }

        let cleanAttrs = PlaceholderNoteTextView.baseAttributes(
            fontSize: baseFontSize,
            lineSpacing: baseLineSpacing
        )

        let sel = selectedRange()
        if sel.length == 0 {
            let nsText = string as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
            let lineBeforeCaret = nsText.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))

            // Convert "---" + Enter into visual divider when live Markdown is enabled
            if isLiveMarkdownEnabled && (lineBeforeCaret == "---" || lineBeforeCaret == "***") {
                let target = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
                let divider = makeDividerAttributedString(includeTrailingNewline: true)
                if shouldChangeText(in: target, replacementString: divider.string) {
                    isApplyingAutoMarkdown = true
                    textStorage?.replaceCharacters(in: target, with: divider)
                    isApplyingAutoMarkdown = false
                    didChangeText()
                    setSelectedRange(NSRange(location: lineRange.location + divider.length, length: 0))
                    typingAttributes = cleanAttrs
                    onFormatChanged?()
                    return
                }
            }

            // Checklist continuation (`☐ ` / `☑ `)
            if lineBeforeCaret.hasPrefix("☐ ") || lineBeforeCaret.hasPrefix("☑ ") {
                let remainder = String(lineBeforeCaret.dropFirst(2))
                if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    let removeRange = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
                    if shouldChangeText(in: removeRange, replacementString: "") {
                        textStorage?.replaceCharacters(in: removeRange, with: "")
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onFormatChanged?()
                        return
                    }
                } else {
                    super.insertNewline(sender)
                    let nextBox = makeCheckboxPrefix(isChecked: false)
                    let insertPos = selectedRange()
                    if shouldChangeText(in: insertPos, replacementString: nextBox.string) {
                        textStorage?.replaceCharacters(in: insertPos, with: nextBox)
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onFormatChanged?()
                        return
                    }
                }
            }

            // Quote exit on empty `▎ `
            if lineBeforeCaret.hasPrefix("▎ ") {
                let remainder = String(lineBeforeCaret.dropFirst(2))
                if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    let removeRange = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
                    if shouldChangeText(in: removeRange, replacementString: "") {
                        textStorage?.replaceCharacters(in: removeRange, with: "")
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onFormatChanged?()
                        return
                    }
                }
            }

            // Bullet list continuation (`• ` / `- ` / `* ` / `- [ ] `)
            let listPrefixes = ["- [ ] ", "• ", "- ", "* "]
            if let matchedPrefix = listPrefixes.first(where: { lineBeforeCaret.hasPrefix($0) }) {
                let remainder = String(lineBeforeCaret.dropFirst(matchedPrefix.count))
                if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    let removeRange = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
                    if shouldChangeText(in: removeRange, replacementString: "") {
                        textStorage?.replaceCharacters(in: removeRange, with: "")
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onFormatChanged?()
                        return
                    }
                } else {
                    super.insertNewline(sender)
                    typingAttributes = cleanAttrs
                    let insertPos = selectedRange()
                    let attrPrefix = matchedPrefix == "• "
                        ? makeBulletPrefix()
                        : NSAttributedString(string: matchedPrefix, attributes: cleanAttrs)
                    if shouldChangeText(in: insertPos, replacementString: attrPrefix.string) {
                        textStorage?.replaceCharacters(in: insertPos, with: attrPrefix)
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onFormatChanged?()
                        return
                    }
                }
            } else if let regex = try? NSRegularExpression(pattern: #"^(\d+)\.\s+"#),
                      let match = regex.firstMatch(
                          in: lineBeforeCaret,
                          range: NSRange(location: 0, length: (lineBeforeCaret as NSString).length)
                      ) {
                let nsLine = lineBeforeCaret as NSString
                let numStr = nsLine.substring(with: match.range(at: 1))
                let prefixLen = match.range.length
                let remainder = nsLine.substring(from: prefixLen)
                if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    let removeRange = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
                    if shouldChangeText(in: removeRange, replacementString: "") {
                        textStorage?.replaceCharacters(in: removeRange, with: "")
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onFormatChanged?()
                        return
                    }
                } else if let num = Int(numStr) {
                    let nextPrefix = "\(num + 1). "
                    super.insertNewline(sender)
                    typingAttributes = cleanAttrs
                    let insertPos = selectedRange()
                    if shouldChangeText(in: insertPos, replacementString: nextPrefix) {
                        textStorage?.replaceCharacters(
                            in: insertPos,
                            with: NSAttributedString(string: nextPrefix, attributes: cleanAttrs)
                        )
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onFormatChanged?()
                        return
                    }
                }
            }
        }

        // Standard newline: reset typingAttributes so heading / yellow highlight / bold / underline don't bleed
        super.insertNewline(sender)
        typingAttributes = cleanAttrs
        onFormatChanged?()
    }

    // MARK: - Keyboard Shortcuts & Clean Paste

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRichText, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == .command {
            switch key {
            case "b":
                applyFormatAction(.toggleBold)
                return true
            case "i":
                applyFormatAction(.toggleItalic)
                return true
            case "u":
                applyFormatAction(.toggleUnderline)
                return true
            case "\\":
                applyFormatAction(.clearFormatting)
                return true
            default:
                break
            }
        } else if flags == [.command, .shift] {
            switch key {
            case "h":
                applyFormatAction(.toggleHighlight)
                return true
            case "x":
                applyFormatAction(.toggleStrikethrough)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if isRichText {
            pasteAsPlainText(sender)
        } else {
            super.paste(sender)
        }
    }

    // MARK: - Placeholder Drawing & Context Menu

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !hasMarkedText(), !placeholderText.isEmpty else { return }

        let origin = textContainerOrigin
        let linePad = textContainer?.lineFragmentPadding ?? 0
        let drawRect = NSRect(
            x: origin.x + linePad,
            y: origin.y,
            width: max(0, bounds.width - (origin.x + linePad) * 2),
            height: max(0, bounds.height - origin.y * 2)
        )

        let attrs: [NSAttributedString.Key: Any] = [
            .font: placeholderFont,
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: placeholderParagraphStyle
        ]
        NSAttributedString(string: placeholderText, attributes: attrs).draw(in: drawRect)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event) ?? NSMenu()
        let selected = currentSelectedSubstring
        var insertIndex = 0

        if onSendSelectionToBoard != nil, !selected.isEmpty {
            let lines = selected
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if !lines.isEmpty {
                let singleTitle = lines.count > 1 ? "合并为 1 条任务添加到规划板" : "添加到规划板"
                let singleItem = NSMenuItem(
                    title: singleTitle,
                    action: #selector(handleSendSelectionSingle),
                    keyEquivalent: ""
                )
                singleItem.target = self
                singleItem.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
                baseMenu.insertItem(singleItem, at: insertIndex)
                insertIndex += 1

                if lines.count > 1 {
                    let splitItem = NSMenuItem(
                        title: "按行拆分为 \(lines.count) 条任务添加到规划板",
                        action: #selector(handleSendSelectionSplit),
                        keyEquivalent: ""
                    )
                    splitItem.target = self
                    splitItem.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
                    baseMenu.insertItem(splitItem, at: insertIndex)
                    insertIndex += 1
                }

                baseMenu.insertItem(.separator(), at: insertIndex)
                insertIndex += 1
            }
        }

        if isRichText && selectedRange().length > 0 {
            let state = currentFormatState()
            let styleSubmenu = NSMenu(title: "文字样式")

            let boldItem = NSMenuItem(title: "加粗", action: #selector(handleMenuBold), keyEquivalent: "b")
            boldItem.target = self
            boldItem.state = state.isBold ? .on : .off
            boldItem.image = NSImage(systemSymbolName: "bold", accessibilityDescription: nil)
            styleSubmenu.addItem(boldItem)

            let italicItem = NSMenuItem(title: "斜体", action: #selector(handleMenuItalic), keyEquivalent: "i")
            italicItem.target = self
            italicItem.state = state.isItalic ? .on : .off
            italicItem.image = NSImage(systemSymbolName: "italic", accessibilityDescription: nil)
            styleSubmenu.addItem(italicItem)

            let underlineItem = NSMenuItem(title: "下划线", action: #selector(handleMenuUnderline), keyEquivalent: "u")
            underlineItem.target = self
            underlineItem.state = state.isUnderlined ? .on : .off
            underlineItem.image = NSImage(systemSymbolName: "underline", accessibilityDescription: nil)
            styleSubmenu.addItem(underlineItem)

            let strikeItem = NSMenuItem(title: "删除线", action: #selector(handleMenuStrikethrough), keyEquivalent: "X")
            strikeItem.target = self
            strikeItem.state = state.isStrikethrough ? .on : .off
            strikeItem.image = NSImage(systemSymbolName: "strikethrough", accessibilityDescription: nil)
            styleSubmenu.addItem(strikeItem)

            let highlightItem = NSMenuItem(title: "标黄高亮", action: #selector(handleMenuHighlight), keyEquivalent: "H")
            highlightItem.target = self
            highlightItem.state = state.isHighlighted ? .on : .off
            highlightItem.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
            styleSubmenu.addItem(highlightItem)

            let codeItem = NSMenuItem(title: "行内代码", action: #selector(handleMenuInlineCode), keyEquivalent: "")
            codeItem.target = self
            codeItem.state = state.isInlineCode ? .on : .off
            codeItem.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
            styleSubmenu.addItem(codeItem)

            styleSubmenu.addItem(.separator())

            let clearItem = NSMenuItem(title: "清除样式", action: #selector(handleMenuClearFormatting), keyEquivalent: "\\")
            clearItem.target = self
            clearItem.image = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil)
            styleSubmenu.addItem(clearItem)

            let styleRoot = NSMenuItem(title: "文字样式", action: nil, keyEquivalent: "")
            styleRoot.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: nil)
            styleRoot.submenu = styleSubmenu
            baseMenu.insertItem(styleRoot, at: insertIndex)
            insertIndex += 1

            baseMenu.insertItem(.separator(), at: insertIndex)
        }

        return baseMenu
    }

    @objc private func handleSendSelectionSingle() {
        let selected = currentSelectedSubstring
        guard !selected.isEmpty else { return }
        onSendSelectionToBoard?(selected, false)
    }

    @objc private func handleSendSelectionSplit() {
        let selected = currentSelectedSubstring
        guard !selected.isEmpty else { return }
        onSendSelectionToBoard?(selected, true)
    }

    @objc private func handleMenuBold() { applyFormatAction(.toggleBold) }
    @objc private func handleMenuItalic() { applyFormatAction(.toggleItalic) }
    @objc private func handleMenuHighlight() { applyFormatAction(.toggleHighlight) }
    @objc private func handleMenuUnderline() { applyFormatAction(.toggleUnderline) }
    @objc private func handleMenuStrikethrough() { applyFormatAction(.toggleStrikethrough) }
    @objc private func handleMenuInlineCode() { applyFormatAction(.insertMarkdown(.inlineCode)) }
    @objc private func handleMenuClearFormatting() { applyFormatAction(.clearFormatting) }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
