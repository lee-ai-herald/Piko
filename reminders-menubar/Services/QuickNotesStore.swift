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
    private let ioQueue = DispatchQueue(label: "piko.notes.io", qos: .utility)
    private let notesFileURL: URL

    private init() {
        self.notesFileURL = AppStoragePaths.applicationSupportDirectory.appendingPathComponent("quick_notes.json")
        loadFromDisk()
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
        notes.removeAll { $0.id == id }
        lastEditOriginByNoteId.removeValue(forKey: id)
        if selectedNoteId == id {
            selectedNoteId = sortedNotes.first?.id
        }
        scheduleSave(immediate: true)
    }

    func copyNote(_ note: QuickNoteItem) {
        let text = note.fullCopyableText
        guard !text.isEmpty else { return }
        writeToPasteboardAndToast(text, noteId: note.id)
    }

    func copyNoteAsMarkdown(_ note: QuickNoteItem) {
        let bodyMd = NoteMarkdownConverter.markdownSource(for: note).trimmingCharacters(in: .whitespacesAndNewlines)
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
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
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
        let delay: TimeInterval = immediate ? 0.05 : 0.40
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
