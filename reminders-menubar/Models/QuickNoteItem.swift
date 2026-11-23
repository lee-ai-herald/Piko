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
    var title: String
    var content: String
    var rtfData: Data?
    var colorTag: NoteColorTag
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        rtfData: Data? = nil,
        colorTag: NoteColorTag = .yellow,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.rtfData = rtfData
        self.colorTag = colorTag
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let firstLine = content
            .split(whereSeparator: \.isNewline)
            .map { NoteMarkdownConverter.strippedPlainText(String($0)) }
            .first(where: { !$0.isEmpty })
        return firstLine ?? "空白随笔"
    }

    var previewText: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = content
            .split(whereSeparator: \.isNewline)
            .map { NoteMarkdownConverter.strippedPlainText(String($0)) }
            .filter { !$0.isEmpty }

        if trimmedTitle.isEmpty {
            let remaining = Array(lines.dropFirst())
            return remaining.isEmpty ? "暂无更多内容" : remaining.joined(separator: " ")
        } else {
            return lines.isEmpty ? "暂无正文内容" : lines.joined(separator: " ")
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
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d HH:mm"
            return formatter.string(from: updatedAt)
        }
    }
}
