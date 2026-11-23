import SwiftUI
import EventKit

// MARK: - Unified Top-Right Corner Mini Window (规划清单 / 番茄钟 / 剪贴板 / 随笔)

@MainActor
struct CornerMiniWindowView: View {
    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared
    @State private var editingItem: ReminderItem?
    @State private var mountedMiniTabs: Set<BoardTab> = [.board]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                CornerMiniHeaderBar()

                Divider().opacity(0.36)

                ZStack {
                    if mountedMiniTabs.contains(.board) {
                        miniTabLayer(isActive: pinnedStore.activeTab == .board) {
                            MiniTaskChecklistView(onTapEdit: { editingItem = $0 })
                        }
                    }
                    if mountedMiniTabs.contains(.pomodoro) {
                        miniTabLayer(isActive: pinnedStore.activeTab == .pomodoro) {
                            MiniPomodoroCornerContent()
                        }
                    }
                    if mountedMiniTabs.contains(.clipboard) {
                        miniTabLayer(isActive: pinnedStore.activeTab == .clipboard) {
                            ClipboardHistoryView(isMiniMode: true)
                        }
                    }
                    if mountedMiniTabs.contains(.notes) {
                        miniTabLayer(isActive: pinnedStore.activeTab == .notes) {
                            MiniQuickNotesView()
                        }
                    }
                }
                .animation(.timingCurve(0.22, 0.94, 0.30, 1.0, duration: 0.22), value: pinnedStore.activeTab)
                .onAppear {
                    mountedMiniTabs.insert(pinnedStore.activeTab)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        for tab in BoardTab.allCases {
                            mountedMiniTabs.insert(tab)
                        }
                    }
                }
                .onChange(of: pinnedStore.activeTab) { newTab in
                    mountedMiniTabs.insert(newTab)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.rmbColor(.backgroundTheme(isTransparent: userPreferences.isTransparencyEnabled)))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.85)
            )
            .shadow(color: Color.black.opacity(0.20), radius: 13, x: 0, y: 6)
            .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
            .preferredColorScheme(userPreferences.rmbColorScheme.colorScheme)

            if pinnedStore.activeTab != .pomodoro {
                ZStack {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.42))
                        .allowsHitTesting(false)
                    WindowResizeHandle()
                }
                .frame(width: 18, height: 18)
                .padding(3)
                .help("拖拽右下角调整小窗大小")
            }
        }
        .padding(PinnedPanelController.shadowInset)
        .sheet(item: $editingItem) { item in
            ReminderEditView(
                isPresented: Binding(
                    get: { editingItem != nil },
                    set: { if !$0 { editingItem = nil } }
                ),
                reminder: item.reminder,
                reminderHasChildren: item.hasChildren
            )
        }
    }

    @ViewBuilder
    private func miniTabLayer<Content: View>(isActive: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isActive ? 1 : 0)
            .offset(y: isActive ? 0 : 5)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
    }
}

// MARK: - Corner Mini Window Header Bar (4-Tab Switcher + Non-Overlapping Drag Handle)

@MainActor
private struct CornerMiniHeaderBar: View {
    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @Namespace private var miniPillNamespace

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1.5) {
                ForEach(BoardTab.allCases) { tab in
                    CornerMiniTabButton(
                        tab: tab,
                        isSelected: pinnedStore.activeTab == tab,
                        pillNamespace: miniPillNamespace
                    ) {
                        PinnedPanelController.shared.switchCornerMiniTab(tab)
                    }
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.065))
            )
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: pinnedStore.activeTab)

            // Non-overlapping drag handle strictly in the flexible middle gap
            WindowDragHandle()
                .frame(minWidth: 10, maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 2) {
                CornerMiniHeaderIconButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    helpText: "展开完整窗口"
                ) {
                    PinnedPanelController.shared.exitCornerMiniMode(targetTab: pinnedStore.activeTab)
                }

                CornerMiniHeaderIconButton(
                    symbol: "xmark",
                    helpText: "隐藏小窗"
                ) {
                    PinnedRemindersStore.shared.hidePanel()
                }
            }
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(height: 38)
    }
}

@MainActor
private struct CornerMiniTabButton: View {
    let tab: BoardTab
    let isSelected: Bool
    let pillNamespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    private var activeAccent: Color {
        tab == .pomodoro ? PomodoroService.shared.phase.accentColor : tab.accentColor
    }

