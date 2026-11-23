import Cocoa
import SwiftUI

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var items: [ClipboardItem] = []
    @Published var lastCopiedItemId: UUID?

    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoreNextChangeCount: Int?
    private var copiedToastWork: DispatchWorkItem?

    private let maxImages = 20

    private var storageDirectory: URL {
        AppStoragePaths.applicationSupportDirectory
    }

    private var imagesDirectory: URL {
        let dir = storageDirectory.appendingPathComponent("ClipboardImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var historyFileURL: URL {
        storageDirectory.appendingPathComponent("clipboard_history.json")
    }

    private init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
        loadFromDisk()
        startMonitoring()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if ignoreNextChangeCount == currentCount {
            ignoreNextChangeCount = nil
            return
        }

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName

        // Prefer plain string content when present
        if let string = pasteboard.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                addTextItem(string, sourceApp: sourceApp)
                return
            }
        }

        // Fall back to image content
        if let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            addImageItem(pngData: pngData, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, sourceApp: sourceApp)
        }
    }

    private func addTextItem(_ text: String, sourceApp: String?) {
        var wasPinned = false
        if let existingIndex = items.firstIndex(where: { $0.textValue == text }) {
            wasPinned = items[existingIndex].isPinned
            items.remove(at: existingIndex)
        }

        let item = ClipboardItem(
            kind: .text(text),
            createdAt: Date(),
            isPinned: wasPinned,
            sourceApp: sourceApp
        )
        items.insert(item, at: 0)
        trimAndPersist()
    }

    private func addImageItem(pngData: Data, width: Int, height: Int, sourceApp: String?) {
        let fileName = "\(UUID().uuidString).png"
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            return
        }

        let item = ClipboardItem(
            kind: .image(fileName: fileName, width: width, height: height),
            createdAt: Date(),
            isPinned: false,
            sourceApp: sourceApp
        )
        items.insert(item, at: 0)
        trimAndPersist()
    }

    func image(for fileName: String) -> NSImage? {
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        return NSImage(contentsOf: fileURL)
    }

    // MARK: - Actions

    func copyItem(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text(let value):
            pasteboard.setString(value, forType: .string)
        case .image(let fileName, _, _):
            if let img = image(for: fileName) {
                pasteboard.writeObjects([img])
            }
        }

        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        // Move item to top of its group
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var moved = items.remove(at: index)
            moved.createdAt = Date()
            items.insert(moved, at: 0)
            saveToDisk()
        }

        lastCopiedItemId = item.id
        copiedToastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                if self?.lastCopiedItemId == item.id {
                    self?.lastCopiedItemId = nil
                }
            }
        }
        copiedToastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        saveToDisk()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        removeImageFileIfNeeded(for: item)
        saveToDisk()
    }

    func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }
        items.removeAll { !$0.isPinned }
        removed.forEach { removeImageFileIfNeeded(for: $0) }
        saveToDisk()
    }

    var sortedItems: [ClipboardItem] {
        let pinned = items.filter(\.isPinned)
        let regular = items.filter { !$0.isPinned }
        return pinned + regular
    }

    // MARK: - Persistence

    private func trimAndPersist() {
        let maxCount = max(20, UserPreferences.shared.clipboardMaxItems)
        var unpinnedCount = 0
        var imageCount = 0
        var kept: [ClipboardItem] = []

        for item in items {
            if item.isPinned {
                kept.append(item)
                continue
            }

            if case .image = item.kind {
                imageCount += 1
                if imageCount > maxImages {
                    removeImageFileIfNeeded(for: item)
                    continue
                }
            }

            unpinnedCount += 1
            if unpinnedCount <= maxCount {
                kept.append(item)
            } else {
                removeImageFileIfNeeded(for: item)
            }
        }

        items = kept
        saveToDisk()
    }

    private func removeImageFileIfNeeded(for item: ClipboardItem) {
        if case .image(let fileName, _, _) = item.kind {
            try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(fileName))
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: historyFileURL, options: .atomic)
    }
}
