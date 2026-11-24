import Cocoa
import ImageIO
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
    private var pendingSaveWork: DispatchWorkItem?

    private let maxImages = 20
    private let maxTextLength = 512_000
    private let ioQueue = DispatchQueue(label: "piko.clipboard.io", qos: .utility)
    private let thumbnailCache = NSCache<NSString, NSImage>()

    private let storageDirectory: URL
    private let imagesDirectory: URL
    private let historyFileURL: URL

    private init() {
        let baseDir = AppStoragePaths.applicationSupportDirectory
        self.storageDirectory = baseDir
        let imgDir = baseDir.appendingPathComponent("ClipboardImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        self.imagesDirectory = imgDir
        self.historyFileURL = baseDir.appendingPathComponent("clipboard_history.json")
        self.thumbnailCache.countLimit = 40
        self.lastChangeCount = NSPasteboard.general.changeCount

        loadFromDisk()
        cleanupOrphanedImagesAsync()
        startMonitoring()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        let nextTimer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
        nextTimer.tolerance = 0.1
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func flushPendingWrites() {
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        let snapshot = items
        let url = historyFileURL
        ioQueue.sync {
            Self.writeHistory(snapshot, to: url)
        }
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
                let bounded = string.count > maxTextLength ? String(string.prefix(maxTextLength)) : string
                addTextItem(bounded, sourceApp: sourceApp)
                return
            }
        }

        // Fall back to image content: prefer raw PNG bytes directly; encode TIFF off main thread.
        if let pngData = pasteboard.data(forType: .png) {
            persistImageDataOffMainThread(pngData: pngData, tiffData: nil, sourceApp: sourceApp)
        } else if let tiffData = pasteboard.data(forType: .tiff) {
            persistImageDataOffMainThread(pngData: nil, tiffData: tiffData, sourceApp: sourceApp)
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

    private func persistImageDataOffMainThread(pngData: Data?, tiffData: Data?, sourceApp: String?) {
        let fileName = "\(UUID().uuidString).png"
        let fileURL = imagesDirectory.appendingPathComponent(fileName)

        ioQueue.async { [weak self] in
            let resolvedPNG: Data
            let width: Int
            let height: Int

            if let pngData, let bitmap = NSBitmapImageRep(data: pngData) {
                resolvedPNG = pngData
                width = bitmap.pixelsWide
                height = bitmap.pixelsHigh
            } else if let tiffData,
                      let bitmap = NSBitmapImageRep(data: tiffData),
                      let encoded = bitmap.representation(using: .png, properties: [:]) {
                resolvedPNG = encoded
                width = bitmap.pixelsWide
                height = bitmap.pixelsHigh
            } else {
                return
            }

            do {
                try resolvedPNG.write(to: fileURL, options: .atomic)
            } catch {
                return
            }

            let thumb = Self.makeThumbnail(from: fileURL, maxPixelSize: 260)

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let thumb {
                    self.thumbnailCache.setObject(thumb, forKey: fileName as NSString)
                }
                let item = ClipboardItem(
                    kind: .image(fileName: fileName, width: width, height: height),
                    createdAt: Date(),
                    isPinned: false,
                    sourceApp: sourceApp
                )
                self.items.insert(item, at: 0)
                self.trimAndPersist()
            }
        }
    }

    /// Cached downsampled thumbnail for smooth SwiftUI scrolling without synchronous full-res disk decode.
    func thumbnail(for fileName: String) -> NSImage? {
        let key = fileName as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached
        }
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        guard let thumb = Self.makeThumbnail(from: fileURL, maxPixelSize: 260) else {
            return nil
        }
        thumbnailCache.setObject(thumb, forKey: key)
        return thumb
    }

    func image(for fileName: String) -> NSImage? {
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        return NSImage(contentsOf: fileURL)
    }

    // MARK: - Actions

    func copyItem(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general

        switch item.kind {
        case .text(let value):
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        case .image(let fileName, _, _):
            guard let img = image(for: fileName) else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects([img])
        }

        ignoreNextChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount

        // Move item to top of its group
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            var moved = items.remove(at: index)
            moved.createdAt = Date()
            items.insert(moved, at: 0)
            scheduleSave()
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
        scheduleSave()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        removeImageFileIfNeeded(for: item)
        scheduleSave()
    }

    func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }
        items.removeAll { !$0.isPinned }
        removed.forEach { removeImageFileIfNeeded(for: $0) }
        scheduleSave()
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
        scheduleSave()
    }

    private func removeImageFileIfNeeded(for item: ClipboardItem) {
        if case .image(let fileName, _, _) = item.kind {
            thumbnailCache.removeObject(forKey: fileName as NSString)
            let fileURL = imagesDirectory.appendingPathComponent(fileName)
            ioQueue.async {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    private func cleanupOrphanedImagesAsync() {
        let referenced = Set(items.compactMap { item -> String? in
            if case .image(let fileName, _, _) = item.kind { return fileName }
            return nil
        })
        let imgDir = imagesDirectory
        ioQueue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: imgDir, includingPropertiesForKeys: nil) else { return }
            for file in files where !referenced.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: historyFileURL),
              let decoded = try? JSONDecoder().decode([ClipboardItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func scheduleSave() {
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let snapshot = self.items
                let url = self.historyFileURL
                self.ioQueue.async {
                    Self.writeHistory(snapshot, to: url)
                }
            }
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    nonisolated private static func writeHistory(_ snapshot: [ClipboardItem], to url: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    nonisolated private static func makeThumbnail(from url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
    }
}