    var body: some View {
        Button {
            isHovered = false
            action()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: tab.miniSymbol)
                    .font(.system(size: 9.5, weight: .semibold))

                Text(tab.miniTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if tab == .pomodoro {
                    PomodoroRunningMiniDot(isSelected: isSelected)
                }
            }
            .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
            .padding(.horizontal, 6.5)
            .padding(.vertical, 4)
            .background {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(activeAccent)
                            .matchedGeometryEffect(id: "activeMiniTabPill", in: pillNamespace)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tab == .board ? "规划板（任务清单）" : tab.title)
    }
}

@MainActor
private struct PomodoroRunningMiniDot: View {
    let isSelected: Bool
    @ObservedObject private var pomodoro = PomodoroService.shared

    var body: some View {
        if pomodoro.isRunning && !isSelected {
            Circle()
                .fill(pomodoro.phase.accentColor)
                .frame(width: 4.5, height: 4.5)
        }
    }
}

private struct CornerMiniHeaderIconButton: View {
    let symbol: String
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            isHovered = false
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(isHovered ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.09) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Mini Tab 1: Task Checklist Only (小窗规划板任务清单)

@MainActor
private struct MiniTaskChecklistView: View {
    let onTapEdit: (ReminderItem) -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @State private var quickAddText = ""
    @State private var isScheduledExpanded = true
    @State private var isSearchVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact top filter bar + search toggle
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    ForEach(EKReminderPriority.allQuadrants, id: \.rawValue) { quadrant in
                        MiniQuadrantFilterDot(
                            quadrant: quadrant,
                            isSelected: pinnedStore.priorityFilter == quadrant
                        ) {
                            pinnedStore.priorityFilter = (pinnedStore.priorityFilter == quadrant) ? nil : quadrant
                        }
                    }

                    if let active = pinnedStore.priorityFilter {
                        Text(active.shortTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(active.quadrantColor)
                            .lineLimit(1)
                    } else {
                        Text("共 \(pinnedStore.filteredItems.count) 项")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 4)

                    if pinnedStore.priorityFilter != nil {
                        Button("全部") {
                            pinnedStore.priorityFilter = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                    }

                    Button {
                        isSearchVisible.toggle()
                        if !isSearchVisible {
                            pinnedStore.searchText = ""
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(isSearchVisible || !pinnedStore.searchText.isEmpty ? .accentColor : .secondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSearchVisible ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("搜索任务")
                }

                if isSearchVisible {
                    HStack(spacing: 5) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9.5))
                            .foregroundColor(.secondary)
                        TextField("搜索任务…", text: $pinnedStore.searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                        if !pinnedStore.searchText.isEmpty {
                            Button {
                                pinnedStore.searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider().opacity(0.32)

            // Inline quick-add task input
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor.opacity(0.85))

                TextField("添加新任务，回车确认…", text: $quickAddText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .onSubmit {
                        let title = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        pinnedStore.quickCreate(title: title)
                        quickAddText = ""
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.3)

            // Task Checklist ScrollView (+ Floating Undo Toast)
            ZStack(alignment: .bottom) {
                if pinnedStore.filteredItems.isEmpty && pinnedStore.filteredCompletedItems.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 26))
                            .foregroundColor(.secondary.opacity(0.55))
                        Text(pinnedStore.searchText.isEmpty ? "当前没有待办任务" : "没有找到匹配的任务")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.primary)
                        Text(pinnedStore.searchText.isEmpty ? "在上方输入框输入即可快速添加" : "换个关键词或筛选条件试试")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            if !pinnedStore.unscheduledTaskItems.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 4) {
                                        Text("待安排")
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        Text("\(pinnedStore.unscheduledTaskItems.count)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundColor(.secondary.opacity(0.8))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 2)

                                    ForEach(pinnedStore.unscheduledTaskItems) { item in
                                        MiniTaskChecklistRow(
                                            reminderItem: item,
                                            isScheduled: false,
                                            onTapEdit: { onTapEdit(item) }
                                        )
                                    }
                                }
                            }

                            if !pinnedStore.scheduledTaskItems.isEmpty {
                                VStack(alignment: .leading, spacing: 5) {
                                    Button {
                                        isScheduledExpanded.toggle()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: isScheduledExpanded ? "chevron.down" : "chevron.right")
                                                .font(.system(size: 8.5, weight: .semibold))
                                                .foregroundColor(.secondary)
                                            Text("已排期")
                                                .font(.system(size: 10.5, weight: .semibold))
                                                .foregroundColor(.secondary)
                                            Text("\(pinnedStore.scheduledTaskItems.count)")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundColor(.secondary.opacity(0.8))
                                            Spacer()
                                        }
                                        .padding(.horizontal, 2)
                                        .padding(.vertical, 2)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    if isScheduledExpanded {
                                        ForEach(pinnedStore.scheduledTaskItems) { item in
                                            MiniTaskChecklistRow(
                                                reminderItem: item,
                                                isScheduled: true,
                                                onTapEdit: { onTapEdit(item) }
                                            )
                                        }
                                    }
                                }
                            }

                            if !pinnedStore.filteredCompletedItems.isEmpty {
                                CompletedTasksSection(onTapEdit: onTapEdit)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                    }
                }

                if let toast = pinnedStore.lastCompletionToast {
                    CompletionUndoToastBanner(toast: toast)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
}

private struct MiniQuadrantFilterDot: View {
    let quadrant: EKReminderPriority
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            isHovered = false
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(
                        isSelected
                            ? quadrant.quadrantColor.opacity(0.22)
                            : (isHovered ? quadrant.quadrantColor.opacity(0.14) : Color.primary.opacity(0.04))
                    )
                Circle()
                    .strokeBorder(
                        isSelected ? quadrant.quadrantColor : (isHovered ? quadrant.quadrantColor.opacity(0.5) : Color.clear),
                        lineWidth: isSelected ? 1.4 : 1
                    )
                Circle()
                    .fill(quadrant.quadrantColor)
                    .frame(width: isSelected ? 8.5 : 7.5, height: isSelected ? 8.5 : 7.5)
            }
            .frame(width: 20, height: 20)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(quadrant.title)（点击筛选）")
    }
}

@MainActor
private struct MiniTaskChecklistRow: View {
    let reminderItem: ReminderItem
    let isScheduled: Bool
    let onTapEdit: () -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared
    @State private var isHovered = false

