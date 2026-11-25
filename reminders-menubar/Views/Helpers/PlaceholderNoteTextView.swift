import Cocoa
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Inline Note Image Attachment (Responsive Rounded Thumbnail, Disk-Backed)

private func computeResponsiveImageBounds(
    naturalSize: NSSize,
    lineFragmentWidth: CGFloat
) -> NSRect {
    let safeW = naturalSize.width > 0 ? naturalSize.width : 240
    let safeH = naturalSize.height > 0 ? naturalSize.height : 160
    let aspect = safeH / max(1, safeW)
    let maxW = max(80, lineFragmentWidth - 14)
    let maxH: CGFloat = lineFragmentWidth < 320 ? 220 : 340
    var targetW = min(safeW, maxW)
    var targetH = targetW * aspect
    if targetH > maxH {
        targetH = maxH
        targetW = max(48, targetH / max(0.01, aspect))
    }
    return NSRect(x: 0, y: -4, width: floor(targetW), height: floor(targetH))
}

final class NoteImageAttachmentCell: NSTextAttachmentCell {
    let fileName: String
    private let naturalSize: NSSize

    init(image: NSImage, fileName: String) {
        self.fileName = fileName
        self.naturalSize = (image.size.width > 0 && image.size.height > 0)
            ? image.size
            : NSSize(width: 240, height: 160)
        super.init(imageCell: image)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cellSize() -> NSSize {
        computeResponsiveImageBounds(naturalSize: naturalSize, lineFragmentWidth: 320).size
    }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        computeResponsiveImageBounds(naturalSize: naturalSize, lineFragmentWidth: lineFrag.width)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image = self.image else { return }
        let insetFrame = cellFrame.insetBy(dx: 0.5, dy: 2)
        guard insetFrame.width > 2, insetFrame.height > 2 else { return }

        NSGraphicsContext.saveGraphicsState()
        let clipPath = NSBezierPath(roundedRect: insetFrame, xRadius: 7, yRadius: 7)
        clipPath.addClip()
        image.draw(
            in: insetFrame,
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        let borderPath = NSBezierPath(roundedRect: insetFrame, xRadius: 7, yRadius: 7)
        borderPath.lineWidth = 0.75
        borderPath.stroke()
    }
}

final class NoteImageTextAttachment: NSTextAttachment {
    let fileName: String
    let originalImage: NSImage

    init(fileName: String, image: NSImage) {
        self.fileName = fileName
        self.originalImage = image
        super.init(data: nil, ofType: nil)
        self.image = image
        self.attachmentCell = NoteImageAttachmentCell(image: image, fileName: fileName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        computeResponsiveImageBounds(naturalSize: originalImage.size, lineFragmentWidth: lineFrag.width)
    }
}

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
    case insertImage(NSImage, Data?)
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
    var allowImageAttachments: Bool = false
    var isActive: Bool = true
    var noteRevision: Int = 0
    var editorId: UUID = UUID()
    var lastEditOriginId: UUID? = nil
    var initialRTFData: Data? = nil
    var initialImageFileNames: [String] = []
    var formattingController: NoteFormattingController? = nil
    var imageLoader: ((String) -> NSImage?)? = nil
    var imageURLResolver: ((String) -> URL?)? = nil
    var onStoreImage: ((NSImage, Data?) -> (fileName: String, image: NSImage)?)? = nil
    var onRichTextChanged: ((String, Data?) -> Void)? = nil
    var onRichContentChanged: ((String, Data?, [String]) -> Void)? = nil
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
        textView.allowImageAttachments = isRichTextEnabled && allowImageAttachments
        textView.importsGraphics = false
        if isRichTextEnabled && allowImageAttachments {
            textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        }
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
        textView.onStoreImage = onStoreImage
        textView.imageURLResolver = imageURLResolver
        textView.onTypingFormatChanged = { [weak coordinator = context.coordinator, weak textView] in
            guard let textView else { return }
            coordinator?.syncFormatState(from: textView)
        }

