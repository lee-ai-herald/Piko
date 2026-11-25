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
    var imageHash: String?

    /// Precomputed display/search metadata so SwiftUI row rendering & filtering never scan 512KB strings.
    let previewText: String
    let characterCount: Int
    private let searchSample: String

    private enum CodingKeys: String, CodingKey {
        case id, kind, createdAt, isPinned, sourceApp, imageHash
    }

    init(
        id: UUID = UUID(),
        kind: Kind,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        sourceApp: String? = nil,
        imageHash: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.sourceApp = sourceApp
        self.imageHash = imageHash
        let meta = Self.buildMetadata(kind: kind, sourceApp: sourceApp)
        self.previewText = meta.preview
        self.characterCount = meta.charCount
        self.searchSample = meta.searchSample
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let isPinned = try container.decode(Bool.self, forKey: .isPinned)
        let sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        let imageHash = try container.decodeIfPresent(String.self, forKey: .imageHash)
        self.init(
            id: id,
            kind: kind,
            createdAt: createdAt,
            isPinned: isPinned,
            sourceApp: sourceApp,
            imageHash: imageHash
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encodeIfPresent(imageHash, forKey: .imageHash)
    }

    var textValue: String? {
        if case .text(let value) = kind {
            return value
        }
        return nil
    }

    func matches(query: String) -> Bool {
        if searchSample.localizedCaseInsensitiveContains(query) {
            return true
        }
        if let sourceApp, sourceApp.localizedCaseInsensitiveContains(query) {
            return true
        }
        return false
    }

    private static func buildMetadata(
        kind: Kind,
        sourceApp: String?
    ) -> (preview: String, charCount: Int, searchSample: String) {
        switch kind {
        case .text(let value):
            let head = value.prefix(1_024).trimmingCharacters(in: .whitespacesAndNewlines)
            let preview: String
            if head.count > 320 {
                preview = String(head.prefix(320)) + "…"
            } else if !head.isEmpty {
                preview = head
            } else {
                preview = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(320))
            }
            let sample = value.utf8.count > 65_536 ? String(value.prefix(32_768)) : value
            return (preview, value.count, sample)
        case .image(_, let width, let height):
            return ("", 0, "图片 image \(width)x\(height) \(sourceApp ?? "")")
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
