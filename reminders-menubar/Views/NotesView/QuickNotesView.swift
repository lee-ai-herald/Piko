import SwiftUI

// MARK: - Full Workspace Quick Notes View (随笔记事)

@MainActor
struct QuickNotesView: View {
    var isActiveTab: Bool = true

    @ObservedObject private var store = QuickNotesStore.shared
    @State private var searchText = ""
    @State private var showPinnedOnly = false
    @State private var compactShowingEditor = false

    private var filteredNotes: [QuickNoteItem] {
        let base = showPinnedOnly ? store.sortedNotes.filter(\.isPinned) : store.sortedNotes
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return base }
        return base.filter { $0.searchableText.lowercased().contains(query) }
    }

    private var activeNote: QuickNoteItem? {
        if let id = store.selectedNoteId, let found = store.notes.first(where: { $0.id == id }) {
            return found
        }
        return filteredNotes.first ?? store.sortedNotes.first
    }

    var body: some View {
        GeometryReader { geo in
            if geo.size.width >= 520 {
                let sidebarWidth = max(210, min(268, geo.size.width * 0.34))
                HStack(spacing: 0) {
                    noteListSidebar(isCompactMode: false)
                        .frame(width: sidebarWidth)

                    Divider().opacity(0.42)

                    if let note = activeNote {
                        NoteEditorPane(note: note, isMiniMode: false, isActiveTab: isActiveTab, onBackToList: nil)
                            .id(note.id)
                    } else {
                        emptyEditorPlaceholder
                    }
                }
            } else {
                if compactShowingEditor, let note = activeNote {
                    NoteEditorPane(note: note, isMiniMode: false, isActiveTab: isActiveTab) {
                        compactShowingEditor = false
                    }
                    .id(note.id)
                } else {
                    noteListSidebar(isCompactMode: true)
                }
            }
        }
        .onAppear {
            if store.selectedNoteId == nil {
                store.selectedNoteId = store.sortedNotes.first?.id
            }
        }
    }

    private func noteListSidebar(isCompactMode: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)

                        TextField("搜索随笔…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))

                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )

                    Button {
                        showPinnedOnly.toggle()
                    } label: {
                        Image(systemName: showPinnedOnly ? "pin.fill" : "pin")
                            .font(.system(size: 11))
                            .foregroundColor(showPinnedOnly ? NoteColorTag.yellow.accentColor : .secondary)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(showPinnedOnly ? NoteColorTag.yellow.accentColor.opacity(0.15) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showPinnedOnly ? "显示全部随笔" : "只看已置顶")
                }

                Button {
                    searchText = ""
                    showPinnedOnly = false
                    let created = store.createNote()
                    store.selectedNoteId = created.id
                    if isCompactMode {
                        compactShowingEditor = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text("新建便签随笔")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .fill(NoteColorTag.yellow.accentColor)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)

            Divider().opacity(0.38)

            if filteredNotes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.55))
                    Text(searchText.isEmpty ? "暂无随笔记录" : "没有找到匹配的随笔")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.primary)
                    Text(searchText.isEmpty ? "点击上方按钮新建一张便签" : "换个关键词试试")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredNotes) { note in
                            QuickNoteCardRow(
                                note: note,
                                isSelected: activeNote?.id == note.id && !isCompactMode
                            ) {
                                store.selectedNoteId = note.id
                                if isCompactMode {
                                    compactShowingEditor = true
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color.primary.opacity(0.015))
    }

    private var emptyEditorPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(NoteColorTag.yellow.accentColor.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: "note.text.badge.plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(NoteColorTag.yellow.accentColor)
            }

            Text("随时记录灵感与备忘")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            Text("像桌面便签一样，记录临时信息、会议要点、常用命令或草稿，自动保存不丢失。")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)

            Button {
                let created = store.createNote()
                store.selectedNoteId = created.id
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("写下第一条随笔")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(NoteColorTag.yellow.accentColor))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Sidebar Note Card Row

@MainActor
private struct QuickNoteCardRow: View {
    let note: QuickNoteItem
    let isSelected: Bool
    let onSelect: () -> Void

