import Cocoa
import SwiftUI

@MainActor
final class QuickNotesStore: ObservableObject {
    static let shared = QuickNotesStore()

    @Published private(set) var notes: [QuickNoteItem] = []
    @Published var selectedNoteId: UUID?
    @Published var lastCopiedNoteId: UUID?

    /// Tracks which editor instance originated the most recent mutation to a note so that
    /// the originating `NSTextView` skips redundant reloads while the paired window syncs full RTF.
    private(set) var lastEditOriginByNoteId: [UUID: UUID] = [:]

    private var copiedToastWork: DispatchWorkItem?
    private var pendingSaveWork: DispatchWorkItem?
    private var hasPendingSave = false
    private let ioQueue = DispatchQueue(label: "piko.notes.io", qos: .utility)
    private let notesFileURL: URL
    private let imagesDirectory: URL
    private let imageCache = NSCache<NSString, NSImage>()
    private static let maxImageEdgePixels: CGFloat = 2400

    private init() {
        let baseDir = AppStoragePaths.applicationSupportDirectory
        self.notesFileURL = baseDir.appendingPathComponent("quick_notes.json")
        let imgDir = baseDir.appendingPathComponent("NoteImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        self.imagesDirectory = imgDir
        self.imageCache.countLimit = 60
        loadFromDisk()
        cleanupOrphanedImagesAsync()
        selectedNoteId = sortedNotes.first?.id
    }

    var sortedNotes: [QuickNoteItem] {
        notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var selectedNote: QuickNoteItem? {
        if let selectedNoteId, let found = notes.first(where: { $0.id == selectedNoteId }) {
            return found
        }
        return sortedNotes.first
    }

    @discardableResult
    func createNote(
        title: String = "",
        content: String = "",
        colorTag: NoteColorTag? = nil
    ) -> QuickNoteItem {
        let note = QuickNoteItem(
            title: title,
            content: content,
            colorTag: colorTag ?? UserPreferences.shared.defaultNoteColorTag
        )
        notes.insert(note, at: 0)
        selectedNoteId = note.id
        scheduleSave(immediate: true)
        return note
    }

    func updateNote(
        id: UUID,
        title: String? = nil,
        content: String? = nil,
        rtfData: Data?? = nil,
        imageFileNames: [String]? = nil,
        colorTag: NoteColorTag? = nil,
        originEditorId: UUID? = nil
    ) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        var bodyChanged = false
        if let title, notes[index].title != title {
            notes[index].title = title
            changed = true
        }
        if let content, notes[index].content != content {
            notes[index].content = content
            changed = true
            bodyChanged = true
        }
        if let rtfData, notes[index].rtfData != rtfData {
            notes[index].rtfData = rtfData
            changed = true
            bodyChanged = true
        }
        if let imageFileNames, notes[index].imageFileNames != imageFileNames {
            notes[index].imageFileNames = imageFileNames
            changed = true
            bodyChanged = true
        }
        if let colorTag, notes[index].colorTag != colorTag {
            notes[index].colorTag = colorTag
            changed = true
        }
        if changed {
            if bodyChanged {
                notes[index].revision += 1
                if let originEditorId {
                    lastEditOriginByNoteId[id] = originEditorId
                } else {
                    lastEditOriginByNoteId.removeValue(forKey: id)
                }
            }
            notes[index].updatedAt = Date()
            scheduleSave(immediate: !bodyChanged)
        }
    }

    func togglePin(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        scheduleSave(immediate: true)
    }

    func deleteNote(id: UUID) {
        let removedImages = notes.first(where: { $0.id == id })?.imageFileNames ?? []
        notes.removeAll { $0.id == id }
        lastEditOriginByNoteId.removeValue(forKey: id)
        if selectedNoteId == id {
            selectedNoteId = sortedNotes.first?.id
        }
        scheduleSave(immediate: true)
        if !removedImages.isEmpty {
            let stillReferenced = Set(notes.flatMap(\.imageFileNames))
            let unreferenced = removedImages.filter { !stillReferenced.contains($0) }
            removeImageFilesAsync(unreferenced)
        }
    }

    // MARK: - Inline Note Images

    func imageURL(for fileName: String) -> URL {
        imagesDirectory.appendingPathComponent(fileName)
    }

    func image(for fileName: String) -> NSImage? {
        let key = fileName as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        let url = imageURL(for: fileName)
        guard let loaded = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(loaded, forKey: key)
        return loaded
    }

    /// Caches the image immediately for 0ms paste responsiveness and writes the PNG asynchronously on serial `ioQueue`.
    func storeImage(_ rawImage: NSImage, rawPNGData: Data? = nil) -> (fileName: String, image: NSImage)? {
        guard rawImage.size.width > 0, rawImage.size.height > 0 else { return nil }

        let (displayImage, pngBytes, cgForAsyncPNG) = Self.prepareImageForStorage(
            rawImage,
            rawPNGData: rawPNGData,
            maxEdgePixels: Self.maxImageEdgePixels
        )
        let fileName = "\(UUID().uuidString).png"
        let fileURL = imageURL(for: fileName)
        imageCache.setObject(displayImage, forKey: fileName as NSString)

        if let pngBytes {
            ioQueue.async {
                try? pngBytes.write(to: fileURL, options: .atomic)
            }
        } else if let cgForAsyncPNG {
            ioQueue.async {
                let rep = NSBitmapImageRep(cgImage: cgForAsyncPNG)
                guard let encoded = rep.representation(using: .png, properties: [:]) else { return }
                try? encoded.write(to: fileURL, options: .atomic)
            }
        } else if let tiff = displayImage.tiffRepresentation {
            ioQueue.async {
                guard let rep = NSBitmapImageRep(data: tiff),
                      let encoded = rep.representation(using: .png, properties: [:]) else { return }
                try? encoded.write(to: fileURL, options: .atomic)
            }
        }
        return (fileName, displayImage)
    }

    private func removeImageFilesAsync(_ fileNames: [String]) {
        guard !fileNames.isEmpty else { return }
        for name in fileNames {
            imageCache.removeObject(forKey: name as NSString)
        }
        let urls = fileNames.map { imageURL(for: $0) }
        ioQueue.async {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func cleanupOrphanedImagesAsync() {
        let referenced = Set(notes.flatMap(\.imageFileNames))
        let imgDir = imagesDirectory
        ioQueue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: imgDir, includingPropertiesForKeys: nil) else { return }
            for file in files where !referenced.contains(file.lastPathComponent) {
                try? fm.removeItem(at: file)
            }
        }
    }

    nonisolated private static func prepareImageForStorage(
        _ image: NSImage,
        rawPNGData: Data?,
        maxEdgePixels: CGFloat
    ) -> (NSImage, Data?, CGImage?) {
        // Determine backing pixel dimensions so Retina screenshots stay sharp without exploding file sizes.
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return (image, rawPNGData, nil)
        }

        let pxW = CGFloat(cgImage.width)
        let pxH = CGFloat(cgImage.height)
        let maxDim = max(pxW, pxH)

        if maxDim <= maxEdgePixels {
            // Keep original PNG bytes when already compact; defer TIFF->PNG encoding to `ioQueue`.
            let pointSize = (image.size.width > 0 && image.size.height > 0)
                ? image.size
                : NSSize(width: pxW, height: pxH)
            let normalized = NSImage(cgImage: cgImage, size: pointSize)
            return (normalized, rawPNGData, rawPNGData == nil ? cgImage : nil)
        }

        let scale = maxEdgePixels / maxDim
        let newW = max(1, Int((pxW * scale).rounded()))
        let newH = max(1, Int((pxH * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: newW,
            pixelsHigh: newH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return (image, rawPNGData, rawPNGData == nil ? cgImage : nil)
        }
        rep.size = NSSize(width: CGFloat(newW), height: CGFloat(newH))

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            NSImage(cgImage: cgImage, size: NSSize(width: pxW, height: pxH)).draw(
                in: NSRect(x: 0, y: 0, width: CGFloat(newW), height: CGFloat(newH)),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let downscaled = NSImage(size: NSSize(width: CGFloat(newW) / 2, height: CGFloat(newH) / 2))
        downscaled.addRepresentation(rep)
        return (downscaled, nil, rep.cgImage)
    }

    func copyNote(_ note: QuickNoteItem) {
        let text = note.fullCopyableText
        guard !text.isEmpty else { return }
        writeToPasteboardAndToast(text, noteId: note.id)
    }

    func copyNoteAsMarkdown(_ note: QuickNoteItem) {
        let bodyMd = NoteMarkdownConverter.markdownSource(
            for: note,
            imageURLResolver: { [weak self] name in
                self?.imageURL(for: name)
            }
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined: String
        if trimmedTitle.isEmpty {
            combined = bodyMd
        } else if bodyMd.isEmpty {
            combined = "# \(trimmedTitle)"
        } else {
            combined = "# \(trimmedTitle)\n\n\(bodyMd)"
        }
        guard !combined.isEmpty else { return }
        writeToPasteboardAndToast(combined, noteId: note.id)
    }

    func flushPendingSave() {
        guard hasPendingSave else { return }
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        hasPendingSave = false
        let snapshot = notes
        let url = notesFileURL
        ioQueue.sync {
            Self.writeNotes(snapshot, to: url)
        }
    }

    private func writeToPasteboardAndToast(_ text: String, noteId: UUID) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        lastCopiedNoteId = noteId
        copiedToastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                if self?.lastCopiedNoteId == noteId {
                    self?.lastCopiedNoteId = nil
                }
            }
        }
        copiedToastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: notesFileURL),
              let decoded = try? JSONDecoder().decode([QuickNoteItem].self, from: data) else {
            return
        }
        notes = decoded
    }

    private func scheduleSave(immediate: Bool) {
        pendingSaveWork?.cancel()
        hasPendingSave = true
        let delay: TimeInterval = immediate ? 0.05 : 0.40
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pendingSaveWork === work else { return }
                self.pendingSaveWork = nil
                self.hasPendingSave = false
                let snapshot = self.notes
                let url = self.notesFileURL
                self.ioQueue.async {
                    Self.writeNotes(snapshot, to: url)
                }
            }
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    nonisolated private static func writeNotes(_ snapshot: [QuickNoteItem], to url: URL) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
