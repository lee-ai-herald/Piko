import Foundation

struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: Codable, Equatable {
        case text(String)
        case image(fileName: String, width: Int, height: Int)
    }

    let id: UUID
    let kind: Kind
    var createdAt: Date
    var isPinned: Bool
    var sourceApp: String?

    init(
        id: UUID = UUID(),
        kind: Kind,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        sourceApp: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.sourceApp = sourceApp
    }

    var textValue: String? {
        if case .text(let value) = kind {
            return value
        }
        return nil
    }

    var searchableText: String {
        switch kind {
        case .text(let value):
            return value
        case .image(_, let width, let height):
            return "图片 image \(width)x\(height) \(sourceApp ?? "")"
        }
    }

    var relativeTimeText: String {
        let seconds = Int(Date().timeIntervalSince(createdAt))
        if seconds < 10 {
            return "刚刚"
        } else if seconds < 60 {
            return "\(seconds) 秒前"
        } else if seconds < 3_600 {
            return "\(seconds / 60) 分钟前"
        } else if seconds < 86_400 {
            return "\(seconds / 3_600) 小时前"
        } else {
            return RmbFormatters.monthDayTime.string(from: createdAt)
        }
    }
}
