import SwiftUI

enum NoteColorTag: String, Codable, CaseIterable, Identifiable {
    case yellow
    case blue
    case green
    case pink
    case purple
    case gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: return "暖黄"
        case .blue: return "晴蓝"
        case .green: return "青绿"
        case .pink: return "樱粉"
        case .purple: return "淡紫"
        case .gray: return "素灰"
        }
    }

    var accentColor: Color {
        switch self {
        case .yellow: return Color(red: 0.90, green: 0.64, blue: 0.12)
        case .blue: return Color(red: 0.22, green: 0.54, blue: 0.95)
        case .green: return Color(red: 0.18, green: 0.69, blue: 0.45)
        case .pink: return Color(red: 0.91, green: 0.36, blue: 0.52)
        case .purple: return Color(red: 0.57, green: 0.40, blue: 0.92)
        case .gray: return Color(red: 0.52, green: 0.56, blue: 0.62)
        }
    }

    var cardTint: Color {
        accentColor.opacity(0.10)
    }

    var paperTint: Color {
        accentColor.opacity(0.055)
    }

    var borderTint: Color {
        accentColor.opacity(0.28)
    }
}

struct QuickNoteItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String {
        didSet { recomputeDerivedText() }
    }
    var content: String {
        didSet { recomputeDerivedText() }
    }
    var rtfData: Data?
    var imageFileNames: [String] {
        didSet { recomputeDerivedText() }
    }
    var colorTag: NoteColorTag
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date
    var revision: Int = 0
    private(set) var displayTitle: String
    private(set) var previewText: String

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case content
        case rtfData
        case imageFileNames
        case colorTag
        case isPinned
        case createdAt
        case updatedAt
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        rtfData: Data? = nil,
        imageFileNames: [String] = [],
        colorTag: NoteColorTag = .yellow,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 0
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.rtfData = rtfData
        self.imageFileNames = imageFileNames
        self.colorTag = colorTag
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        let computed = Self.computeDisplayAndPreview(title: title, content: content, imageCount: imageFileNames.count)
        self.displayTitle = computed.title
        self.previewText = computed.preview
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let content = try container.decode(String.self, forKey: .content)
        let rtfData = try container.decodeIfPresent(Data.self, forKey: .rtfData)
        let imageFileNames = try container.decodeIfPresent([String].self, forKey: .imageFileNames) ?? []
        let colorTag = try container.decode(NoteColorTag.self, forKey: .colorTag)
        let isPinned = try container.decode(Bool.self, forKey: .isPinned)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.init(
            id: id,
            title: title,
            content: content,
            rtfData: rtfData,
            imageFileNames: imageFileNames,
            colorTag: colorTag,
            isPinned: isPinned,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private mutating func recomputeDerivedText() {
        let computed = Self.computeDisplayAndPreview(title: title, content: content, imageCount: imageFileNames.count)
        displayTitle = computed.title
        previewText = computed.preview
    }

    private static func computeDisplayAndPreview(
        title: String,
        content: String,
        imageCount: Int
    ) -> (title: String, preview: String) {
        let trimmedTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        // Bound work to the leading slice so pasting huge single-line notes stays O(1).
        let sample = content.count > 2_400 ? String(content.prefix(2_400)) : content
        let lines = sample
            .split(whereSeparator: \.isNewline)
            .prefix(12)
            .map { NoteMarkdownConverter.strippedPlainText(String($0.prefix(240))) }
            .filter { !$0.isEmpty }

        if trimmedTitle.isEmpty {
            let resolvedTitle = lines.first ?? (imageCount > 0 ? "图片随笔" : "空白随笔")
            let remaining = Array(lines.dropFirst())
            let preview: String
            if !remaining.isEmpty {
                preview = String(remaining.joined(separator: " ").prefix(280))
            } else if imageCount > 0 {
                preview = "包含 \(imageCount) 张图片"
            } else {
                preview = "暂无更多内容"
            }
            return (resolvedTitle, preview)
        } else {
            let preview: String
            if !lines.isEmpty {
                preview = String(lines.joined(separator: " ").prefix(280))
            } else if imageCount > 0 {
                preview = "包含 \(imageCount) 张图片"
            } else {
                preview = "暂无正文内容"
            }
            return (trimmedTitle, preview)
        }
    }

    var fullCopyableText: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            return trimmedContent
        }
        if trimmedContent.isEmpty {
            return trimmedTitle
        }
        return "\(trimmedTitle)\n\n\(trimmedContent)"
    }

    var characterCount: Int {
        title.count + content.count
    }

    var searchableText: String {
        "\(title)\n\(content)"
    }

    var relativeTimeText: String {
        let seconds = Int(Date().timeIntervalSince(updatedAt))
        if seconds < 60 {
            return "刚刚"
        } else if seconds < 3_600 {
            return "\(seconds / 60) 分钟前"
        } else if seconds < 86_400 {
            return "\(seconds / 3_600) 小时前"
        } else {
            return RmbFormatters.monthDayTime.string(from: updatedAt)
        }
    }
}
