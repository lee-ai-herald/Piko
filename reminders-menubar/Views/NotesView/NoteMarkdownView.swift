import Cocoa
import SwiftUI

// MARK: - WYSIWYG Markdown Block & Inline Snippets

enum MarkdownSnippet {
    case heading1
    case heading2
    case heading3
    case checkbox
    case bullet
    case quote
    case inlineCode
    case divider
}

// MARK: - RTF <-> Markdown Export & Sidebar Preview Helper

enum NoteMarkdownConverter {
    static let dividerLineText = "────────────────────────"
    /// 1-char UTF-16 sentinel stored in RTF at each inline image position so images persist
    /// on disk (`NoteImages/`) instead of bloating `quick_notes.json` with raw binary blobs.
    static let imageSentinel = "\u{E000}"
    static let imageSentinelUTF16: unichar = 0xE000

    /// Converts a WYSIWYG `QuickNoteItem` (including headings, checkboxes, bullets, quotes,
    /// inline code, Bold/Italic/Highlight/Underline/Strikethrough, and inline images) into clean Markdown text.
    static func markdownSource(
        for note: QuickNoteItem,
        imageURLResolver: ((String) -> URL?)? = nil
    ) -> String {
        guard let rtfData = note.rtfData,
              let decoded = NSAttributedString(rtf: rtfData, documentAttributes: nil),
              decoded.length > 0 else {
            return note.content
        }

        let nsStr = decoded.string as NSString
        var outputLines: [String] = []
        var lineLocation = 0
        var nextImageIndex = 0

        while lineLocation <= nsStr.length {
            let lineRange = nsStr.lineRange(for: NSRange(location: lineLocation, length: 0))
            let rawLine = nsStr.substring(with: lineRange)
            let strippedNewline = rawLine.trimmingCharacters(in: CharacterSet.newlines)
            let contentLength = (strippedNewline as NSString).length

            if contentLength == 0 {
                outputLines.append("")
            } else if strippedNewline.trimmingCharacters(in: .whitespaces).hasPrefix("────") {
                outputLines.append("---")
            } else {
                let effectiveRange = NSRange(location: lineRange.location, length: contentLength)
                outputLines.append(
                    convertLine(
                        decoded,
                        range: effectiveRange,
                        imageFileNames: note.imageFileNames,
                        nextImageIndex: &nextImageIndex,
                        imageURLResolver: imageURLResolver
                    )
                )
            }

            let nextLoc = NSMaxRange(lineRange)
            if nextLoc <= lineLocation || nextLoc >= nsStr.length {
                if rawLine.hasSuffix("\n") {
                    outputLines.append("")
                }
                break
            }
            lineLocation = nextLoc
        }

        return outputLines.joined(separator: "\n")
    }