    private var isCompleting: Bool {
        pinnedStore.isCompleting(reminderItem.id)
    }

    private var quadrantColor: Color {
        reminderItem.reminder.ekPriority.quadrantColor
    }

    private var notesPreview: String? {
        guard userPreferences.showNotesInReminderItem else { return nil }
        let trimmed = (reminderItem.reminder.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var scheduleBadge: String? {
        guard isScheduled else { return nil }
        let sched = pinnedStore.effectiveSchedule(for: reminderItem)
        guard let start = sched.startDate else { return nil }
        if Calendar.current.isDateInToday(start) {
            return "今天"
        }
        if Calendar.current.isDateInTomorrow(start) {
            return "明天"
        }
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f.string(from: start)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            InstantCompleteCircle(
                color: quadrantColor,
                isCompleted: isCompleting || reminderItem.reminder.isCompleted
            ) {
                pinnedStore.toggleComplete(reminderItem)
            }
            .padding(.top, 1.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(reminderItem.reminder.title ?? "")
                    .font(.system(size: 12, weight: isScheduled ? .regular : .medium))
                    .strikethrough(isCompleting, color: .secondary)
                    .foregroundColor(isCompleting ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let notes = notesPreview {
                    Text(notes)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onTapEdit()
            }

            // Fixed-width trailing slot: opacity-only swap guarantees zero hover jitter!
            ZStack(alignment: .trailing) {
                if isCompleting {
                    Text("已完成")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.green)
                } else {
                    if let badge = scheduleBadge {
                        Text(badge)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(quadrantColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(quadrantColor.opacity(0.13)))
                            .opacity(isHovered ? 0 : 1)
                    }

                    Button {
                        PomodoroService.shared.focusOnTask(
                            id: reminderItem.id,
                            title: reminderItem.reminder.title ?? ""
                        )
                        PinnedPanelController.shared.switchCornerMiniTab(.pomodoro)
                    } label: {
                        Image(systemName: "timer")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(PomodoroService.shared.phase.accentColor)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(PomodoroService.shared.phase.accentColor.opacity(0.12)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .help("切换到番茄钟专注此任务")
                }
            }
            .frame(width: 36, height: 20, alignment: .trailing)
        }
        .padding(.horizontal, 8.5)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isCompleting
                        ? Color.green.opacity(0.14)
                        : quadrantColor.opacity(isHovered ? 0.15 : (isScheduled ? 0.065 : 0.10))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    quadrantColor.opacity(isHovered ? 0.42 : (isScheduled ? 0.15 : 0.22)),
                    lineWidth: 0.75
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .transaction { $0.animation = nil }
        .contextMenu {
            Button("编辑任务…") { onTapEdit() }
            Menu("调整优先级象限") {
                ForEach(EKReminderPriority.allQuadrants, id: \.rawValue) { q in
                    Button {
                        pinnedStore.updatePriority(for: reminderItem.reminder, priority: q)
                    } label: {
                        HStack {
                            Text(q.title)
                            if reminderItem.reminder.ekPriority == q {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Button("番茄钟专注此任务") {
                PomodoroService.shared.focusOnTask(
                    id: reminderItem.id,
                    title: reminderItem.reminder.title ?? ""
                )
                PinnedPanelController.shared.switchCornerMiniTab(.pomodoro)
            }
            if isScheduled {
                Divider()
                Button("移回待安排") {
                    pinnedStore.unscheduleCompletely(for: reminderItem.id)
                }
            }
            Divider()
            Button("删除任务", role: .destructive) {
                pinnedStore.removeItem(reminderItem.reminder)
            }
        }
    }
}

// MARK: - Mini Tab 2: Compact Pomodoro HUD Content

@MainActor
private struct MiniPomodoroCornerContent: View {
    @ObservedObject private var pomodoro = PomodoroService.shared

    private var accent: Color { pomodoro.phase.accentColor }

    private var endTimeLabel: String {
        let finish = Date().addingTimeInterval(TimeInterval(pomodoro.remainingSeconds))
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "预计 \(f.string(from: finish)) 结束"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [accent.opacity(pomodoro.isRunning ? 0.13 : 0.05), Color.clear],
                startPoint: .leading,
                endPoint: .center
            )
            .allowsHitTesting(false)

            HStack(spacing: 12) {
                Button {
                    pomodoro.toggleStartPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(pomodoro.isRunning ? 0.15 : 0.10))

                        Circle()
                            .stroke(Color.primary.opacity(0.09), lineWidth: 3.5)

                        Circle()
                            .trim(from: 0, to: max(0.015, pomodoro.progress))
                            .stroke(accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.25), value: pomodoro.progress)

                        Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(accent)
                            .offset(x: pomodoro.isRunning ? 0 : 1)
                    }
                    .frame(width: 46, height: 46)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(pomodoro.isRunning ? "暂停计时" : "开始计时")

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(pomodoro.formattedTime)
                            .font(.system(size: 27, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)

                        Menu {
                            ForEach(PomodoroPhase.allCases) { phase in
                                Button(phase.title) {
                                    pomodoro.selectPhase(phase)
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(pomodoro.phase.title)
                                    .font(.system(size: 10, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 7.5, weight: .bold))
                            }
                            .foregroundColor(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(accent.opacity(0.14)))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("切换专注或休息阶段")
                    }

                    HStack(spacing: 6) {
                        if let title = pomodoro.linkedTaskTitle, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        } else if !pomodoro.isRunning {
                            Button("-5m") {
                                let cur = pomodoro.phase.defaultDurationMinutes
                                pomodoro.setDurationMinutes(max(1, cur - 5), for: pomodoro.phase)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.065)))

                            Button("+5m") {
                                let cur = pomodoro.phase.defaultDurationMinutes
                                pomodoro.setDurationMinutes(min(180, cur + 5), for: pomodoro.phase)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.065)))
                        } else {
                            Text(endTimeLabel)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer(minLength: 2)

                VStack(spacing: 5) {
                    CornerMiniHeaderIconButton(symbol: "arrow.counterclockwise", helpText: "重置计时") {
                        pomodoro.resetCurrentPhase()
                    }
                    CornerMiniHeaderIconButton(symbol: "forward.end.fill", helpText: "跳至下一阶段") {
                        pomodoro.skipPhase()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.06))
                    Rectangle()
                        .fill(accent)
                        .frame(width: geo.size.width * pomodoro.progress)
                        .animation(.linear(duration: 0.25), value: pomodoro.progress)
                }
            }
            .frame(height: 2.5)
            .allowsHitTesting(false)
        }
    }
}