    @ObservedObject private var store = QuickNotesStore.shared
    @State private var isHovered = false

    private var isJustCopied: Bool {
        store.lastCopiedNoteId == note.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(note.colorTag.accentColor)
                .frame(width: 3)
                .padding(.vertical, 5)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 5) {
                    if note.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                            .foregroundColor(note.colorTag.accentColor)
                    }

                    Text(note.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if isJustCopied {
                        Text("已复制")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(.green)
                    } else if isHovered {
                        HStack(spacing: 3) {
                            Button {
                                store.copyNote(note)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9.5))
                                    .foregroundColor(.secondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("复制全文")

                            Button {
                                store.deleteNote(id: note.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("删除随笔")
                        }
                    }
                }

                Text(note.previewText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Text(note.relativeTimeText)
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary.opacity(0.8))

                    if note.characterCount > 0 {
                        Text("· \(note.characterCount) 字")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary.opacity(0.75))
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .fill(
                    isSelected
                        ? note.colorTag.accentColor.opacity(0.16)
                        : (isHovered ? note.colorTag.accentColor.opacity(0.12) : note.colorTag.cardTint)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .strokeBorder(
                    isSelected ? note.colorTag.accentColor.opacity(0.65) : note.colorTag.borderTint,
                    lineWidth: isSelected ? 1.15 : 0.75
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(note.isPinned ? "取消置顶" : "置顶便签") {
                store.togglePin(id: note.id)
            }
            Menu("切换便签颜色") {
                ForEach(NoteColorTag.allCases) { color in
                    Button {
                        store.updateNote(id: note.id, colorTag: color)
                    } label: {
                        HStack {
                            Text(color.title)
                            if note.colorTag == color {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Button("复制全文") {
                store.copyNote(note)
            }
            Button("复制为 Markdown") {
                store.copyNoteAsMarkdown(note)
            }
            Button("添加到规划板") {
                let text = note.fullCopyableText
                if !text.isEmpty {
                    PinnedRemindersStore.shared.quickCreateFromSelection(text, splitByLine: false)
                }
            }
            Divider()
            Button("删除随笔", role: .destructive) {
                store.deleteNote(id: note.id)
            }
        }
    }
}

// MARK: - Sticky Note Editor Pane (Shared between Full & Mini Views)

@MainActor
private struct NoteEditorPane: View {
    let note: QuickNoteItem
    let isMiniMode: Bool
    let isActiveTab: Bool
    let onBackToList: (() -> Void)?
    var onCreateNote: (() -> Void)? = nil

    @ObservedObject private var store = QuickNotesStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared
    @StateObject private var formattingController = NoteFormattingController()
    @State private var titleText: String
    @State private var bodyText: String
    @State private var selectedText = ""
    @State private var sentToBoardMessage: String?
    @State private var toastWorkItem: DispatchWorkItem?

    private var selectedNonEmptyLineCount: Int {
        selectedText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    init(
        note: QuickNoteItem,
        isMiniMode: Bool,
        isActiveTab: Bool = true,
        onBackToList: (() -> Void)?,
        onCreateNote: (() -> Void)? = nil
    ) {
        self.note = note
        self.isMiniMode = isMiniMode
        self.isActiveTab = isActiveTab
        self.onBackToList = onBackToList
        self.onCreateNote = onCreateNote
        _titleText = State(initialValue: note.title)
        _bodyText = State(initialValue: note.content)
    }

    private var liveNote: QuickNoteItem {
        store.notes.first(where: { $0.id == note.id }) ?? note
    }

    private var isJustCopied: Bool {
        store.lastCopiedNoteId == note.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Single compact top toolbar (merged in mini mode so writing area stays tall & open)
            topToolbar

            Divider().opacity(0.28)

            // Seamless sticky-note paper: Title flows directly into WYSIWYG Body
            TextField("便签标题（可选）", text: $titleText)
                .textFieldStyle(.plain)
                .font(.system(size: isMiniMode ? 13.5 : 15.5, weight: .semibold))
                .foregroundColor(.primary)
                .padding(.horizontal, isMiniMode ? 12 : 16)
                .padding(.top, isMiniMode ? 10 : 14)
                .padding(.bottom, 4)
                .onChange(of: titleText) { newValue in
                    store.updateNote(id: note.id, title: newValue)
                }

            PlaceholderNoteTextView(
                text: $bodyText,
                placeholder: userPreferences.isNoteMarkdownEnabled
                    ? "支持 Markdown 所写即所见：# 标题、- [ ] 待办、**加粗**、==标黄==、`代码`"
                    : "随便记点什么… 选中文字可加粗、标黄或加入规划板",
                fontSize: isMiniMode ? 12.5 : 13,
                horizontalInset: isMiniMode ? 8 : 12,
                verticalInset: 4,
                lineSpacing: 3.5,
                isRichTextEnabled: true,
                isLiveMarkdownEnabled: userPreferences.isNoteMarkdownEnabled,
                isActive: isActiveTab,
                initialRTFData: liveNote.rtfData,
                formattingController: formattingController,
                onRichTextChanged: { plain, rtf in
                    store.updateNote(id: note.id, content: plain, rtfData: .some(rtf))
                },
                onSelectionChanged: { selected in
                    selectedText = selected
                },
                onSendSelectionToBoard: { selected, splitByLine in
                    sendTextToBoard(selected, splitByLine: splitByLine)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.24)

            // Integrated Bottom Bar: Formatting Controls + Selection-to-Board / Status
            bottomIntegratedBar
        }
        .background(liveNote.colorTag.paperTint)
        .onChange(of: liveNote.title) { external in
            if external != titleText { titleText = external }
        }
        .onChange(of: liveNote.content) { external in
            if external != bodyText { bodyText = external }
        }
    }

    // MARK: - Top Toolbar (Merged Single Row in Mini Mode)

    private var topToolbar: some View {
        HStack(spacing: isMiniMode ? 5 : 8) {
            if isMiniMode {
                if let onBackToList {
                    Button(action: onBackToList) {
                        HStack(spacing: 3.5) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("全部 (\(store.notes.count))")
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 3.5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.065)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看全部随笔")
                }

                // Compact color picker menu in mini mode
                Menu {
                    ForEach(NoteColorTag.allCases) { tag in
                        Button {
                            store.updateNote(id: note.id, colorTag: tag)
                        } label: {
                            HStack {
                                Text(tag.title)
                                if liveNote.colorTag == tag {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(liveNote.colorTag.accentColor)
                            .frame(width: 12, height: 12)
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.2)
                            .frame(width: 17, height: 17)
                    }
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换便签颜色（当前：\(liveNote.colorTag.title)）")
            } else {
                if let onBackToList {
                    Button(action: onBackToList) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .semibold))
                            Text("全部随笔")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Full 6 sticky-note color dots in wide window
                HStack(spacing: 5) {
                    ForEach(NoteColorTag.allCases) { tag in
                        let selected = liveNote.colorTag == tag
                        Button {
                            store.updateNote(id: note.id, colorTag: tag)
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(tag.accentColor)
                                    .frame(width: selected ? 13 : 11, height: selected ? 13 : 11)
                                if selected {
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                                        .frame(width: 17, height: 17)
                                }
                            }
                            .frame(width: 18, height: 18)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("便签颜色：\(tag.title)")
                    }
                }
            }

            Spacer(minLength: 4)

            if isMiniMode, let onCreateNote {
                Button(action: onCreateNote) {
                    HStack(spacing: 2.5) {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text("新建")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(liveNote.colorTag.accentColor))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("新建便签随笔")
            }

            Button {
                userPreferences.isNoteMarkdownEnabled.toggle()
            } label: {
                HStack(spacing: 3) {
                    Circle()
                        .fill(userPreferences.isNoteMarkdownEnabled ? liveNote.colorTag.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text("MD")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                }
                .foregroundColor(userPreferences.isNoteMarkdownEnabled ? liveNote.colorTag.accentColor : .secondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(userPreferences.isNoteMarkdownEnabled ? liveNote.colorTag.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .strokeBorder(
                            userPreferences.isNoteMarkdownEnabled ? liveNote.colorTag.accentColor.opacity(0.35) : Color.clear,
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(userPreferences.isNoteMarkdownEnabled
                  ? "Markdown 所写即所见：已开启（点击关闭）"
                  : "Markdown 所写即所见：已关闭（点击开启）")

            Button {
                store.togglePin(id: note.id)
            } label: {
                Image(systemName: liveNote.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10.5))
                    .foregroundColor(liveNote.isPinned ? liveNote.colorTag.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5.5)
                            .fill(liveNote.isPinned ? liveNote.colorTag.accentColor.opacity(0.16) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(liveNote.isPinned ? "取消置顶" : "置顶便签")

            Button {
                store.copyNote(liveNote)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isJustCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                    if isJustCopied && !isMiniMode {
                        Text("已复制")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .foregroundColor(isJustCopied ? .green : .secondary)
                .padding(.horizontal, isJustCopied && !isMiniMode ? 6 : 5)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5.5)
                        .fill(isJustCopied ? Color.green.opacity(0.14) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isJustCopied ? "已复制全文" : "复制全文")

            Button {
                store.deleteNote(id: note.id)
                if !isMiniMode, onBackToList != nil {
                    onBackToList?()
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("删除随笔")
        }
        .padding(.horizontal, isMiniMode ? 9 : 14)
        .padding(.vertical, isMiniMode ? 6 : 8)
        .background(liveNote.colorTag.accentColor.opacity(0.08))
    }

    // MARK: - Integrated Bottom Bar (Format Tools + Selection-to-Board / Auto-Save)

    private var bottomIntegratedBar: some View {
        let format = formattingController.activeFormat
        let btnW: CGFloat = isMiniMode ? 21 : 23

        return HStack(spacing: isMiniMode ? 3 : 5) {
            // Left: Sleek Rich-Text Format Cluster + WYSIWYG Block Menu
            HStack(spacing: 2) {
                NoteFormatToggleButton(
                    symbol: "bold",
                    width: btnW,
                    isActive: format.isBold,
                    activeFill: liveNote.colorTag.accentColor.opacity(0.22),
                    activeForeground: liveNote.colorTag.accentColor,
                    helpText: "加粗 (⌘B / **文字**)"
                ) {
                    formattingController.apply(.toggleBold)
                }

                NoteFormatToggleButton(
                    symbol: "italic",
                    width: btnW,
                    isActive: format.isItalic,
                    activeFill: liveNote.colorTag.accentColor.opacity(0.22),
                    activeForeground: liveNote.colorTag.accentColor,
                    helpText: "斜体 (⌘I / *文字*)"
                ) {
                    formattingController.apply(.toggleItalic)
                }

                NoteFormatToggleButton(
                    symbol: "underline",
                    width: btnW,
                    isActive: format.isUnderlined,
                    activeFill: liveNote.colorTag.accentColor.opacity(0.22),
                    activeForeground: liveNote.colorTag.accentColor,
                    helpText: "下划线 (⌘U)"
                ) {
                    formattingController.apply(.toggleUnderline)
                }

                NoteFormatToggleButton(
                    symbol: "strikethrough",
                    width: btnW,
                    isActive: format.isStrikethrough,
                    activeFill: liveNote.colorTag.accentColor.opacity(0.22),
                    activeForeground: liveNote.colorTag.accentColor,
                    helpText: "删除线 (⇧⌘X / ~~文字~~)"
                ) {
                    formattingController.apply(.toggleStrikethrough)
                }

                // Yellow Highlighter Button with permanent subtle warm-yellow indicator line
                NoteHighlightToggleButton(
                    isActive: format.isHighlighted,
                    width: btnW
                ) {
                    formattingController.apply(.toggleHighlight)
                }

                // WYSIWYG Block / Heading / Checklist Insert Menu
                if userPreferences.isNoteMarkdownEnabled {
                    Menu {
                        Button("大标题  (# + 空格)") {
                            formattingController.apply(.insertMarkdown(.heading1))
                        }
                        Button("副标题  (## + 空格)") {
                            formattingController.apply(.insertMarkdown(.heading2))
                        }
                        Button("小标题  (### + 空格)") {
                            formattingController.apply(.insertMarkdown(.heading3))
                        }
                        Divider()
                        Button("可勾选待办  (- [ ] + 空格)") {
                            formattingController.apply(.insertMarkdown(.checkbox))
                        }
                        Button("圆点列表  (- + 空格)") {
                            formattingController.apply(.insertMarkdown(.bullet))
                        }
                        Button("引用块  (> + 空格)") {
                            formattingController.apply(.insertMarkdown(.quote))
                        }
                        Button("行内代码  (`代码`)") {
                            formattingController.apply(.insertMarkdown(.inlineCode))
                        }
                        Divider()
                        Button("分割线  (--- + 回车)") {
                            formattingController.apply(.insertMarkdown(.divider))
                        }
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 10.5, weight: format.headingLevel > 0 ? .bold : .medium))
                            .foregroundColor(format.headingLevel > 0 ? liveNote.colorTag.accentColor : .secondary)
                            .frame(width: btnW + 1, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .fill(format.headingLevel > 0 ? liveNote.colorTag.accentColor.opacity(0.20) : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("快速插入标题、待办勾选、引用与代码块")
                }

                if format.hasAnyStyle || !selectedText.isEmpty {
                    NoteFormatToggleButton(
                        symbol: "eraser",
                        width: btnW,
                        isActive: false,
                        activeFill: Color.primary.opacity(0.10),
                        activeForeground: .primary,
                        helpText: "清除文字样式 (⌘\\)"
                    ) {
                        formattingController.apply(.clearFormatting)
                    }
                }
            }

            Spacer(minLength: 4)

            // Right: Contextual Toast / Selection-to-Board / Subtle Word Count & Save Time
            if let toast = sentToBoardMessage {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(.green)
                    Text(isMiniMode ? "已加入" : toast)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                        .lineLimit(1)

                    Button("查看") {
                        if PinnedPanelController.shared.isCornerMiniMode {
                            PinnedPanelController.shared.switchCornerMiniTab(.board)
                        } else {
                            PinnedRemindersStore.shared.activeTab = .board
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accentColor)
                }
            } else if !selectedText.isEmpty {
                HStack(spacing: 4) {
                    Button {
                        sendTextToBoard(selectedText, splitByLine: false)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 9.5))
                            Text(isMiniMode ? "规划板" : (selectedNonEmptyLineCount > 1 ? "合为1条加入" : "加入规划板"))
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, isMiniMode ? 6.5 : 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.accentColor))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("将选中内容添加为规划板待办任务")

                    if selectedNonEmptyLineCount > 1 {
                        Button {
                            sendTextToBoard(selectedText, splitByLine: true)
                        } label: {
                            Text("拆分(\(selectedNonEmptyLineCount))")
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("按行拆分为 \(selectedNonEmptyLineCount) 条独立任务添加到规划板")
                    }
                }
            } else {
                Text(isMiniMode
                     ? "\(titleText.count + bodyText.count) 字"
                     : "\(titleText.count + bodyText.count) 字 · \(liveNote.relativeTimeText)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isMiniMode ? 9 : 13)
        .padding(.vertical, 5.5)
        .frame(minHeight: 32)
        .background(liveNote.colorTag.accentColor.opacity(0.055))
    }

    private func sendTextToBoard(_ text: String, splitByLine: Bool) {
        guard RemindersService.shared.isAuthorized else {
            showToast("请先授予提醒事项权限")
            return
        }
        guard !PinnedRemindersStore.shared.allCalendarsExcluded else {
            showToast("请先在设置中开启至少一个同步列表")
            return
        }
        let count = PinnedRemindersStore.shared.quickCreateFromSelection(text, splitByLine: splitByLine)
        guard count > 0 else { return }
        showToast(count == 1 ? "已添加到规划板" : "已添加 \(count) 条任务")
    }

    private func showToast(_ message: String) {
        sentToBoardMessage = message
        toastWorkItem?.cancel()
        let work = DispatchWorkItem {
            sentToBoardMessage = nil
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}

private struct NoteFormatToggleButton: View {
    let symbol: String
    var width: CGFloat = 23
    let isActive: Bool
    let activeFill: Color
    let activeForeground: Color
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: isActive ? .bold : .medium))
                .foregroundColor(isActive ? activeForeground : (isHovered ? .primary : .secondary))
                .frame(width: width, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(isActive ? activeFill : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .strokeBorder(isActive ? activeForeground.opacity(0.42) : Color.clear, lineWidth: 0.75)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}

private struct NoteHighlightToggleButton: View {
    let isActive: Bool
    var width: CGFloat = 23
    let action: () -> Void

    @State private var isHovered = false

    private let yellowAccent = Color(red: 0.96, green: 0.76, blue: 0.12)
    private let activeInk = Color(red: 0.48, green: 0.34, blue: 0.0)

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 1.5) {
                Image(systemName: "highlighter")
                    .font(.system(size: 10, weight: .semibold))
                Capsule()
                    .fill(yellowAccent)
                    .frame(width: 11, height: 2.2)
                    .opacity(isActive ? 0.95 : 0.85)
            }
            .foregroundColor(isActive ? activeInk : (isHovered ? .primary : .secondary))
            .frame(width: width + 2, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .fill(
                        isActive
                            ? Color(red: 1.0, green: 0.86, blue: 0.22).opacity(0.78)
                            : (isHovered ? yellowAccent.opacity(0.16) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                    .strokeBorder(isActive ? yellowAccent.opacity(0.75) : Color.clear, lineWidth: 0.75)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("文字标黄高亮 (⇧⌘H)")
    }
}

// MARK: - Top-Right Corner Mini Window Quick Notes View

@MainActor
struct MiniQuickNotesView: View {
    var isActiveTab: Bool = true

    @ObservedObject private var store = QuickNotesStore.shared
    @State private var isShowingList = false
    @State private var searchText = ""

    private var filteredNotes: [QuickNoteItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.sortedNotes }
        return store.sortedNotes.filter { $0.searchableText.lowercased().contains(query) }
    }

    private var activeNote: QuickNoteItem? {
        store.selectedNote
    }

    var body: some View {
        VStack(spacing: 0) {
            if isShowingList || activeNote == nil {
                miniListView
            } else if let note = activeNote {
                NoteEditorPane(
                    note: note,
                    isMiniMode: true,
                    isActiveTab: isActiveTab,
                    onBackToList: {
                        isShowingList = true
                    },
                    onCreateNote: {
                        searchText = ""
                        let created = store.createNote()
                        store.selectedNoteId = created.id
                        isShowingList = false
                    }
                )
                .id(note.id)
            }
        }
        .onAppear {
            if store.selectedNoteId == nil {
                store.selectedNoteId = store.sortedNotes.first?.id
            }
        }
    }

    private var miniListView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)

                    TextField("搜索随笔…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

                Button {
                    searchText = ""
                    let created = store.createNote()
                    store.selectedNoteId = created.id
                    isShowingList = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("新建")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 8.5)
                    .padding(.vertical, 4.5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(NoteColorTag.yellow.accentColor))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().opacity(0.35)

            if filteredNotes.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.system(size: 24))
                        .foregroundColor(NoteColorTag.yellow.accentColor.opacity(0.75))
                    Text(searchText.isEmpty ? "还没有随笔便签" : "没有找到匹配内容")
                        .font(.system(size: 12.5, weight: .medium))
                    if searchText.isEmpty {
                        Button {
                            let created = store.createNote()
                            store.selectedNoteId = created.id
                            isShowingList = false
                        } label: {
                            Text("立即新建便签")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(NoteColorTag.yellow.accentColor))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredNotes) { note in
                            QuickNoteCardRow(note: note, isSelected: false) {
                                store.selectedNoteId = note.id
                                isShowingList = false
                            }
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