        if isRichTextEnabled, let rtf = initialRTFData,
           let normalized = Self.normalizedAttributedString(
               fromRTF: rtf,
               imageFileNames: initialImageFileNames,
               fontSize: fontSize,
               lineSpacing: lineSpacing,
               imageLoader: imageLoader
           ) {
            textView.textStorage?.setAttributedString(normalized)
        } else {
            let baseAttrs = Self.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttrs))
        }
        context.coordinator.lastSyncedPlainText = text
        context.coordinator.lastSyncedRevision = noteRevision

        textView.typingAttributes = Self.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
        formattingController?.textView = textView
        context.coordinator.syncFormatState(from: textView)

        scrollView.documentView = textView
        scrollView.isHidden = !isActive
        textView.isTabActive = isActive
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? PlaceholderNSTextView else { return }
        textView.delegate = nil
        textView.onTypingFormatChanged = nil
        textView.onSendSelectionToBoard = nil
        textView.onStoreImage = nil
        textView.imageURLResolver = nil
        if coordinator.parent.formattingController?.textView === textView {
            coordinator.parent.formattingController?.textView = nil
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PlaceholderNSTextView else { return }

        let shouldBeHidden = !isActive
        if scrollView.isHidden != shouldBeHidden || textView.isTabActive != isActive {
            if !isActive, textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
            scrollView.isHidden = shouldBeHidden
            textView.isTabActive = isActive
            scrollView.window?.invalidateCursorRects(for: scrollView)
            textView.window?.invalidateCursorRects(for: textView)
        }

        textView.baseFontSize = fontSize
        textView.baseLineSpacing = lineSpacing
        textView.isLiveMarkdownEnabled = isRichTextEnabled && isLiveMarkdownEnabled
        textView.allowImageAttachments = isRichTextEnabled && allowImageAttachments
        applyBaseConfiguration(to: textView)
        textView.onSendSelectionToBoard = onSendSelectionToBoard
        textView.onStoreImage = onStoreImage
        textView.imageURLResolver = imageURLResolver
        formattingController?.textView = textView

        // Never overwrite while user is composing with IME (e.g. Chinese Pinyin)
        guard !textView.hasMarkedText() else { return }

        if isRichTextEnabled {
            if lastEditOriginId == editorId {
                context.coordinator.lastSyncedPlainText = text
                context.coordinator.lastSyncedRevision = noteRevision
                return
            }

            // Skip redundant RTF decoding & layout for hidden paired editors (e.g. background mini/main panel);
            // when `isActive` turns true, `updateNSView` fires again and syncs the latest revision immediately.
            guard isActive else { return }

            let needsExternalSync = (noteRevision != context.coordinator.lastSyncedRevision)
                || (text != context.coordinator.lastSyncedPlainText)
            guard needsExternalSync else { return }

            let savedSelection = textView.selectedRanges
            if let rtf = initialRTFData,
               let normalized = Self.normalizedAttributedString(
                   fromRTF: rtf,
                   imageFileNames: initialImageFileNames,
                   fontSize: fontSize,
                   lineSpacing: lineSpacing,
                   imageLoader: imageLoader
               ) {
                textView.textStorage?.setAttributedString(normalized)
            } else {
                let baseAttrs = Self.baseAttributes(fontSize: fontSize, lineSpacing: lineSpacing)
                textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: baseAttrs))
            }
            context.coordinator.lastSyncedPlainText = text
            context.coordinator.lastSyncedRevision = noteRevision

            let maxLen = textView.textStorage?.length ?? 0
            let clamped = savedSelection.compactMap { value -> NSValue? in
                let r = value.rangeValue
                let loc = min(r.location, maxLen)
                let len = min(r.length, maxLen - loc)
                return NSValue(range: NSRange(location: loc, length: len))
            }
            if !clamped.isEmpty {
                textView.selectedRanges = clamped
            }
            context.coordinator.syncFormatState(from: textView)
            textView.needsDisplay = true
        } else if textView.string != text {
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

        guard !textView.hasMarkedText() else { return }

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

    /// Normalizes line endings and removes control/attachment sentinel characters that mutate or disappear
    /// during RTF round-trips (`\r\n`, `\r`, `\u{2029}`, `\0`, `\u{FFFC}`, `\u{E000}`), keeping plain text and RTF identical.
    static func sanitizedPlainTextForInsertion(_ raw: String) -> String {
        // Inspect Unicode scalars (not Swift Characters, where `\r\n` is a single grapheme cluster != `\r`).
        let needsSanitization = raw.unicodeScalars.contains { scalar in
            scalar == "\r" || scalar == "\u{2029}" || scalar == "\0" || scalar == "\u{FFFC}" || scalar == "\u{E000}"
        }
        guard needsSanitization else { return raw }

        var output = String()
        output.unicodeScalars.reserveCapacity(raw.unicodeScalars.count)
        var previousWasCR = false
        for scalar in raw.unicodeScalars {
            if scalar == "\r" {
                output.unicodeScalars.append("\n")
                previousWasCR = true
                continue
            }
            if scalar == "\n", previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = false
            if scalar == "\u{2029}" {
                output.unicodeScalars.append("\n")
            } else if scalar == "\0" || scalar == "\u{FFFC}" || scalar == "\u{E000}" {
                continue
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    static func normalizedAttributedString(
        fromRTF data: Data,
        imageFileNames: [String] = [],
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        imageLoader: ((String) -> NSImage?)? = nil
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
        let defaultParagraphStyle = NSMutableParagraphStyle()
        defaultParagraphStyle.lineSpacing = lineSpacing
        let monoFont = NSFont.monospacedSystemFont(ofSize: max(11, fontSize - 1), weight: .regular)

        struct FontKey: Hashable {
            let sizeTenths: Int
            let isBold: Bool
            let isItalic: Bool
        }
        var fontCache: [FontKey: NSFont] = [:]
        func cachedFont(size: CGFloat, isBold: Bool, isItalic: Bool) -> NSFont {
            let key = FontKey(sizeTenths: Int((size * 10).rounded()), isBold: isBold, isItalic: isItalic)
            if let hit = fontCache[key] { return hit }
            let created = resolvedFont(size: size, isBold: isBold, isItalic: isItalic)
            fontCache[key] = created
            return created
        }

        struct FontTraitsSummary {
            let isMono: Bool
            let isBold: Bool
            let isItalic: Bool
            let pointSize: CGFloat
        }
        var traitsCache: [ObjectIdentifier: FontTraitsSummary] = [:]
        func fontSummary(for font: NSFont) -> FontTraitsSummary {
            let id = ObjectIdentifier(font)
            if let hit = traitsCache[id] { return hit }
            let traits = NSFontManager.shared.traits(of: font)
            let summary = FontTraitsSummary(
                isMono: font.fontDescriptor.symbolicTraits.contains(.monoSpace),
                isBold: traits.contains(.boldFontMask),
                isItalic: traits.contains(.italicFontMask),
                pointSize: font.pointSize
            )
            traitsCache[id] = summary
            return summary
        }

        // Cache line-level prefix flags so multi-run lines (e.g. mixed CJK/ASCII) stay strictly O(N).
        var cachedLineEnd = -1
        var isDividerLine = false
        var isQuoteLine = false
        var isCheckedLine = false

        result.beginEditing()
        decoded.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            let summary = (attrs[.font] as? NSFont).map(fontSummary(for:))
            let bgColor = attrs[.backgroundColor] as? NSColor
            let isYellow = NoteMarkdownConverter.isYellowHighlightColor(bgColor)
            let isInlineCode = (summary?.isMono ?? false) || NoteMarkdownConverter.isInlineCodeBackgroundColor(bgColor)
            let isBold = summary?.isBold ?? false
            let obliq = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
            let isItalic = (summary?.isItalic ?? false) || obliq > 0.05
            let underlineRaw = (attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0
            let strikeRaw = (attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0

            let paragraphStyle: NSParagraphStyle
            if let oldPara = attrs[.paragraphStyle] as? NSParagraphStyle,
               oldPara.headIndent != 0
                || oldPara.firstLineHeadIndent != 0
                || oldPara.paragraphSpacingBefore != 0
                || oldPara.paragraphSpacing != 0 {
                let customPara = NSMutableParagraphStyle()
                customPara.lineSpacing = lineSpacing
                customPara.headIndent = oldPara.headIndent
                customPara.firstLineHeadIndent = oldPara.firstLineHeadIndent
                customPara.paragraphSpacingBefore = oldPara.paragraphSpacingBefore
                customPara.paragraphSpacing = oldPara.paragraphSpacing
                paragraphStyle = customPara
            } else {
                paragraphStyle = defaultParagraphStyle
            }

            // Split multi-line runs along line boundaries so line-level styling (dividers, quotes,
            // checked items) never bleeds onto subsequent paragraphs.
            let runEnd = NSMaxRange(range)
            var segStart = range.location
            while segStart < runEnd {
                if segStart >= cachedLineEnd {
                    let lineRange = nsStr.lineRange(for: NSRange(location: segStart, length: 0))
                    cachedLineEnd = NSMaxRange(lineRange)
                    let prefixLen = min(4, lineRange.length)
                    let linePrefix = prefixLen > 0
                        ? nsStr.substring(with: NSRange(location: lineRange.location, length: prefixLen))
                        : ""
                    isDividerLine = linePrefix.hasPrefix("────")
                    isQuoteLine = linePrefix.hasPrefix("▎ ")
                    isCheckedLine = linePrefix.hasPrefix("☑ ")
                }

                let segEnd = min(runEnd, cachedLineEnd)
                let segRange = NSRange(location: segStart, length: segEnd - segStart)

                let trimmedChunk: String = {
                    guard segRange.length <= 16 else { return "" }
                    return nsStr.substring(with: segRange).trimmingCharacters(in: .whitespaces)
                }()
                let isCheckboxGlyph = trimmedChunk == "☐" || trimmedChunk == "☑"

                // Preserve heading sizes across Mini (12.5pt) and Full (13.0pt) windows while keeping
                // checkbox glyphs (13.3 / 13.8pt) strictly distinct from H3 (14.0 / 14.5pt).
                let resolvedSize: CGFloat = {
                    if isCheckboxGlyph { return fontSize + 0.8 }
                    guard let pt = summary?.pointSize else { return fontSize }
                    if pt >= 17.5 || pt >= fontSize + 4.5 { return fontSize + 5.5 }
                    if pt >= 15.0 || pt >= fontSize + 2.2 { return fontSize + 3.0 }
                    if pt >= 13.9 || pt >= fontSize + 1.2 { return fontSize + 1.5 }
                    return fontSize
                }()

                let resolvedFG: NSColor = {
                    if trimmedChunk == "▎" || trimmedChunk == "☑" {
                        return .controlAccentColor
                    }
                    if trimmedChunk == "☐" {
                        return .secondaryLabelColor
                    }
                    if isDividerLine {
                        return .tertiaryLabelColor
                    }
                    if isQuoteLine {
                        return .secondaryLabelColor
                    }
                    if isCheckedLine {
                        let chunkHasCheckedGlyph = segRange.length <= 16
                            ? trimmedChunk.contains("☑")
                            : nsStr.range(of: "☑", options: [], range: segRange).location != NSNotFound
                        if !chunkHasCheckedGlyph {
                            return .secondaryLabelColor
                        }
                    }
                    return .labelColor
                }()

                var normalizedAttrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: resolvedFG,
                    .paragraphStyle: paragraphStyle
                ]

                if isInlineCode {
                    normalizedAttrs[.font] = monoFont
                    normalizedAttrs[.backgroundColor] = inlineCodeBackgroundColor
                } else {
                    normalizedAttrs[.font] = cachedFont(size: resolvedSize, isBold: isBold, isItalic: isItalic)
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

                result.setAttributes(normalizedAttrs, range: segRange)
                segStart = segEnd
            }
        }

        // Restore disk-backed inline image attachments at each 1-char UTF-16 sentinel (`U+E000`).
        if !imageFileNames.isEmpty {
            let sentinelChar = NoteMarkdownConverter.imageSentinelUTF16
            let currentNS = result.string as NSString
            let len = currentNS.length
            var sentinelLocations: [Int] = []
            for idx in 0..<len where currentNS.character(at: idx) == sentinelChar {
                sentinelLocations.append(idx)
            }

            let imagePara = NSMutableParagraphStyle()
            imagePara.lineSpacing = lineSpacing
            imagePara.paragraphSpacingBefore = 3
            imagePara.paragraphSpacing = 4

            // Replace in reverse order so out-of-range fallback strings cannot shift earlier indices.
            for (imgIdx, loc) in sentinelLocations.enumerated().reversed() {
                let targetRange = NSRange(location: loc, length: 1)
                if imgIdx < imageFileNames.count {
                    let fileName = imageFileNames[imgIdx]
                    if let loadedImage = imageLoader?(fileName) {
                        let attachment = NoteImageTextAttachment(fileName: fileName, image: loadedImage)
                        let attr = NSMutableAttributedString(attachment: attachment)
                        attr.addAttribute(.paragraphStyle, value: imagePara, range: NSRange(location: 0, length: attr.length))
                        result.replaceCharacters(in: targetRange, with: attr)
                    } else {
                        let missing = NSAttributedString(
                            string: "[图片文件已移除]",
                            attributes: [
                                .font: NSFont.systemFont(ofSize: max(11, fontSize - 1)),
                                .foregroundColor: NSColor.tertiaryLabelColor,
                                .paragraphStyle: imagePara
                            ]
                        )
                        result.replaceCharacters(in: targetRange, with: missing)
                    }
                } else {
                    result.deleteCharacters(in: targetRange)
                }
            }
        }

        result.endEditing()
        return result
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlaceholderNoteTextView
        var lastSyncedPlainText = ""
        var lastSyncedRevision = 0
        private var lastReportedSelection = ""

        init(_ parent: PlaceholderNoteTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderNSTextView else { return }
            textView.needsDisplay = true
            guard !textView.hasMarkedText(), !textView.isSuppressingNestedTextDidChange else { return }
            textView.processLiveMarkdownIfNeeded()
            syncRichTextAndFormat(from: textView)
            reportSelection(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? PlaceholderNSTextView else { return }
            reportSelection(for: textView)
            syncFormatState(from: textView)
        }

        func syncRichTextAndFormat(from textView: PlaceholderNSTextView) {
            if parent.isRichTextEnabled {
                let exported = textView.exportRichContent()
                lastSyncedPlainText = exported.plainText
                if parent.text != exported.plainText {
                    parent.text = exported.plainText
                }
                if let onRichContentChanged = parent.onRichContentChanged {
                    onRichContentChanged(exported.plainText, exported.rtfData, exported.imageFileNames)
                } else {
                    parent.onRichTextChanged?(exported.plainText, exported.rtfData)
                }
            } else {
                let plain = textView.string
                lastSyncedPlainText = plain
                if parent.text != plain {
                    parent.text = plain
                }
            }
            syncFormatState(from: textView)
        }

        func syncFormatState(from textView: PlaceholderNSTextView) {
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
        return nsStr.substring(with: range)
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ensures the underlying `NSTextView` is always at least as tall as the visible scroll viewport
/// so clicking anywhere in an empty note immediately focuses the cursor, and re-layouts inline
/// images smoothly whenever the editor width changes.
private final class AutoSizingNoteScrollView: NSScrollView {
    private var lastViewportWidth: CGFloat = 0

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
        let currentWidth = contentView.bounds.width
        if abs(currentWidth - lastViewportWidth) > 1.0 {
            lastViewportWidth = currentWidth
            if let storage = textView.textStorage, storage.containsAttachments, storage.length > 0 {
                textView.layoutManager?.invalidateLayout(
                    forCharacterRange: NSRange(location: 0, length: storage.length),
                    actualCharacterRange: nil
                )
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
    var allowImageAttachments: Bool = false
    var isTabActive: Bool = true
    var onSendSelectionToBoard: ((String, Bool) -> Void)?
    var onStoreImage: ((NSImage, Data?) -> (fileName: String, image: NSImage)?)?
    var imageURLResolver: ((String) -> URL?)?
    var onTypingFormatChanged: (() -> Void)?

    private var contextMenuImageAttachment: (attachment: NoteImageTextAttachment, charIndex: Int)?
    private static let maxPastedImageBytes = 32 * 1024 * 1024

    private enum InlineRule {
        case bold
        case highlight
        case strikethrough
        case inlineCode
        case italic
    }

    private static let inlineMarkdownRules: [(NSRegularExpression, InlineRule)] = {
        let specs: [(String, InlineRule)] = [
            (#"(?<!\*)\*\*([^*\n]+?)\*\*$"#, .bold),
            (#"==([^=\n]+?)==$"#, .highlight),
            (#"~~([^~\n]+?)~~$"#, .strikethrough),
            (#"`([^`\n]+?)`$"#, .inlineCode),
            (#"(?<!\*)\*([^*\s\n](?:[^*\n]*?[^*\s\n])?)\*$"#, .italic)
        ]
        return specs.compactMap { pattern, rule in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, rule)
        }
    }()

    private static let numberedListRegex = try? NSRegularExpression(pattern: #"^(\d+)\.\s+"#)

    override func resetCursorRects() {
        guard isTabActive, !isHiddenOrHasHiddenAncestor else { return }
        super.resetCursorRects()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isTabActive, !isHiddenOrHasHiddenAncestor else { return }
        super.cursorUpdate(with: event)
    }

    private var isApplyingAutoMarkdown = false
    fileprivate var isSuppressingNestedTextDidChange = false

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
        guard prefixLen > 0, prefixLen <= 4_096 else { return }
        let lineBeforeCaret = nsText.substring(with: NSRange(location: lineRange.location, length: prefixLen))

        isApplyingAutoMarkdown = true
        isSuppressingNestedTextDidChange = true
        defer {
            isSuppressingNestedTextDidChange = false
            isApplyingAutoMarkdown = false
        }

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
            let nsText = string as NSString
            let trimmedLineLen = (nsText.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString).length
            let targetLineRange = NSRange(location: lineRange.location, length: max(prefixRange.length, trimmedLineLen))
            let remainingRange = NSRange(
                location: caretLocation,
                length: max(0, NSMaxRange(targetLineRange) - caretLocation)
            )
            let remainingStr = remainingRange.length > 0 ? nsText.substring(with: remainingRange) : ""
            let replacement = NSAttributedString(string: remainingStr, attributes: hAttrs)
            if shouldChangeText(in: targetLineRange, replacementString: remainingStr) {
                storage.replaceCharacters(in: targetLineRange, with: replacement)
                didChangeText()
                setSelectedRange(NSRange(location: lineRange.location, length: 0))
                typingAttributes = hAttrs
                return true
            }
        }

        // Unchecked Checkbox: "- [ ] ", "* [ ] ", "[] ", "• [ ] ", "• [] "
        // Note: typing "- " converts immediately to "• ", so typing "- [ ] " arrives here as "• [ ] ".
        if lineBeforeCaret == "- [ ] " || lineBeforeCaret == "* [ ] " || lineBeforeCaret == "[] "
            || lineBeforeCaret == "• [ ] " || lineBeforeCaret == "• [] " {
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

        // Checked Checkbox: "- [x] ", "- [X] ", "* [x] ", "* [X] ", "• [x] ", "• [X] "
        if lineBeforeCaret == "- [x] " || lineBeforeCaret == "- [X] "
            || lineBeforeCaret == "* [x] " || lineBeforeCaret == "* [X] "
            || lineBeforeCaret == "• [x] " || lineBeforeCaret == "• [X] " {
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
            let qAttrs = PlaceholderNoteTextView.quoteAttributes(
                baseFontSize: baseFontSize,
                lineSpacing: baseLineSpacing
            )
            let nsText = string as NSString
            let trimmedLineLen = (nsText.substring(with: lineRange).trimmingCharacters(in: .newlines) as NSString).length
            let targetLineRange = NSRange(location: lineRange.location, length: max(prefixRange.length, trimmedLineLen))
            let remainingRange = NSRange(
                location: caretLocation,
                length: max(0, NSMaxRange(targetLineRange) - caretLocation)
            )
            let replacement = NSMutableAttributedString(attributedString: quote)
            if remainingRange.length > 0 {
                replacement.append(NSAttributedString(string: nsText.substring(with: remainingRange), attributes: qAttrs))
            }
            if shouldChangeText(in: targetLineRange, replacementString: replacement.string) {
                storage.replaceCharacters(in: targetLineRange, with: replacement)
                didChangeText()
                let nextLoc = lineRange.location + quote.length
                setSelectedRange(NSRange(location: nextLoc, length: 0))
                typingAttributes = qAttrs
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

        for (regex, rule) in Self.inlineMarkdownRules {
            guard let match = regex.firstMatch(in: lineBeforeCaret, range: fullRange),
                  match.numberOfRanges >= 2 else {
                continue
            }

            let matchRangeInDoc = NSRange(location: lineStart + match.range.location, length: match.range.length)
            let innerText = nsLine.substring(with: match.range(at: 1))
            guard !innerText.isEmpty else { continue }

            // Preserve line-level context (heading size, quote color, paragraph style) when applying inline syntax.
            let existingAttrs = matchRangeInDoc.location < storage.length
                ? storage.attributes(at: matchRangeInDoc.location, effectiveRange: nil)
                : clean
            let existingFont = existingAttrs[.font] as? NSFont
            let activeSize = existingFont?.pointSize ?? baseFontSize
            let existingTraits = existingFont.map { NSFontManager.shared.traits(of: $0) } ?? []
            let existingBold = existingTraits.contains(.boldFontMask)
            let existingItalic = existingTraits.contains(.italicFontMask)
                || (((existingAttrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0) > 0.05)

            var contextBase = clean
            if let fg = existingAttrs[.foregroundColor] {
                contextBase[.foregroundColor] = fg
            }
            if let para = existingAttrs[.paragraphStyle] {
                contextBase[.paragraphStyle] = para
            }
            if let existingFont {
                contextBase[.font] = existingFont
            }

            var styledAttrs = contextBase
            switch rule {
            case .bold:
                styledAttrs[.font] = PlaceholderNoteTextView.resolvedFont(
                    size: activeSize,
                    isBold: true,
                    isItalic: existingItalic
                )
            case .highlight:
                styledAttrs[.backgroundColor] = PlaceholderNoteTextView.highlightYellowColor
            case .strikethrough:
                styledAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .inlineCode:
                styledAttrs = PlaceholderNoteTextView.inlineCodeAttributes(
                    baseFontSize: baseFontSize,
                    lineSpacing: baseLineSpacing
                )
                if let para = existingAttrs[.paragraphStyle] {
                    styledAttrs[.paragraphStyle] = para
                }
            case .italic:
                styledAttrs[.font] = PlaceholderNoteTextView.resolvedFont(
                    size: activeSize,
                    isBold: existingBold,
                    isItalic: true
                )
                styledAttrs[.obliqueness] = NSNumber(value: Double(PlaceholderNoteTextView.chineseItalicObliqueness))
            }

            let styled = NSAttributedString(string: innerText, attributes: styledAttrs)
            if shouldChangeText(in: matchRangeInDoc, replacementString: innerText) {
                storage.replaceCharacters(in: matchRangeInDoc, with: styled)
                didChangeText()
                let caretPos = matchRangeInDoc.location + styled.length
                setSelectedRange(NSRange(location: caretPos, length: 0))
                // Continue typing in the line's surrounding style (e.g. heading/quote) without bleeding inline style
                typingAttributes = contextBase
                onTypingFormatChanged?()
            }
            return
        }
    }

    // MARK: - Clickable Checkboxes (`☐` <-> `☑`) Right Inside Editor!

    override func mouseDown(with event: NSEvent) {
        if isRichText, allowImageAttachments, event.clickCount == 2,
           let hit = imageAttachment(at: event) {
            previewImageAttachment(hit.attachment)
            return
        }
        if isRichText, tryToggleCheckbox(at: event) {
            return
        }
        super.mouseDown(with: event)
    }

    private func imageAttachment(at event: NSEvent) -> (attachment: NoteImageTextAttachment, charIndex: Int)? {
        guard let storage = textStorage,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              storage.containsAttachments,
              storage.length > 0 else {
            return nil
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
        guard charIndex < storage.length,
              let attachment = storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? NoteImageTextAttachment else {
            return nil
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: charIndex, length: 1), actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard glyphRect.insetBy(dx: -4, dy: -4).contains(pointInContainer) else { return nil }
        return (attachment, charIndex)
    }

    private func previewImageAttachment(_ attachment: NoteImageTextAttachment) {
        if let url = imageURLResolver?(attachment.fileName), FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        }
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

        // Convert UTF-16 character range to glyph range so preceding emoji/surrogate pairs never crash layoutManager.
        let charRange = NSRange(location: lineRange.location, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return false }
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let expandedHitRect = glyphRect.insetBy(dx: -5, dy: -3)
        guard expandedHitRect.contains(pointInContainer) else { return false }

        let nextChecked = isUnchecked
        let trimmedContentLen = (lineStr.trimmingCharacters(in: .newlines) as NSString).length
        guard trimmedContentLen >= 2 else { return false }
        let targetRange = NSRange(location: lineRange.location, length: trimmedContentLen)
        guard NSMaxRange(targetRange) <= storage.length else { return false }

        let updatedLine = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: targetRange))
        let symbolAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: baseFontSize + 0.8),
            .foregroundColor: nextChecked ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            .paragraphStyle: checkboxParagraphStyle()
        ]
        updatedLine.replaceCharacters(
            in: NSRange(location: 0, length: 1),
            with: NSAttributedString(string: nextChecked ? "☑" : "☐", attributes: symbolAttrs)
        )

        let bodyLen = max(0, trimmedContentLen - 2)
        if bodyLen > 0 {
            let localBodyRange = NSRange(location: 2, length: bodyLen)
            if nextChecked {
                updatedLine.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: localBodyRange)
                updatedLine.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: localBodyRange)
            } else {
                updatedLine.removeAttribute(.strikethroughStyle, range: localBodyRange)
                updatedLine.addAttribute(.foregroundColor, value: NSColor.labelColor, range: localBodyRange)
            }
        }

        guard shouldChangeText(in: targetRange, replacementString: updatedLine.string) else { return false }
        storage.replaceCharacters(in: targetRange, with: updatedLine)
        didChangeText()
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
                .font: NSFont.systemFont(ofSize: baseFontSize + 0.8),
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
        let bgColor = attrs[.backgroundColor] as? NSColor
        let isInlineCode = (font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
            || NoteMarkdownConverter.isInlineCodeBackgroundColor(bgColor)
        let isBold = traits.contains(.boldFontMask)
        let obliq = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
        let isItalic = traits.contains(.italicFontMask) || obliq > 0.05
        let isUnderlined = ((attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
        let isStrikethrough = ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
        let isHighlighted = NoteMarkdownConverter.isYellowHighlightColor(bgColor)

        let headingLevel: Int = {
            guard let pt = font?.pointSize else { return 0 }
            if pt >= 17.5 || pt >= baseFontSize + 4.5 { return 1 }
            if pt >= 15.0 || pt >= baseFontSize + 2.2 { return 2 }
            if pt >= 13.9 || pt >= baseFontSize + 1.2 { return 3 }
            return 0
        }()

        return NoteFormatState(
            isBold: isBold && headingLevel == 0,
            isItalic: isItalic,
            isHighlighted: isHighlighted,
            isUnderlined: isUnderlined,
            isStrikethrough: isStrikethrough,
            isInlineCode: isInlineCode,
            headingLevel: headingLevel
        )
    }

    func applyFormatAction(_ action: NoteFormatAction) {
        guard isRichText, let storage = textStorage else { return }

        if case .insertMarkdown(let snippet) = action {
            applyWYSIWYGSnippet(snippet)
            return
        }

        if case .insertImage(let image, let rawPNG) = action {
            insertImages([(image, rawPNG)])
            return
        }

        let range = selectedRange()
        if range.length == 0 {
            if case .clearFormatting = action {
                typingAttributes = PlaceholderNoteTextView.baseAttributes(
                    fontSize: baseFontSize,
                    lineSpacing: baseLineSpacing
                )
                onTypingFormatChanged?()
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
            case .clearFormatting, .insertMarkdown, .insertImage:
                break
            }
            attrs[.foregroundColor] = NSColor.labelColor
            typingAttributes = attrs
            onTypingFormatChanged?()
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
        case .clearFormatting, .insertMarkdown, .insertImage: enable = false
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

        case .insertMarkdown, .insertImage:
            break
        }
        storage.endEditing()

        didChangeText()
        if range.location < storage.length {
            var synced = storage.attributes(at: range.location, effectiveRange: nil)
            synced[.foregroundColor] = NSColor.labelColor
            typingAttributes = synced
        }
        onTypingFormatChanged?()
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
            onTypingFormatChanged?()

        case .checkbox:
            let prefix = makeCheckboxPrefix(isChecked: false)
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if shouldChangeText(in: insertRange, replacementString: prefix.string) {
                storage.insert(prefix, at: lineRange.location)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + prefix.length, length: sel.length))
                typingAttributes = clean
                onTypingFormatChanged?()
            }

        case .bullet:
            let prefix = makeBulletPrefix()
            let insertRange = NSRange(location: lineRange.location, length: 0)
            if shouldChangeText(in: insertRange, replacementString: prefix.string) {
                storage.insert(prefix, at: lineRange.location)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + prefix.length, length: sel.length))
                typingAttributes = clean
                onTypingFormatChanged?()
            }

        case .quote:
            let prefix = makeQuotePrefix()
            let targetLineRange = NSRange(location: lineRange.location, length: lineContentLen)
            let qAttrs = PlaceholderNoteTextView.quoteAttributes(baseFontSize: baseFontSize, lineSpacing: baseLineSpacing)
            let replacement = NSMutableAttributedString(attributedString: prefix)
            if lineContentLen > 0 {
                replacement.append(NSAttributedString(string: nsText.substring(with: targetLineRange), attributes: qAttrs))
            }
            if shouldChangeText(in: targetLineRange, replacementString: replacement.string) {
                storage.replaceCharacters(in: targetLineRange, with: replacement)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + prefix.length, length: sel.length))
                typingAttributes = qAttrs
                onTypingFormatChanged?()
            }

        case .inlineCode:
            let codeAttrs = PlaceholderNoteTextView.inlineCodeAttributes(
                baseFontSize: baseFontSize,
                lineSpacing: baseLineSpacing
            )
            let isCurrentlyCode = currentFormatState().isInlineCode
            if sel.length > 0 {
                if shouldChangeText(in: sel, replacementString: nil) {
                    storage.beginEditing()
                    storage.enumerateAttributes(in: sel, options: []) { attrs, subRange, _ in
                        var updated = isCurrentlyCode ? clean : codeAttrs
                        if let para = attrs[.paragraphStyle] {
                            updated[.paragraphStyle] = para
                        }
                        if isCurrentlyCode, let fg = attrs[.foregroundColor] {
                            updated[.foregroundColor] = fg
                        }
                        storage.setAttributes(updated, range: subRange)
                    }
                    storage.endEditing()
                    didChangeText()
                    typingAttributes = clean
                    onTypingFormatChanged?()
                }
            } else {
                typingAttributes = isCurrentlyCode ? clean : codeAttrs
                onTypingFormatChanged?()
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
                onTypingFormatChanged?()
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

    /// Exports plain text (without attachment chars), compact RTF (with `U+E000` sentinels instead of binary images),
    /// and the ordered list of inline image filenames.
    func exportRichContent() -> (plainText: String, rtfData: Data?, imageFileNames: [String]) {
        guard isRichText, let storage = textStorage, storage.length > 0 else {
            return (string, nil, [])
        }
        if !storage.containsAttachments {
            return (storage.string, exportRTFData(), [])
        }

        let copy = NSMutableAttributedString(attributedString: storage)
        let fullRange = NSRange(location: 0, length: copy.length)
        let baseAttrs = PlaceholderNoteTextView.baseAttributes(fontSize: baseFontSize, lineSpacing: baseLineSpacing)
        var attachments: [(range: NSRange, fileName: String)] = []

        copy.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            if let imgAttachment = value as? NoteImageTextAttachment {
                attachments.append((range, imgAttachment.fileName))
            }
        }

        let fileNames = attachments.map(\.fileName)
        for item in attachments.reversed() {
            copy.replaceCharacters(
                in: item.range,
                with: NSAttributedString(string: NoteMarkdownConverter.imageSentinel, attributes: baseAttrs)
            )
        }

        let rtf = try? copy.data(
            from: NSRange(location: 0, length: copy.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let plainText = storage.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        return (plainText, rtf, fileNames)
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
                    onTypingFormatChanged?()
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
            let fullLineContent = nsText.substring(with: lineRange).trimmingCharacters(in: .newlines)

            // Convert "---" + Enter into visual divider when live Markdown is enabled
            if isLiveMarkdownEnabled && (fullLineContent == "---" || fullLineContent == "***") && lineBeforeCaret == fullLineContent {
                let target = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
                let divider = makeDividerAttributedString(includeTrailingNewline: true)
                if shouldChangeText(in: target, replacementString: divider.string) {
                    isApplyingAutoMarkdown = true
                    textStorage?.replaceCharacters(in: target, with: divider)
                    isApplyingAutoMarkdown = false
                    didChangeText()
                    setSelectedRange(NSRange(location: lineRange.location + divider.length, length: 0))
                    typingAttributes = cleanAttrs
                    onTypingFormatChanged?()
                    return
                }
            }

            // Checklist continuation (`☐ ` / `☑ `)
            if lineBeforeCaret.hasPrefix("☐ ") || lineBeforeCaret.hasPrefix("☑ ") {
                let fullRemainder = String(fullLineContent.dropFirst(2))
                if fullRemainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    let removeRange = NSRange(location: lineRange.location, length: (fullLineContent as NSString).length)
                    if shouldChangeText(in: removeRange, replacementString: "") {
                        textStorage?.replaceCharacters(in: removeRange, with: "")
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onTypingFormatChanged?()
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
                        onTypingFormatChanged?()
                        return
                    }
                }
            }

            // Quote exit on empty `▎ `
            if lineBeforeCaret.hasPrefix("▎ ") {
                let fullRemainder = String(fullLineContent.dropFirst(2))
                if fullRemainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    let removeRange = NSRange(location: lineRange.location, length: (fullLineContent as NSString).length)
                    if shouldChangeText(in: removeRange, replacementString: "") {
                        textStorage?.replaceCharacters(in: removeRange, with: "")
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onTypingFormatChanged?()
                        return
                    }
                }
            }

            // Bullet list continuation (`• ` / `- ` / `* ` / `- [ ] `)
            let listPrefixes = ["- [ ] ", "• ", "- ", "* "]
            if let matchedPrefix = listPrefixes.first(where: { lineBeforeCaret.hasPrefix($0) }) {
                let fullRemainder = String(fullLineContent.dropFirst(matchedPrefix.count))
                if fullRemainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    let removeRange = NSRange(location: lineRange.location, length: (fullLineContent as NSString).length)
                    if shouldChangeText(in: removeRange, replacementString: "") {
                        textStorage?.replaceCharacters(in: removeRange, with: "")
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onTypingFormatChanged?()
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
                        onTypingFormatChanged?()
                        return
                    }
                }
            } else if let regex = Self.numberedListRegex,
                      let match = regex.firstMatch(
                          in: lineBeforeCaret,
                          range: NSRange(location: 0, length: (lineBeforeCaret as NSString).length)
                      ) {
                let nsLine = lineBeforeCaret as NSString
                let numStr = nsLine.substring(with: match.range(at: 1))
                let prefixLen = match.range.length
                let nsFullLine = fullLineContent as NSString
                let fullRemainder = prefixLen <= nsFullLine.length ? nsFullLine.substring(from: prefixLen) : ""
                if fullRemainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    let removeRange = NSRange(location: lineRange.location, length: nsFullLine.length)
                    if shouldChangeText(in: removeRange, replacementString: "") {
                        textStorage?.replaceCharacters(in: removeRange, with: "")
                        didChangeText()
                        typingAttributes = cleanAttrs
                        onTypingFormatChanged?()
                        return
                    }
                } else if let num = Int(numStr), num < Int.max {
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
                        onTypingFormatChanged?()
                        return
                    }
                }
            }
        }

        // Standard newline: reset typingAttributes so heading / yellow highlight / bold / underline don't bleed
        super.insertNewline(sender)
        typingAttributes = cleanAttrs
        onTypingFormatChanged?()
    }

    // MARK: - Keyboard Shortcuts & Clean Paste

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        if isRichText && allowImageAttachments {
            for extra in [NSPasteboard.PasteboardType.png, .tiff, .fileURL, NSPasteboard.PasteboardType("public.jpeg")] where !types.contains(extra) {
                types.append(extra)
            }
        }
        return types
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)),
           isEditable, isRichText, allowImageAttachments,
           hasPasteableImages(in: NSPasteboard.general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRichText, isTabActive, !isHiddenOrHasHiddenAncestor, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()

        if flags == .command {
            switch key {
            case "v":
                paste(nil)
                return true
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
        } else if flags == [.command, .shift, .option], key == "v" {
            pasteAsPlainText(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if isRichText, allowImageAttachments, tryPasteImages(from: NSPasteboard.general) {
            return
        }
        pasteSanitizedPlainText()
    }

    override func pasteAsPlainText(_ sender: Any?) {
        pasteSanitizedPlainText()
    }

    override func copy(_ sender: Any?) {
        if isRichText, allowImageAttachments, let storage = textStorage {
            let sel = selectedRange()
            if sel.length > 0, NSMaxRange(sel) <= storage.length {
                let selectedText = (storage.string as NSString)
                    .substring(with: sel)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if selectedText.isEmpty {
                    var found: [NoteImageTextAttachment] = []
                    storage.enumerateAttribute(.attachment, in: sel, options: []) { value, _, _ in
                        if let img = value as? NoteImageTextAttachment {
                            found.append(img)
                        }
                    }
                    if found.count == 1 {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.writeObjects([found[0].originalImage])
                        return
                    }
                }
            }
        }
        super.copy(sender)
    }

    // MARK: - Image Paste & Drag-Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isRichText, allowImageAttachments, hasPasteableImages(in: sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isRichText, allowImageAttachments, hasPasteableImages(in: sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isRichText, allowImageAttachments, tryPasteImages(from: sender.draggingPasteboard) {
            return true
        }
        return super.performDragOperation(sender)
    }

    private static let jpegPasteboardType = NSPasteboard.PasteboardType("public.jpeg")

    private func hasPasteableImages(in pasteboard: NSPasteboard) -> Bool {
        if !extractImageFileURLs(from: pasteboard).isEmpty {
            return true
        }
        let types = Set(pasteboard.types ?? [])
        return types.contains(.png)
            || types.contains(.tiff)
            || types.contains(Self.jpegPasteboardType)
            || NSImage.canInit(with: pasteboard)
    }

    private func extractImageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return []
        }
        return urls.filter { url in
            if let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey]),
               values.isRegularFile == true,
               let type = values.contentType {
                return type.conforms(to: .image)
            }
            if let extType = UTType(filenameExtension: url.pathExtension) {
                return extType.conforms(to: .image)
            }
            return false
        }
    }

    @discardableResult
    func tryPasteImages(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, isRichText, allowImageAttachments else { return false }

        // 1. Finder-copied or dragged image file URL(s) (also catches WeChat/messaging apps that put filename in .string).
        let imageURLs = extractImageFileURLs(from: pasteboard)
        if !imageURLs.isEmpty {
            var loaded: [(NSImage, Data?)] = []
            for url in imageURLs {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int, size > Self.maxPastedImageBytes {
                    continue
                }
                guard let data = try? Data(contentsOf: url),
                      data.count <= Self.maxPastedImageBytes,
                      let img = NSImage(data: data) else { continue }
                let rawPNG: Data? = url.pathExtension.lowercased() == "png" ? data : nil
                loaded.append((img, rawPNG))
            }
            if !loaded.isEmpty {
                insertImages(loaded)
                return true
            }
        }

        // 2. Direct clipboard image (screenshots, browser "Copy Image", Preview, Piko Clipboard).
        // Skip if non-empty plain text is present so copying formatted text from Word/Excel still pastes text.
        let types = Set(pasteboard.types ?? [])
        let hasNonEmptyPlainText: Bool = {
            guard types.contains(.string), let s = pasteboard.string(forType: .string) else { return false }
            return s.contains(where: { !$0.isWhitespace && !$0.isNewline })
        }()
        guard !hasNonEmptyPlainText else { return false }

        if types.contains(.png), let pngData = pasteboard.data(forType: .png),
           pngData.count <= Self.maxPastedImageBytes,
           let img = NSImage(data: pngData) {
            insertImages([(img, pngData)])
            return true
        }
        if types.contains(Self.jpegPasteboardType), let jpgData = pasteboard.data(forType: Self.jpegPasteboardType),
           jpgData.count <= Self.maxPastedImageBytes,
           let img = NSImage(data: jpgData) {
            insertImages([(img, nil)])
            return true
        }
        if types.contains(.tiff), let tiffData = pasteboard.data(forType: .tiff),
           tiffData.count <= Self.maxPastedImageBytes,
           let img = NSImage(data: tiffData) {
            insertImages([(img, nil)])
            return true
        }
        if NSImage.canInit(with: pasteboard),
           let img = NSImage(pasteboard: pasteboard),
           img.size.width > 0, img.size.height > 0 {
            insertImages([(img, nil)])
            return true
        }
        return false
    }

    func insertImages(_ items: [(image: NSImage, rawPNGData: Data?)]) {
        guard isEditable, isRichText, allowImageAttachments, let storage = textStorage, !items.isEmpty else { return }

        var stored: [(fileName: String, image: NSImage)] = []
        for (img, rawPNG) in items {
            if let result = onStoreImage?(img, rawPNG) {
                stored.append(result)
            }
        }
        guard !stored.isEmpty else { return }

        let sel = selectedRange()
        let nsText = string as NSString
        let needsLeadingNewline: Bool = {
            guard sel.location > 0, sel.location <= nsText.length else { return false }
            let prev = nsText.character(at: sel.location - 1)
            return prev != 0x0A && prev != 0x0D
        }()

        let clean = PlaceholderNoteTextView.baseAttributes(fontSize: baseFontSize, lineSpacing: baseLineSpacing)
        let imagePara = NSMutableParagraphStyle()
        imagePara.lineSpacing = baseLineSpacing
        imagePara.paragraphSpacingBefore = 3
        imagePara.paragraphSpacing = 4

        let payload = NSMutableAttributedString()
        if needsLeadingNewline {
            payload.append(NSAttributedString(string: "\n", attributes: clean))
        }
        for entry in stored {
            let attachment = NoteImageTextAttachment(fileName: entry.fileName, image: entry.image)
            let imgAttr = NSMutableAttributedString(attachment: attachment)
            imgAttr.addAttribute(.paragraphStyle, value: imagePara, range: NSRange(location: 0, length: imgAttr.length))
            payload.append(imgAttr)
            payload.append(NSAttributedString(string: "\n", attributes: clean))
        }

        isApplyingAutoMarkdown = true
        defer { isApplyingAutoMarkdown = false }

        if shouldChangeText(in: sel, replacementString: payload.string) {
            storage.replaceCharacters(in: sel, with: payload)
            didChangeText()
            let nextLoc = sel.location + payload.length
            setSelectedRange(NSRange(location: nextLoc, length: 0))
            typingAttributes = clean
            onTypingFormatChanged?()
        }
    }

    private func pasteSanitizedPlainText() {
        guard isEditable else { return }
        guard let rawText = readPlainTextFromGeneralPasteboard() else { return }
        let sanitized = PlaceholderNoteTextView.sanitizedPlainTextForInsertion(rawText)
        guard !sanitized.isEmpty else { return }

        if typingAttributes[.font] == nil {
            typingAttributes = PlaceholderNoteTextView.baseAttributes(
                fontSize: baseFontSize,
                lineSpacing: baseLineSpacing
            )
        }

        // Prevent live-typing Markdown regex from mutating pasted code/text or doubling RTF export.
        isApplyingAutoMarkdown = true
        defer { isApplyingAutoMarkdown = false }
        insertText(sanitized, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func readPlainTextFromGeneralPasteboard() -> String? {
        let pasteboard = NSPasteboard.general
        if let plain = pasteboard.string(forType: .string) {
            return plain
        }
        if let rtfData = pasteboard.data(forType: .rtf),
           let decoded = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            return decoded.string
        }
        if let rtfdData = pasteboard.data(forType: .rtfd),
           let decoded = NSAttributedString(rtfd: rtfdData, documentAttributes: nil) {
            return decoded.string
        }
        return nil
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

        if isRichText, allowImageAttachments, let hit = imageAttachment(at: event) {
            contextMenuImageAttachment = hit

            let previewItem = NSMenuItem(title: "预览原图", action: #selector(handleMenuPreviewImage), keyEquivalent: "")
            previewItem.target = self
            previewItem.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
            baseMenu.insertItem(previewItem, at: insertIndex)
            insertIndex += 1

            let copyImgItem = NSMenuItem(title: "复制图片", action: #selector(handleMenuCopyImage), keyEquivalent: "")
            copyImgItem.target = self
            copyImgItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            baseMenu.insertItem(copyImgItem, at: insertIndex)
            insertIndex += 1

            let saveImgItem = NSMenuItem(title: "存储图片…", action: #selector(handleMenuSaveImage), keyEquivalent: "")
            saveImgItem.target = self
            saveImgItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
            baseMenu.insertItem(saveImgItem, at: insertIndex)
            insertIndex += 1

            let deleteImgItem = NSMenuItem(title: "删除图片", action: #selector(handleMenuDeleteImage), keyEquivalent: "")
            deleteImgItem.target = self
            deleteImgItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            baseMenu.insertItem(deleteImgItem, at: insertIndex)
            insertIndex += 1

            baseMenu.insertItem(.separator(), at: insertIndex)
            insertIndex += 1
        } else {
            contextMenuImageAttachment = nil
        }

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

    @objc private func handleMenuPreviewImage() {
        guard let hit = contextMenuImageAttachment else { return }
        previewImageAttachment(hit.attachment)
    }

    @objc private func handleMenuCopyImage() {
        guard let hit = contextMenuImageAttachment else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([hit.attachment.originalImage])
    }

    @objc private func handleMenuSaveImage() {
        guard let hit = contextMenuImageAttachment else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Piko-Note-Image.png"
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let destURL = panel.url else { return }
            if let srcURL = self?.imageURLResolver?(hit.attachment.fileName),
               FileManager.default.fileExists(atPath: srcURL.path) {
                try? FileManager.default.removeItem(at: destURL)
                try? FileManager.default.copyItem(at: srcURL, to: destURL)
            } else if let tiff = hit.attachment.originalImage.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: destURL, options: .atomic)
            }
        }
    }

    @objc private func handleMenuDeleteImage() {
        guard let hit = contextMenuImageAttachment, let storage = textStorage else { return }
        let range = NSRange(location: hit.charIndex, length: 1)
        guard NSMaxRange(range) <= storage.length else { return }
        if shouldChangeText(in: range, replacementString: "") {
            storage.deleteCharacters(in: range)
            didChangeText()
            setSelectedRange(NSRange(location: min(hit.charIndex, storage.length), length: 0))
        }
        contextMenuImageAttachment = nil
    }

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
