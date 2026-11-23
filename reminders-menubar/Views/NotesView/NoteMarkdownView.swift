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

    /// Converts a WYSIWYG `QuickNoteItem` (including headings, checkboxes, bullets, quotes,
    /// inline code, Bold/Italic/Highlight/Underline/Strikethrough) into clean Markdown text.
    static func markdownSource(for note: QuickNoteItem) -> String {
        guard let rtfData = note.rtfData,
              let decoded = NSAttributedString(rtf: rtfData, documentAttributes: nil),
              decoded.length > 0 else {
            return note.content
        }

        let nsStr = decoded.string as NSString
        var outputLines: [String] = []
        var lineLocation = 0

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
                outputLines.append(convertLine(decoded, range: effectiveRange))
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

    private static func convertLine(_ attributed: NSAttributedString, range: NSRange) -> String {
        let rawLine = (attributed.string as NSString).substring(with: range)

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
                } else if font.pointSize >= 13.8 {
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

        var result = mdPrefix
        attributed.enumerateAttributes(in: bodyRange, options: []) { attrs, subRange, _ in
            let chunk = (attributed.string as NSString).substring(with: subRange)
            guard !chunk.trimmingCharacters(in: .whitespaces).isEmpty else {
                result += chunk
                return
            }

            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let isMono = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
            let isBold = traits.contains(.boldFontMask) && !isHeading
            let obliq = (attrs[.obliqueness] as? NSNumber)?.doubleValue ?? 0
            let isItalic = traits.contains(.italicFontMask) || obliq > 0.05
            let isUnderlined = ((attrs[.underlineStyle] as? NSNumber)?.intValue ?? 0) != 0
            let isStrikethrough = ((attrs[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0 && !rawLine.hasPrefix("☑ ")
            let bgColor = attrs[.backgroundColor] as? NSColor
            let isYellowHighlight = Self.isYellowHighlightColor(bgColor)

            let leadingSpaces = chunk.prefix(while: { $0 == " " || $0 == "\t" })
            let trailingSpaces = chunk.reversed().prefix(while: { $0 == " " || $0 == "\t" }).reversed()
            let coreStart = chunk.index(chunk.startIndex, offsetBy: leadingSpaces.count)
            let coreEnd = chunk.index(chunk.endIndex, offsetBy: -trailingSpaces.count)
            guard coreStart < coreEnd else {
                result += chunk
                return
            }

            var core = String(chunk[coreStart..<coreEnd])

            if isMono {
                core = "`\(core)`"
            } else {
                if isBold { core = "**\(core)**" }
                if isItalic { core = "*\(core)*" }
                if isStrikethrough { core = "~~\(core)~~" }
                if isUnderlined { core = "<u>\(core)</u>" }
                if isYellowHighlight { core = "==\(core)==" }
            }

            result += String(leadingSpaces) + core + String(trailingSpaces)
        }

        return result
    }

    static func isYellowHighlightColor(_ color: NSColor?) -> Bool {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return false }
        return rgb.redComponent > 0.8 && rgb.greenComponent > 0.65 && rgb.blueComponent < 0.45
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
        if let regex = try? NSRegularExpression(pattern: #"^#{1,6}\s+"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        let inlineReplacements: [(String, String)] = [
            (#"\*\*(.+?)\*\*"#, "$1"),
            (#"__(.+?)__"#, "$1"),
            (#"~~(.+?)~~"#, "$1"),
            (#"==(.+?)=="#, "$1"),
            (#"<u>(.+?)</u>"#, "$1"),
            (#"`([^`]+)`"#, "$1"),
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1")
        ]
        for (pattern, template) in inlineReplacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
