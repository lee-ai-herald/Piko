import Cocoa
import SwiftUI

@MainActor
final class QuickNotesStore: ObservableObject {
    static let shared = QuickNotesStore()

    @Published private(set) var notes: [QuickNoteItem] = []
    @Published var selectedNoteId: UUID?
    @Published var lastCopiedNoteId: UUID?

    private var copiedToastWork: DispatchWorkItem?

    private var storageDirectory: URL {
        AppStoragePaths.applicationSupportDirectory
    }

    private var notesFileURL: URL {
        storageDirectory.appendingPathComponent("quick_notes.json")
    }

    private init() {
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
        saveToDisk()
        return note
    }

    func updateNote(
        id: UUID,
        title: String? = nil,
        content: String? = nil,
        rtfData: Data?? = nil,
        colorTag: NoteColorTag? = nil
    ) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var changed = false
        if let title, notes[index].title != title {
            notes[index].title = title
            changed = true
        }
        if let content, notes[index].content != content {
            notes[index].content = content
            changed = true
        }
        if let rtfData, notes[index].rtfData != rtfData {
            notes[index].rtfData = rtfData
            changed = true
        }
        if let colorTag, notes[index].colorTag != colorTag {
            notes[index].colorTag = colorTag
            changed = true
        }
        if changed {
            notes[index].updatedAt = Date()
            saveToDisk()
        }
    }

    func togglePin(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        saveToDisk()
    }

    func deleteNote(id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedNoteId == id {
            selectedNoteId = sortedNotes.first?.id
        }
        saveToDisk()
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

    func toggleCheckbox(inNoteId id: UUID, atLineIndex lineIndex: Int) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var lines = notes[index].content.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return }

        let originalLine = lines[lineIndex]
        let updatedLine: String
        if let range = originalLine.range(of: "[ ]") {
            updatedLine = originalLine.replacingCharacters(in: range, with: "[x]")
        } else if let range = originalLine.range(of: "[x]") {
            updatedLine = originalLine.replacingCharacters(in: range, with: "[ ]")
        } else if let range = originalLine.range(of: "[X]") {
            updatedLine = originalLine.replacingCharacters(in: range, with: "[ ]")
        } else {
            return
        }

        lines[lineIndex] = updatedLine
        let newPlain = lines.joined(separator: "\n")
        notes[index].content = newPlain

        // Also keep RTF text in sync if present
        if let rtfData = notes[index].rtfData,
           let mutable = NSMutableAttributedString(rtf: rtfData, documentAttributes: nil) {
            let nsStr = mutable.string as NSString
            var currentLine = 0
            var loc = 0
            while loc <= nsStr.length {
                let lr = nsStr.lineRange(for: NSRange(location: loc, length: 0))
                if currentLine == lineIndex {
                    let sub = nsStr.substring(with: lr)
                    let target: (String, String)? = {
                        if sub.contains("[ ]") { return ("[ ]", "[x]") }
                        if sub.contains("[x]") { return ("[x]", "[ ]") }
                        if sub.contains("[X]") { return ("[X]", "[ ]") }
                        return nil
                    }()
                    if let (from, to) = target {
                        let found = (sub as NSString).range(of: from)
                        if found.location != NSNotFound {
                            let replaceRange = NSRange(location: lr.location + found.location, length: found.length)
                            mutable.replaceCharacters(in: replaceRange, with: to)
                            notes[index].rtfData = try? mutable.data(
                                from: NSRange(location: 0, length: mutable.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                            )
                        }
                    }
                    break
                }
                let next = NSMaxRange(lr)
                if next <= loc || next >= nsStr.length { break }
                loc = next
                currentLine += 1
            }
        }

        notes[index].updatedAt = Date()
        saveToDisk()
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

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: notesFileURL, options: .atomic)
    }
}