    private static func convertLine(
        _ attributed: NSAttributedString,
        range: NSRange,
        imageFileNames: [String],
        nextImageIndex: inout Int,
        imageURLResolver: ((String) -> URL?)?
    ) -> String {
        let rawLine = (attributed.string as NSString).substring(with: range)

        // Pure inline-image line(s)
        if rawLine.contains(imageSentinel) && rawLine.replacingOccurrences(of: imageSentinel, with: "").trimmingCharacters(in: .whitespaces).isEmpty {
            var parts: [String] = []
            for scalar in rawLine.unicodeScalars where scalar == "\u{E000}" {
                parts.append(markdownImageTag(imageFileNames: imageFileNames, index: &nextImageIndex, resolver: imageURLResolver))
            }
            return parts.joined(separator: "\n")
        }

        // Detect WYSIWYG visual block prefixes
        var mdPrefix = ""
        var skipUTF16Length = 0

        if rawLine.hasPrefix("☐ ") {
            mdPrefix = "- [ ] "
            skipUTF16Length = ("☐ " as NSString).length
        } else if rawLine.hasPrefix("☑ ") {
            mdPrefix = "- [x] "
            skipUTF16Length = ("☑ " as NSString).length
        } else if rawLine.hasPrefix("• ") {
            mdPrefix = "- "
            skipUTF16Length = ("• " as NSString).length
        } else if rawLine.hasPrefix("▎ ") {
            mdPrefix = "> "
            skipUTF16Length = ("▎ " as NSString).length
        } else {
            // Detect heading by font size at start of line
            let firstAttrs = attributed.attributes(at: range.location, effectiveRange: nil)
            if let font = firstAttrs[.font] as? NSFont {
                if font.pointSize >= 17.5 {
                    mdPrefix = "# "
                } else if font.pointSize >= 15.0 {
                    mdPrefix = "## "
                } else if font.pointSize >= 13.9 {
                    mdPrefix = "### "
                }
            }
        }

        let isHeading = mdPrefix.hasPrefix("#")
        let bodyRange = NSRange(
            location: range.location + skipUTF16Length,
            length: max(0, range.length - skipUTF16Length)
        )
        guard bodyRange.length > 0 else { return mdPrefix }

        struct InlineStyle: Equatable {
            var isCode = false
            var isBold = false
            var isItalic = false
            var isStrikethrough = false
            var isUnderlined = false
            var isYellowHighlight = false

            static let plain = InlineStyle()
        }

        // Coalesce adjacent runs that share the same logical Markdown style so mixed ASCII/CJK/Emoji
        // font fallback splits don't emit broken markers like `*hello**世界*` or `` `git "`修复`"` ``.
        var segments: [(style: InlineStyle, text: String)] = []
        attributed.enumerateAttributes(in: bodyRange, options: []) { attrs, subRange, _ in
            let chunk = (attributed.string as NSString).substring(with: subRange)
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let bgColor = attrs[.backgroundColor] as? NSColor
            let isMono = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
            let isCode = isMono || Self.isInlineCodeBackgroundColor(bgColor)

            let style: InlineStyle
            if isCode {
                style = InlineStyle(isCode: true)
            } else {
                let isBold = traits.contains(.boldFontMask) && !isHeading
                let obliq = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
                let isItalic = traits.contains(.italicFontMask) || obliq > 0.05
                let isUnderlined = ((attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
                let isStrikethrough = ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0 && !rawLine.hasPrefix("☑ ")
                let isYellowHighlight = Self.isYellowHighlightColor(bgColor)
                style = InlineStyle(
                    isCode: false,
                    isBold: isBold,
                    isItalic: isItalic,
                    isStrikethrough: isStrikethrough,
                    isUnderlined: isUnderlined,
                    isYellowHighlight: isYellowHighlight
                )
            }

            if let lastIdx = segments.indices.last, segments[lastIdx].style == style {
                segments[lastIdx].text += chunk
            } else {
                segments.append((style, chunk))
            }
        }

        var result = mdPrefix
        for (style, chunk) in segments {
            guard style != .plain, !chunk.trimmingCharacters(in: .whitespaces).isEmpty else {
                result += chunk
                continue
            }

            let leadingSpaces = chunk.prefix(while: { $0 == " " || $0 == "\t" })
            let trailingSpaces = chunk.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed()
            let coreStart = chunk.index(chunk.startIndex, offsetBy: leadingSpaces.count)
            let coreEnd = chunk.index(chunk.endIndex, offsetBy: -trailingSpaces.count)
            guard coreStart < coreEnd else {
                result += chunk
                continue
            }

            var core = String(chunk[coreStart..<coreEnd])
            if style.isCode {
                core = "`\(core)`"
            } else {
                if style.isBold { core = "**\(core)**" }
                if style.isItalic { core = "*\(core)*" }
                if style.isStrikethrough { core = "~~\(core)~~" }
                if style.isUnderlined { core = "<u>\(core)</u>" }
                if style.isYellowHighlight { core = "==\(core)==" }
            }

            result += String(leadingSpaces) + core + String(trailingSpaces)
        }

        if result.contains(imageSentinel) {
            var expanded = ""
            for scalar in result.unicodeScalars {
                if scalar == "\u{E000}" {
                    expanded += markdownImageTag(imageFileNames: imageFileNames, index: &nextImageIndex, resolver: imageURLResolver)
                } else {
                    expanded.unicodeScalars.append(scalar)
                }
            }
            return expanded
        }

        return result
    }

    private static func markdownImageTag(
        imageFileNames: [String],
        index: inout Int,
        resolver: ((String) -> URL?)?
    ) -> String {
        guard index < imageFileNames.count else {
            return "![图片]()"
        }
        let fileName = imageFileNames[index]
        index += 1
        let target = resolver?(fileName)?.absoluteString ?? fileName
        return "![图片](\(target))"
    }

    static func isYellowHighlightColor(_ color: NSColor?) -> Bool {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent > 0.8 && rgb.greenComponent > 0.65 && rgb.blueComponent < 0.45
    }

    /// Detects subtle neutral inline-code background color so CJK/Emoji runs (where AppKit drops
    /// the `.monoSpace` font trait during glyph fallback) retain inline-code identity across RTF saves.
    static func isInlineCodeBackgroundColor(_ color: NSColor?) -> Bool {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return false }
        guard rgb.alphaComponent > 0.01, !isYellowHighlightColor(color) else { return false }
        let maxC = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        let minC = min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        return (maxC - minC) < 0.12 && (rgb.alphaComponent <= 0.35 || minC > 0.75)
    }

    private static let headingPrefixRegex = try? NSRegularExpression(pattern: #"^#{1,6}\s+"#)
    private static let inlineStripRegexes: [(NSRegularExpression, String)] = [
        (#"\*\*(.+?)\*\*"#, "$1"),
        (#"__(.+?)__"#, "$1"),
        (#"~~(.+?)~~"#, "$1"),
        (#"==(.+?)=="#, "$1"),
        (#"<u>(.+?)</u>"#, "$1"),
        (#"`([^`]+)`"#, "$1"),
        (#"\[([^\]]+)\]\([^)]+\)"#, "$1")
    ].compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, template)
    }

    /// Strips visual/Markdown list markers for clean sidebar card titles and snippets.
    static func strippedPlainText(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("────") {
            return ""
        }
        let simplePrefixes = ["☐ ", "☑ ", "• ", "▎ ", "- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "> "]
        for p in simplePrefixes where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if let regex = headingPrefixRegex {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        for (regex, template) in inlineStripRegexes {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
