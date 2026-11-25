import SwiftUI
import Combine
import EventKit

// MARK: - Preference Keys for Cross-Column Drop Targets

private struct DayViewportFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct DayCanvasFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct TimeViewportFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct TimeCanvasFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Responsive Board Modes

private enum MediumLeftPane: Equatable {
    case calendar
    case tasks
}

private enum CompactBoardColumn: String, CaseIterable, Identifiable {
    case tasks
    case calendar
    case timeline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: return "任务"
        case .calendar: return "日程"
        case .timeline: return "时段"
        }
    }

    var symbol: String {
        switch self {
        case .tasks: return "checklist"
        case .calendar: return "calendar"
        case .timeline: return "clock"
        }
    }
}

// MARK: - Non-Observable Drop Geometry Cache (Prevents Scroll Re-Render Churn)

private final class BoardDropGeometryCache {
    var dayViewportRect: CGRect = .zero
    var dayCanvasRect: CGRect = .zero
    var timeViewportRect: CGRect = .zero
    var timeCanvasRect: CGRect = .zero
    var monthViewportRect: CGRect = .zero
    var monthCellFrames: [String: CGRect] = [:]
}

// MARK: - Main Unified 3-Column Floating Workspace

/// Isolated high-frequency drag pointer state so 60–120Hz cross-column dragging only redraws
/// the tiny floating ghost pill instead of re-evaluating the entire 3-column board & Month calendar.
@MainActor
private final class BoardDragOverlayState: ObservableObject {
    @Published var item: ReminderItem?
    @Published var pointer: CGPoint = .zero
    @Published var badge: String?

    func clear() {
        item = nil
        badge = nil
    }
}

@MainActor
private struct BoardDragGhostOverlay: View {
    @ObservedObject var state: BoardDragOverlayState

    var body: some View {
        if let item = state.item {
            let color = item.reminder.ekPriority.quadrantColor
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(item.reminder.title ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if let badge = state.badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(color))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(color, lineWidth: 1.2)
            )
            .position(x: max(90, state.pointer.x), y: max(24, state.pointer.y))
            .allowsHitTesting(false)
        }
    }
}

@MainActor
struct PinnedPanelView: View {
    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var panelController = PinnedPanelController.shared
    @ObservedObject private var userPreferences = UserPreferences.shared

    @State private var editingItem: ReminderItem?
    @State private var mountedTabs: Set<BoardTab> = [.board]

    // Responsive layout pane state (used when window shrinks to 2-col or 1-col mode)
    @State private var mediumLeftPane: MediumLeftPane = .calendar
    @State private var compactColumn: CompactBoardColumn = .timeline

    // Cross-column drag state (stationary coordinate space: "tripleBoardRoot")
    @StateObject private var dragOverlay = BoardDragOverlayState()
    @State private var dropGeometry = BoardDropGeometryCache()
    @State private var hoveredDropDayIndex: Int?
    @State private var hoveredDropMonthDateKey: String?
    @State private var hoveredDropMinute: Int?

    private let dayRowHeight: CGFloat = 62
    private let hourHeight: CGFloat = 54

    private var effectiveStartHour: Int {
        let earliest = pinnedStore.timeSlotItemsForSelectedDate.map { $0.slot.startMinute / 60 }.min() ?? 7
        return min(7, max(0, earliest))
    }

    private var effectiveEndHour: Int {
        let latest = pinnedStore.timeSlotItemsForSelectedDate.map { ($0.slot.endMinute + 59) / 60 }.max() ?? 23
        return max(23, min(24, latest))
    }

    private var isBoardActive: Bool {
        pinnedStore.activeTab == .board && !panelController.isCornerMiniMode && !pinnedStore.isCollapsed
    }

    private var isNotesActive: Bool {
        pinnedStore.activeTab == .notes && !panelController.isCornerMiniMode && !pinnedStore.isCollapsed
    }

    var body: some View {
        fullWorkspaceView
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
                .preferredColorScheme(userPreferences.rmbColorScheme.colorScheme)
            }
            .onChange(of: pinnedStore.activeTab) { _ in cancelCrossColumnDrag() }
            .onChange(of: pinnedStore.isCollapsed) { _ in cancelCrossColumnDrag() }
            .onChange(of: panelController.isCornerMiniMode) { _ in cancelCrossColumnDrag() }
    }

    private var fullWorkspaceView: some View {
        GeometryReader { rootGeo in
            ZStack(alignment: .bottomTrailing) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        WorkspaceHeaderBar(windowWidth: rootGeo.size.width)

                        if !pinnedStore.isCollapsed {
                            Divider().opacity(0.42)

                            ZStack {
                                if mountedTabs.contains(.board) {
                                    tabLayer(isActive: pinnedStore.activeTab == .board) {
                                        threeColumnBoardView
                                    }
                                }
                                if mountedTabs.contains(.pomodoro) {
                                    tabLayer(isActive: pinnedStore.activeTab == .pomodoro) {
                                        PomodoroView()
                                    }
                                }
                                if mountedTabs.contains(.clipboard) {
                                    tabLayer(isActive: pinnedStore.activeTab == .clipboard) {
                                        ClipboardHistoryView()
                                    }
                                }
                                if mountedTabs.contains(.notes) {
                                    tabLayer(isActive: pinnedStore.activeTab == .notes) {
                                        QuickNotesView(isActiveTab: isNotesActive)
                                    }
                                }
                            }
                            .animation(.timingCurve(0.22, 0.94, 0.30, 1.0, duration: 0.24), value: pinnedStore.activeTab)
                            .onAppear {
                                mountedTabs.insert(pinnedStore.activeTab)
                                // Quietly pre-warm remaining tabs shortly after first paint so even the
                                // very first tab switch has zero view-construction stutter.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                                    for tab in BoardTab.allCases {
                                        mountedTabs.insert(tab)
                                    }
                                }
                            }
                            .onChange(of: pinnedStore.activeTab) { newTab in
                                mountedTabs.insert(newTab)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.rmbColor(.backgroundTheme(isTransparent: userPreferences.isTransparencyEnabled)))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75)
                    )
                    .shadow(color: Color.black.opacity(0.20), radius: 14, x: 0, y: 7)
                    .shadow(color: Color.black.opacity(0.06), radius: 2, x: 0, y: 1)
                    .preferredColorScheme(userPreferences.rmbColorScheme.colorScheme)

                    BoardDragGhostOverlay(state: dragOverlay)

                    if !pinnedStore.isCollapsed,
                       pinnedStore.activeTab == .board,
                       let toast = pinnedStore.lastCompletionToast {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                CompletionUndoToastBanner(toast: toast)
                                Spacer()
                            }
                            .padding(.bottom, 14)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(50)
                    }
                }
                .coordinateSpace(name: "tripleBoardRoot")
                .onPreferenceChange(DayViewportFrameKey.self) { dropGeometry.dayViewportRect = $0 }
                .onPreferenceChange(DayCanvasFrameKey.self) { dropGeometry.dayCanvasRect = $0 }
                .onPreferenceChange(TimeViewportFrameKey.self) { dropGeometry.timeViewportRect = $0 }
                .onPreferenceChange(TimeCanvasFrameKey.self) { dropGeometry.timeCanvasRect = $0 }
                .onPreferenceChange(MonthViewportFrameKey.self) { dropGeometry.monthViewportRect = $0 }
                .onPreferenceChange(MonthCellFramesKey.self) { dropGeometry.monthCellFrames = $0 }

                if !pinnedStore.isCollapsed {
                    ZStack {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.45))
                            .allowsHitTesting(false)
                        WindowResizeHandle()
                    }
                    .frame(width: 20, height: 20)
                    .padding(3)
                    .help("拖拽右下角调整窗口大小")
                }
            }
        }
    }

    @ViewBuilder
    private func tabLayer<Content: View>(isActive: Bool, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isActive ? 1 : 0)
            .scaleEffect(isActive ? 1.0 : 0.985, anchor: .center)
            .offset(y: isActive ? 0 : 6)
            .disabled(!isActive)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
    }

    // MARK: - Responsive Board Layout (Wide 3-Col >= 740 | Medium 2-Col 500..<740 | Compact 1-Col < 500)

    private var threeColumnBoardView: some View {
        GeometryReader { geo in
            let availWidth = geo.size.width

            if availWidth >= 740 {
                // Wide Mode: Full 3-column workspace (Tasks 25% | Calendar 36% | Hourly 39%)
                let totalWidth = max(738, availWidth - 2)
                let leftWidth = max(196, min(285, totalWidth * 0.25))
                let remaining = totalWidth - leftWidth
                let middleWidth = remaining * 0.48
                let rightWidth = remaining - middleWidth

                HStack(spacing: 0) {
                    TaskPoolColumn(
                        onTapEdit: { editingItem = $0 },
                        onDragChanged: { item, loc in updateCrossColumnDrag(item: item, at: loc) },
                        onDragEnded: { item, loc in finishCrossColumnDrag(item: item, at: loc) }
                    )
                    .frame(width: leftWidth)

                    Divider().opacity(0.45)

                    DayDimensionColumn(
                        columnWidth: middleWidth,
                        dayRowHeight: dayRowHeight,
                        hoveredDropDayIndex: hoveredDropDayIndex,
                        hoveredDropMonthDateKey: hoveredDropMonthDateKey,
                        isBoardActive: isBoardActive,
                        onSelectTaskForEdit: { editingItem = $0 }
                    )
                    .frame(width: middleWidth)

                    Divider().opacity(0.45)

                    HourlySlotsColumn(
                        columnWidth: rightWidth,
                        startHour: effectiveStartHour,
                        endHour: effectiveEndHour,
                        hourHeight: hourHeight,
                        hoveredDropMinute: hoveredDropMinute,
                        isBoardActive: isBoardActive,
                        onStartDragDayTask: { item, location in
                            updateCrossColumnDrag(item: item, at: location)
                        },
                        onEndDragDayTask: { item, location in
                            finishCrossColumnDrag(item: item, at: location)
                        },
                        onSelectTaskForEdit: { editingItem = $0 }
                    )
                    .frame(width: rightWidth)
                }
            } else if availWidth >= 500 {
                // Medium Mode: Priority 2-column layout (Always keep Today's Hourly Slots on right;
                // quick-toggle Calendar vs Tasks on left so neither column gets crushed)
                let totalWidth = max(499, availWidth - 1)
                let leftPaneWidth = totalWidth * 0.48
                let rightPaneWidth = totalWidth - leftPaneWidth

                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        mediumLeftPaneSwitcher
                        Divider().opacity(0.35)

                        if mediumLeftPane == .calendar {
                            DayDimensionColumn(
                                columnWidth: leftPaneWidth,
                                dayRowHeight: dayRowHeight,
                                hoveredDropDayIndex: hoveredDropDayIndex,
                                hoveredDropMonthDateKey: hoveredDropMonthDateKey,
                                isBoardActive: isBoardActive,
                                onSelectTaskForEdit: { editingItem = $0 }
                            )
                        } else {
                            TaskPoolColumn(
                                onTapEdit: { editingItem = $0 },
                                onDragChanged: { item, loc in updateCrossColumnDrag(item: item, at: loc) },
                                onDragEnded: { item, loc in finishCrossColumnDrag(item: item, at: loc) }
                            )
                        }
                    }
                    .frame(width: leftPaneWidth)

                    Divider().opacity(0.45)

                    HourlySlotsColumn(
                        columnWidth: rightPaneWidth,
                        startHour: effectiveStartHour,
                        endHour: effectiveEndHour,
                        hourHeight: hourHeight,
                        hoveredDropMinute: hoveredDropMinute,
                        isBoardActive: isBoardActive,
                        onStartDragDayTask: { item, location in
                            updateCrossColumnDrag(item: item, at: location)
                        },
                        onEndDragDayTask: { item, location in
                            finishCrossColumnDrag(item: item, at: location)
                        },
                        onSelectTaskForEdit: { editingItem = $0 }
                    )
                    .frame(width: rightPaneWidth)
                }
            } else {
                // Compact Mode (< 500pt): Focused single-column switcher so even a small widget stays 100% crisp
                VStack(spacing: 0) {
                    compactColumnSwitcher
                    Divider().opacity(0.35)

                    switch compactColumn {
                    case .tasks:
                        TaskPoolColumn(
                            onTapEdit: { editingItem = $0 },
                            onDragChanged: { item, loc in updateCrossColumnDrag(item: item, at: loc) },
                            onDragEnded: { item, loc in finishCrossColumnDrag(item: item, at: loc) }
                        )
                    case .calendar:
                        DayDimensionColumn(
                            columnWidth: availWidth,
                            dayRowHeight: dayRowHeight,
                            hoveredDropDayIndex: hoveredDropDayIndex,
                            hoveredDropMonthDateKey: hoveredDropMonthDateKey,
                            isBoardActive: isBoardActive,
                            onSelectTaskForEdit: { editingItem = $0 }
                        )
                    case .timeline:
                        HourlySlotsColumn(
                            columnWidth: availWidth,
                            startHour: effectiveStartHour,
                            endHour: effectiveEndHour,
                            hourHeight: hourHeight,
                            hoveredDropMinute: hoveredDropMinute,
                            isBoardActive: isBoardActive,
                            onStartDragDayTask: { item, location in
                                updateCrossColumnDrag(item: item, at: location)
                            },
                            onEndDragDayTask: { item, location in
                                finishCrossColumnDrag(item: item, at: location)
                            },
                            onSelectTaskForEdit: { editingItem = $0 }
                        )
                    }
                }
            }
        }
    }

    private var mediumLeftPaneSwitcher: some View {
        HStack(spacing: 4) {
            mediumPaneButton(title: "日程视图", symbol: "calendar", isSelected: mediumLeftPane == .calendar) {
                withAnimation(.easeInOut(duration: 0.14)) {
                    mediumLeftPane = .calendar
                }
            }
            mediumPaneButton(
                title: "任务 (\(pinnedStore.filteredItems.count))",
                symbol: "checklist",
                isSelected: mediumLeftPane == .tasks
            ) {
                withAnimation(.easeInOut(duration: 0.14)) {
                    mediumLeftPane = .tasks
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.025))
    }

    private func mediumPaneButton(title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundColor(isSelected ? .accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.13) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var compactColumnSwitcher: some View {
        HStack(spacing: 3) {
            ForEach(CompactBoardColumn.allCases) { col in
                let isSelected = compactColumn == col
                let label = col == .tasks ? "\(col.title) \(pinnedStore.filteredItems.count)" : col.title
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        compactColumn = col
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: col.symbol)
                            .font(.system(size: 10, weight: .semibold))
                        Text(label)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundColor(isSelected ? .white : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Cross-Column Drag Calculation

    private func cancelCrossColumnDrag() {
        dragOverlay.clear()
        if hoveredDropMonthDateKey != nil { hoveredDropMonthDateKey = nil }
        if hoveredDropDayIndex != nil { hoveredDropDayIndex = nil }
        if hoveredDropMinute != nil { hoveredDropMinute = nil }
    }

    private func updateCrossColumnDrag(item: ReminderItem, at point: CGPoint) {
        dragOverlay.item = item
        dragOverlay.pointer = point

        let inMonthViewport = dropGeometry.monthViewportRect == .zero
            || dropGeometry.monthViewportRect.contains(point)

        let nextMonthKey: String?
        let nextDayIdx: Int?
        let nextMinute: Int?

        if pinnedStore.calendarScale == .month,
           inMonthViewport,
           let matchedKey = dropGeometry.monthCellFrames.first(where: { $0.value.contains(point) })?.key {
            nextMonthKey = matchedKey
            nextDayIdx = nil
            nextMinute = nil
        } else if pinnedStore.calendarScale == .week && dropGeometry.dayViewportRect.contains(point) {
            nextMonthKey = nil
            nextMinute = nil
            let localY = point.y - dropGeometry.dayCanvasRect.minY - 6
            let idx = Int(floor(localY / dayRowHeight))
            nextDayIdx = (0..<7).contains(idx) ? idx : nil
        } else if dropGeometry.timeViewportRect.contains(point) {
            nextMonthKey = nil
            nextDayIdx = nil
            let sHour = effectiveStartHour
            let eHour = effectiveEndHour
            let localY = point.y - dropGeometry.timeCanvasRect.minY - 8
            let rawMin = Double(sHour * 60) + (Double(localY) / Double(hourHeight)) * 60.0
            let snapped = DayTimeSlot.snap(Int(rawMin))
            nextMinute = max(sHour * 60, min(eHour * 60 - 15, snapped))
        } else {
            nextMonthKey = nil
            nextDayIdx = nil
            nextMinute = nil
        }

        if hoveredDropMonthDateKey != nextMonthKey { hoveredDropMonthDateKey = nextMonthKey }
        if hoveredDropDayIndex != nextDayIdx { hoveredDropDayIndex = nextDayIdx }
        if hoveredDropMinute != nextMinute { hoveredDropMinute = nextMinute }

        let nextBadge: String? = {
            if let monthKey = nextMonthKey,
               let date = PinnedTaskSchedule.date(fromKey: monthKey) {
                return RmbFormatters.monthDay.string(from: date)
            }
            if let idx = nextDayIdx, pinnedStore.visibleDays.indices.contains(idx) {
                return RmbFormatters.monthDay.string(from: pinnedStore.visibleDays[idx])
            }
            if let min = nextMinute {
                return DayTimeSlot.formatMinute(min)
            }
            return nil
        }()
        if dragOverlay.badge != nextBadge {
            dragOverlay.badge = nextBadge
        }
    }

    private func finishCrossColumnDrag(item: ReminderItem, at point: CGPoint) {
        updateCrossColumnDrag(item: item, at: point)
        let preservedSpan = max(1, pinnedStore.effectiveSchedule(for: item).spanDays)

        if let monthKey = hoveredDropMonthDateKey,
           let targetDay = PinnedTaskSchedule.date(fromKey: monthKey) {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                pinnedStore.setDaySpan(for: item.id, startDate: targetDay, spanDays: preservedSpan)
                pinnedStore.selectDate(targetDay)
            }
        } else if let dayIdx = hoveredDropDayIndex, pinnedStore.visibleDays.indices.contains(dayIdx) {
            let targetDay = pinnedStore.visibleDays[dayIdx]
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                pinnedStore.setDaySpan(for: item.id, startDate: targetDay, spanDays: preservedSpan)
                pinnedStore.selectDate(targetDay)
            }
        } else if let minute = hoveredDropMinute {
            let duration = max(15, min(60, effectiveEndHour * 60 - minute))
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                pinnedStore.setTimeSlot(
                    for: item.id,
                    on: pinnedStore.selectedDate,
                    startMinute: minute,
                    durationMinutes: duration
                )
            }
        }

        cancelCrossColumnDrag()
    }
}

// MARK: - Column 1 (Left 26%): Task Pool (待安排 + 已排期 + Reliable 4-Quadrant Filter)

@MainActor
private struct TaskPoolColumn: View {
    let onTapEdit: (ReminderItem) -> Void
    let onDragChanged: (ReminderItem, CGPoint) -> Void
    let onDragEnded: (ReminderItem, CGPoint) -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared
    @State private var quickAddText = ""
    @State private var isScheduledExpanded = true
    @State private var authRefreshTick = 0

    private var isAuthorized: Bool {
        _ = authRefreshTick
        return RemindersService.shared.isAuthorized
    }

    private var isQuickAddDisabled: Bool {
        !isAuthorized || pinnedStore.allCalendarsExcluded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header + 4-quadrant large-hit-area filter buttons
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(.accentColor)

                    Text("任务")
                        .font(.system(size: 11.5, weight: .semibold))

                    Text("\(pinnedStore.filteredItems.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))

                    Spacer()

                    if pinnedStore.hasExcludedCalendars {
                        Button {
                            NSApp.openAppSettings(tab: .maintenance)
                        } label: {
                            HStack(spacing: 2.5) {
                                Image(systemName: "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 9.5, weight: .medium))
                                Text("\(pinnedStore.syncedCalendars.count)/\(pinnedStore.availableCalendars.count)")
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.accentColor.opacity(0.11)))
                        }
                        .buttonStyle(.plain)
                        .help("仅同步部分提醒事项列表（点击管理同步列表）")
                    }

                    if pinnedStore.priorityFilter != nil {
                        Button("全部") {
                            pinnedStore.priorityFilter = nil
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.accentColor)
                    }
                }

                // 4 reliable, generous hit-target quadrant filter pills
                HStack(spacing: 4) {
                    ForEach(EKReminderPriority.allQuadrants, id: \.rawValue) { quadrant in
                        QuadrantFilterDotButton(
                            quadrant: quadrant,
                            isSelected: pinnedStore.priorityFilter == quadrant
                        ) {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                pinnedStore.priorityFilter = (pinnedStore.priorityFilter == quadrant) ? nil : quadrant
                            }
                        }
                    }

                    Spacer(minLength: 2)

                    if let active = pinnedStore.priorityFilter {
                        Text(active.shortTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(active.quadrantColor)
                            .lineLimit(1)
                    }
                }

                // Search bar
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary.opacity(0.8))

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
                        .fill(Color.primary.opacity(0.055))
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider().opacity(0.35)

            // Always-handy inline quick-add input
            HStack(spacing: 5) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(isQuickAddDisabled ? .secondary.opacity(0.45) : .accentColor.opacity(0.85))

                TextField(
                    !isAuthorized
                        ? "请先授予提醒事项权限…"
                        : (pinnedStore.allCalendarsExcluded ? "已暂停同步，请先开启列表…" : "添加新任务，回车确认…"),
                    text: $quickAddText
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .disabled(isQuickAddDisabled)
                    .onSubmit {
                        let title = quickAddText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !title.isEmpty else { return }
                        if pinnedStore.quickCreate(title: title) {
                            quickAddText = ""
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.02))

            Divider().opacity(0.3)

            // Vertical Task List: 待安排 + 已排期
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if !isAuthorized {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("未授予 Apple 提醒事项权限")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.primary)
                            Text("授权后即可在规划板中查看、排期并同步你的全部待办任务。")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                            Button("前往授权") {
                                AppDelegate.shared?.openRemindersPermissionFlow()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor))
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                    } else if pinnedStore.allCalendarsExcluded {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("已暂停全部提醒事项列表同步")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.primary)
                            Text("你可以在设置中选择要同步的列表，或一键恢复全部同步。")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary)
                            HStack(spacing: 6) {
                                Button("恢复全部同步") {
                                    userPreferences.enableAllCalendars()
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor))

                                Button("同步设置") {
                                    NSApp.openAppSettings(tab: .maintenance)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.07)))
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                    } else {
                        // Section 1: 待安排
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

                            if pinnedStore.unscheduledTaskItems.isEmpty {
                                Text(pinnedStore.scheduledTaskItems.isEmpty ? "暂无待办任务，上方回车快速添加" : "全部任务已排期")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary.opacity(0.65))
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 4)
                            } else {
                                ForEach(pinnedStore.unscheduledTaskItems) { item in
                                    TaskPoolRow(
                                        reminderItem: item,
                                        isScheduled: false,
                                        onTap: { onTapEdit(item) },
                                        onDragChanged: { onDragChanged(item, $0) },
                                        onDragEnded: { onDragEnded(item, $0) }
                                    )
                                }
                            }
                        }

                        // Section 2: 已排期 (so tasks never "disappear" and stay always accessible!)
                        if !pinnedStore.scheduledTaskItems.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.14)) {
                                        isScheduledExpanded.toggle()
                                    }
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
                                        TaskPoolRow(
                                            reminderItem: item,
                                            isScheduled: true,
                                            onTap: { onTapEdit(item) },
                                            onDragChanged: { onDragChanged(item, $0) },
                                            onDragEnded: { onDragEnded(item, $0) }
                                        )
                                    }
                                }
                            }
                        }

                        // Section 3: 已完成 (Keep header accessible when range != .all so user can switch to 全部)
                        if !pinnedStore.filteredCompletedItems.isEmpty || pinnedStore.completedTimeRange != .all {
                            CompletedTasksSection(onTapEdit: onTapEdit)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
        }
        .background(Color.primary.opacity(0.018))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            authRefreshTick += 1
            if RemindersService.shared.isAuthorized && pinnedStore.availableCalendars.isEmpty {
                pinnedStore.requestRefresh()
            }
        }
    }
}

/// Large 22×22 reliable hit-target quadrant filter button (fixes unreliable 7×7 dot clicking!)
private struct QuadrantFilterDotButton: View {
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
                        lineWidth: isSelected ? 1.5 : 1
                    )

                Circle()
                    .fill(quadrant.quadrantColor)
                    .frame(width: isSelected ? 9 : 8, height: isSelected ? 9 : 8)
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(quadrant.title)（点击筛选）")
    }
}

@MainActor
private struct TaskPoolRow: View {
    let reminderItem: ReminderItem
    let isScheduled: Bool
    let onTap: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared
    @State private var isHovered = false
    @State private var isDragging = false

    private var isCompleting: Bool {
        pinnedStore.isCompleting(reminderItem.id)
    }

    private var quadrantColor: Color {
        reminderItem.reminder.ekPriority.quadrantColor
    }

    private var hasNotes: Bool {
        guard userPreferences.showNotesInReminderItem else { return false }
        return !(reminderItem.reminder.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            // Isolated outside drag/tap container so completion click is 100% reliable!
            InstantCompleteCircle(
                color: quadrantColor,
                isCompleted: isCompleting || reminderItem.reminder.isCompleted
            ) {
                pinnedStore.toggleComplete(reminderItem)
            }
            .padding(.top, 1)

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminderItem.reminder.title ?? "")
                        .font(.system(size: 12, weight: isScheduled ? .regular : .medium))
                        .strikethrough(isCompleting, color: .secondary)
                        .foregroundColor(isCompleting ? .secondary : (isScheduled ? .primary.opacity(0.75) : .primary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if hasNotes {
                        Text((reminderItem.reminder.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCompleting {
                    Text("已完成")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.green)
                } else if isScheduled {
                    Image(systemName: "calendar.badge.checkmark")
                        .font(.system(size: 10))
                        .foregroundColor(quadrantColor.opacity(0.8))
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isDragging {
                    onTap()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named("tripleBoardRoot"))
                    .onChanged { value in
                        isDragging = true
                        onDragChanged(value.location)
                    }
                    .onEnded { value in
                        isDragging = false
                        onDragEnded(value.location)
                    }
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isCompleting
                        ? Color.green.opacity(0.14)
                        : quadrantColor.opacity(isHovered ? 0.16 : (isScheduled ? 0.06 : 0.11))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    quadrantColor.opacity(isHovered ? 0.45 : (isScheduled ? 0.14 : 0.24)),
                    lineWidth: 0.75
                )
        )
        .opacity(isDragging ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDisappear { isDragging = false }
        .contextMenu {
            Button("编辑任务…") { onTap() }
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
                PomodoroService.shared.focusOnTask(id: reminderItem.id, title: reminderItem.reminder.title ?? "")
                PinnedPanelController.shared.snapPomodoroToTopRightCorner()
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

// MARK: - Isolated Workspace Header Bar (Zero Scroll / Hover Animation Leakage)

@MainActor
private struct WorkspaceHeaderBar: View {
    let windowWidth: CGFloat

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared
    @ObservedObject private var updateService = AppUpdateService.shared
    @Namespace private var tabPillNamespace

    var body: some View {
        let isCompactHeader = windowWidth < 520

        HStack(spacing: isCompactHeader ? 4 : 8) {
            HStack(spacing: 2) {
                ForEach(BoardTab.allCases) { tab in
                    WorkspaceTabButton(
                        tab: tab,
                        isSelected: pinnedStore.activeTab == tab,
                        compactIconOnly: isCompactHeader && pinnedStore.activeTab != tab,
                        pillNamespace: tabPillNamespace
                    ) {
                        selectTab(tab)
                    }
                }
            }
            .padding(2.5)
            .background(
                RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                    .fill(Color.primary.opacity(0.065))
            )
            .animation(.spring(response: 0.30, dampingFraction: 0.84), value: pinnedStore.activeTab)

            // Non-overlapping drag region strictly in the empty flexible spacer
            WindowDragHandle()
                .frame(minWidth: 12, maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: isCompactHeader ? 1.5 : 3) {
                PinnedHeaderIconButton(
                    symbol: .pipEnter,
                    isHighlighted: false,
                    helpText: pinnedStore.activeTab == .board
                        ? "切换为右上角任务清单小窗"
                        : "切换为右上角迷你小窗"
                ) {
                    PinnedPanelController.shared.enterCornerMiniMode(tab: pinnedStore.activeTab)
                }

                PinnedHeaderIconButton(
                    symbol: userPreferences.isBoardAlwaysOnTop ? .pinFill : .pin,
                    isHighlighted: userPreferences.isBoardAlwaysOnTop,
                    helpText: userPreferences.isBoardAlwaysOnTop
                        ? "已置顶悬浮（点击取消置顶）"
                        : "普通窗口（点击置顶悬浮）"
                ) {
                    PinnedPanelController.shared.toggleAlwaysOnTop()
                }

                ZStack(alignment: .topTrailing) {
                    PinnedHeaderIconButton(
                        symbol: .gearshape,
                        isHighlighted: updateService.hasAvailableUpdate,
                        helpText: updateService.availableRelease.map { "发现新版本 \($0.displayVersion)（点击前往更新）" } ?? "偏好设置"
                    ) {
                        NSApp.openAppSettings(tab: updateService.hasAvailableUpdate ? .maintenance : .general)
                    }

                    if updateService.hasAvailableUpdate {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .offset(x: -2, y: 2)
                            .allowsHitTesting(false)
                    }
                }

                PinnedHeaderIconButton(
                    symbol: pinnedStore.isCollapsed ? .chevronDown : .chevronUp,
                    isHighlighted: false,
                    helpText: pinnedStore.isCollapsed ? "展开窗口" : "收起窗口"
                ) {
                    pinnedStore.toggleCollapsed()
                }

                PinnedHeaderIconButton(
                    symbol: .xmark,
                    isHighlighted: false,
                    helpText: "隐藏窗口"
                ) {
                    pinnedStore.hidePanel()
                }
            }
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, isCompactHeader ? 8 : 12)
        .padding(.vertical, 7)
        .frame(height: PinnedPanelController.collapsedHeight)
    }

    private func selectTab(_ tab: BoardTab) {
        if pinnedStore.activeTab == .notes && tab != .notes {
            // Release NSTextView focus when leaving Notes so hidden text editor doesn't capture shortcuts
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        pinnedStore.activeTab = tab
        if pinnedStore.isCollapsed {
            pinnedStore.isCollapsed = false
        }
    }
}

@MainActor
private struct WorkspacePomodoroDot: View {
    let isSelected: Bool
    @ObservedObject private var pomodoro = PomodoroService.shared

    var body: some View {
        if pomodoro.isRunning && !isSelected {
            Circle()
                .fill(pomodoro.phase.accentColor)
                .frame(width: 5, height: 5)
        }
    }
}

// MARK: - Workspace Tab Button

@MainActor
private struct WorkspaceTabButton: View {
    let tab: BoardTab
    let isSelected: Bool
    var compactIconOnly: Bool = false
    let pillNamespace: Namespace.ID
    let action: () -> Void

    @ObservedObject private var pomodoro = PomodoroService.shared
    @State private var isHovered = false

    private var activeColor: Color {
        tab == .pomodoro ? pomodoro.phase.accentColor : tab.accentColor
    }

    var body: some View {
        Button {
            isHovered = false
            action()
        } label: {
            HStack(spacing: compactIconOnly ? 0 : 4.5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                if !compactIconOnly {
                    Text(tab.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if tab == .pomodoro {
                    WorkspacePomodoroDot(isSelected: isSelected)
                }
            }
            .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
            .padding(.horizontal, compactIconOnly ? 7.5 : 9)
            .padding(.vertical, 4.5)
            .background {
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(activeColor)
                            .matchedGeometryEffect(id: "activeWorkspaceTabPill", in: pillNamespace)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tab.title)
    }
}

// MARK: - Column 2 (Middle 36%): Multi-Scale Calendar (Week / Month / Year)

@MainActor
private struct DayDimensionColumn: View {
    let columnWidth: CGFloat
    let dayRowHeight: CGFloat
    let hoveredDropDayIndex: Int?
    let hoveredDropMonthDateKey: String?
    let isBoardActive: Bool
    let onSelectTaskForEdit: (ReminderItem) -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared

    private var dayGutterWidth: CGFloat {
        columnWidth < 250 ? 48 : 56
    }
    private var canvasHeight: CGFloat { CGFloat(7) * dayRowHeight }

    private var todayButtonLabel: String {
        switch pinnedStore.calendarScale {
        case .week: return "今天"
        case .month: return "本月"
        case .year: return "今年"
        }
    }

    var body: some View {
        let tightHeader = columnWidth < 255

        VStack(alignment: .leading, spacing: 0) {
            // Header with Week / Month / Year segmented switch + navigation (never wraps)
            HStack(spacing: tightHeader ? 4 : 6) {
                HStack(spacing: 1.5) {
                    ForEach(CalendarScaleMode.allCases) { scale in
                        let isSelected = pinnedStore.calendarScale == scale
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                pinnedStore.calendarScale = scale
                            }
                        } label: {
                            Text(scale.title)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundColor(isSelected ? .white : .secondary)
                                .padding(.horizontal, tightHeader ? 6 : 8)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                        .fill(isSelected ? Color.accentColor : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

                Spacer(minLength: 4)

                HStack(spacing: 1.5) {
                    Button {
                        stepCalendar(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: tightHeader ? 18 : 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Button {
                        pinnedStore.goToToday()
                    } label: {
                        Text(todayButtonLabel)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, tightHeader ? 5 : 6)
                            .padding(.vertical, 2.5)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.11)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        stepCalendar(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: tightHeader ? 18 : 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, tightHeader ? 7 : 10)
            .padding(.vertical, 6.5)

            Divider().opacity(0.35)

            switch pinnedStore.calendarScale {
            case .week:
                weekTimelineContent
            case .month:
                MonthCalendarScaleView(
                    hoveredDropDateKey: hoveredDropMonthDateKey,
                    onSelectTaskForEdit: onSelectTaskForEdit
                )
            case .year:
                YearHeatmapScaleView(onSelectTaskForEdit: onSelectTaskForEdit)
            }
        }
    }

    private func stepCalendar(by direction: Int) {
        switch pinnedStore.calendarScale {
        case .week:
            pinnedStore.shiftWeek(byDays: direction * 7)
        case .month:
            pinnedStore.shiftDisplayedMonth(byMonths: direction)
        case .year:
            pinnedStore.shiftDisplayedYear(byYears: direction)
        }
    }

    private var weekTimelineContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(Array(pinnedStore.visibleDays.enumerated()), id: \.offset) { idx, day in
                            dayRowBackground(day: day, index: idx)
                        }
                    }

                    if let dropIdx = hoveredDropDayIndex {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.4, dash: [5, 3]))
                            )
                            .frame(height: dayRowHeight - 6)
                            .padding(.leading, dayGutterWidth + 6)
                            .padding(.trailing, 8)
                            .offset(y: CGFloat(dropIdx) * dayRowHeight + 3)
                            .allowsHitTesting(false)
                    }

                    GeometryReader { geo in
                        let trackLeft = dayGutterWidth + 6
                        let trackWidth = max(100, geo.size.width - trackLeft - 8)
                        let laidOut = layoutDaySpans()

                        ForEach(laidOut, id: \.item.id) { placed in
                            let colW = max(24, (trackWidth - CGFloat(placed.totalColumns - 1) * 5) / CGFloat(placed.totalColumns))
                            let colX = trackLeft + CGFloat(placed.columnIndex) * (colW + 5)

                            DaySpanBlockView(
                                reminderItem: placed.item,
                                schedule: placed.schedule,
                                visibleStartOffset: placed.clampedStartIndex,
                                visibleSpan: placed.clampedSpan,
                                dayRowHeight: dayRowHeight,
                                blockWidth: colW,
                                blockX: colX,
                                isBoardActive: isBoardActive,
                                onTapEdit: { onSelectTaskForEdit(placed.item) }
                            )
                        }
                    }
                }
                .coordinateSpace(name: "dayCanvas")
                .padding(.top, 6)
                .padding(.bottom, 10)
                .frame(height: canvasHeight + 16, alignment: .top)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: DayCanvasFrameKey.self, value: proxy.frame(in: .named("tripleBoardRoot")))
                    }
                )
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: DayViewportFrameKey.self, value: proxy.frame(in: .named("tripleBoardRoot")))
                }
            )
    }

    private func dayRowBackground(day: Date, index: Int) -> some View {
        let cal = Calendar.current
        let isSelected = cal.isDate(day, inSameDayAs: pinnedStore.selectedDate)
        let isToday = cal.isDateInToday(day)

        return HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 2.5)
                .padding(.vertical, 8)
                .padding(.leading, 3)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 3) {
                    if isToday {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 4.5, height: 4.5)
                    }
                    Text(isToday ? "今天" : RmbFormatters.weekdayShortZH.string(from: day))
                        .font(.system(size: 10.5, weight: isToday || isSelected ? .semibold : .medium))
                        .foregroundColor(isToday ? .red : (isSelected ? .accentColor : .primary))
                }

                Text(RmbFormatters.monthDay.string(from: day))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(isSelected ? .accentColor.opacity(0.9) : .secondary)
            }
            .frame(width: dayGutterWidth - 11, alignment: .trailing)
            .padding(.trailing, 6)

            Rectangle()
                .fill(Color.clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: dayRowHeight)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.07)
                : (index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.015))
        )
        .overlay(
            VStack {
                Divider().opacity(0.28)
                Spacer()
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            pinnedStore.selectDate(day)
        }
    }

    private struct PlacedDaySpan {
        let item: ReminderItem
        let schedule: PinnedTaskSchedule
        let clampedStartIndex: Int
        let clampedSpan: Int
        let columnIndex: Int
        let totalColumns: Int
    }

    private func layoutDaySpans() -> [PlacedDaySpan] {
        let weekStart = pinnedStore.weekStartDate
        var visibleEntries: [(item: ReminderItem, schedule: PinnedTaskSchedule, startIdx: Int, endIdx: Int)] = []

        for entry in pinnedStore.dayVisibleItems {
            guard let start = entry.schedule.startDate else { continue }
            let rawStart = PinnedTaskSchedule.dayDifference(from: weekStart, to: start)
            let rawEnd = rawStart + entry.schedule.spanDays - 1
            guard rawEnd >= 0 && rawStart < 7 else { continue }
            visibleEntries.append((entry.item, entry.schedule, max(0, rawStart), min(6, rawEnd)))
        }

        visibleEntries.sort { lhs, rhs in
            if lhs.startIdx != rhs.startIdx { return lhs.startIdx < rhs.startIdx }
            if lhs.endIdx != rhs.endIdx { return lhs.endIdx > rhs.endIdx }
            return lhs.item.id < rhs.item.id
        }

        // Partition into connected overlap clusters so every block in a cluster shares the exact same column width.
        var clusters: [[(item: ReminderItem, schedule: PinnedTaskSchedule, startIdx: Int, endIdx: Int)]] = []
        var clusterMaxEnd = Int.min
        for entry in visibleEntries {
            if clusters.isEmpty || entry.startIdx > clusterMaxEnd {
                clusters.append([entry])
                clusterMaxEnd = entry.endIdx
            } else {
                clusters[clusters.count - 1].append(entry)
                clusterMaxEnd = max(clusterMaxEnd, entry.endIdx)
            }
        }

        var result: [PlacedDaySpan] = []
        for cluster in clusters {
            var colEnds: [Int] = []
            var assigned: [(item: ReminderItem, schedule: PinnedTaskSchedule, startIdx: Int, endIdx: Int, col: Int)] = []
            for e in cluster {
                var placedCol: Int?
                for idx in colEnds.indices where colEnds[idx] < e.startIdx {
                    placedCol = idx
                    colEnds[idx] = e.endIdx
                    break
                }
                if let c = placedCol {
                    assigned.append((e.item, e.schedule, e.startIdx, e.endIdx, c))
                } else {
                    colEnds.append(e.endIdx)
                    assigned.append((e.item, e.schedule, e.startIdx, e.endIdx, colEnds.count - 1))
                }
            }
            let totalCols = max(1, colEnds.count)
            for cur in assigned {
                result.append(
                    PlacedDaySpan(
                        item: cur.item,
                        schedule: cur.schedule,
                        clampedStartIndex: cur.startIdx,
                        clampedSpan: max(1, cur.endIdx - cur.startIdx + 1),
                        columnIndex: cur.col,
                        totalColumns: totalCols
                    )
                )
            }
        }
        return result
    }
}

// MARK: - Middle Column Block

@MainActor
private struct DaySpanBlockView: View {
    let reminderItem: ReminderItem
    let schedule: PinnedTaskSchedule
    let visibleStartOffset: Int
    let visibleSpan: Int
    let dayRowHeight: CGFloat
    let blockWidth: CGFloat
    let blockX: CGFloat
    let isBoardActive: Bool
    let onTapEdit: () -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared

    @State private var moveDeltaY: CGFloat = 0
    @State private var topResizeDeltaY: CGFloat = 0
    @State private var bottomResizeDeltaY: CGFloat = 0
    @State private var isMoving = false
    @State private var isResizingTop = false
    @State private var isResizingBottom = false
    @State private var isHovered = false

    private var isDone: Bool {
        reminderItem.reminder.isCompleted
    }

    private var isCompleting: Bool {
        pinnedStore.isCompleting(reminderItem.id)
    }

    private var isVisuallyDone: Bool {
        isDone || isCompleting
    }

    private var quadrantColor: Color {
        reminderItem.reminder.ekPriority.quadrantColor
    }

    private var notesPreview: String? {
        guard userPreferences.showNotesInReminderItem else { return nil }
        let trimmed = (reminderItem.reminder.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var moveDayDelta: Int {
        let raw = Int((moveDeltaY / dayRowHeight).rounded())
        return max(-visibleStartOffset, min(7 - visibleSpan - visibleStartOffset, raw))
    }

    private var topDayDelta: Int {
        let raw = Int((topResizeDeltaY / dayRowHeight).rounded())
        return max(-visibleStartOffset, min(min(schedule.spanDays, visibleSpan) - 1, raw))
    }

    private var bottomDayDelta: Int {
        let raw = Int((bottomResizeDeltaY / dayRowHeight).rounded())
        let minDelta = max(1 - schedule.spanDays, 1 - visibleSpan)
        let maxDelta = max(0, 7 - visibleStartOffset - visibleSpan)
        return max(minDelta, min(maxDelta, raw))
    }

    private var baseTopY: CGFloat {
        CGFloat(visibleStartOffset) * dayRowHeight + 3
    }

    private var baseHeight: CGFloat {
        max(36, CGFloat(visibleSpan) * dayRowHeight - 6)
    }

    private var liveTopY: CGFloat {
        let maxTop = CGFloat(7 - visibleSpan) * dayRowHeight + 3
        if isMoving {
            return (baseTopY + moveDeltaY).constrainedTo(min: 3, max: max(3, maxTop))
        } else if isResizingTop {
            let maxTopResize = max(3, baseTopY + baseHeight - (dayRowHeight - 6))
            return (baseTopY + topResizeDeltaY).constrainedTo(min: 3, max: maxTopResize)
        }
        return baseTopY
    }

    private var liveHeight: CGFloat {
        if isResizingBottom {
            let maxH = max(dayRowHeight - 6, CGFloat(7 - visibleStartOffset) * dayRowHeight - 6)
            return (baseHeight + bottomResizeDeltaY).constrainedTo(min: dayRowHeight - 6, max: maxH)
        } else if isResizingTop {
            let bottomEdge = baseTopY + baseHeight
            return max(dayRowHeight - 6, bottomEdge - liveTopY)
        }
        return baseHeight
    }

    private var snappedGuideTopY: CGFloat {
        let row: Int
        if isMoving {
            row = max(0, min(7 - visibleSpan, visibleStartOffset + moveDayDelta))
        } else if isResizingTop {
            row = max(0, min(visibleStartOffset + visibleSpan - 1, visibleStartOffset + topDayDelta))
        } else {
            row = visibleStartOffset
        }
        return CGFloat(row) * dayRowHeight + 3
    }

    private var snappedGuideHeight: CGFloat {
        let span: Int
        if isResizingBottom {
            span = max(1, min(7 - visibleStartOffset, visibleSpan + bottomDayDelta))
        } else if isResizingTop {
            span = max(1, visibleSpan - topDayDelta)
        } else {
            span = visibleSpan
        }
        return max(36, CGFloat(span) * dayRowHeight - 6)
    }

    private var liveDragLabel: String {
        guard let baseStart = schedule.startDate else { return "" }
        let cal = Calendar.current
        let start: Date
        let span: Int
        if isMoving {
            start = cal.date(byAdding: .day, value: moveDayDelta, to: baseStart) ?? baseStart
            span = schedule.spanDays
        } else if isResizingTop {
            start = cal.date(byAdding: .day, value: topDayDelta, to: baseStart) ?? baseStart
            span = max(1, schedule.spanDays - topDayDelta)
        } else {
            start = baseStart
            span = max(1, schedule.spanDays + bottomDayDelta)
        }
        let end = cal.date(byAdding: .day, value: max(0, span - 1), to: start) ?? start
        let startStr = RmbFormatters.monthDay.string(from: start)
        let endStr = RmbFormatters.monthDay.string(from: end)
        return span <= 1 ? "\(startStr) · 1天" : "\(startStr)–\(endStr) · \(span)天"
    }

    private var isActiveDrag: Bool {
        isMoving || isResizingTop || isResizingBottom
    }

    private var isStartClippedBeforeWeek: Bool {
        guard let start = schedule.startDate else { return false }
        return PinnedTaskSchedule.dayDifference(from: pinnedStore.weekStartDate, to: start) < 0
    }

    private var isEndClippedAfterWeek: Bool {
        guard let start = schedule.startDate else { return false }
        let rawEnd = PinnedTaskSchedule.dayDifference(from: pinnedStore.weekStartDate, to: start) + schedule.spanDays - 1
        return rawEnd > 6
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isActiveDrag {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(quadrantColor.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(quadrantColor.opacity(0.65), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    )
                    .frame(width: blockWidth, height: snappedGuideHeight)
                    .offset(x: blockX, y: snappedGuideTopY)
                    .allowsHitTesting(false)
            }

            cardContent
                .frame(width: blockWidth, height: liveHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isVisuallyDone
                                ? Color.green.opacity(isDone ? (isHovered ? 0.10 : 0.065) : 0.14)
                                : quadrantColor.opacity(isActiveDrag ? 0.22 : (isHovered ? 0.17 : 0.12))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isVisuallyDone
                                ? Color.green.opacity(isHovered ? 0.42 : 0.22)
                                : (isActiveDrag ? quadrantColor : quadrantColor.opacity(isHovered ? 0.5 : 0.3)),
                            lineWidth: isActiveDrag ? 1.5 : 0.75
                        )
                )
                .shadow(color: isActiveDrag ? .black.opacity(0.16) : .clear, radius: 7, y: 3)
                .opacity(isCompleting ? 0.65 : (isDone ? 0.80 : 1.0))
                .offset(x: blockX, y: liveTopY)
                .zIndex(isActiveDrag ? 10 : 1)
                .onHover { isHovered = $0 }
                .contextMenu {
                    if isDone {
                        Button("恢复为未完成") {
                            pinnedStore.uncompleteItem(reminderItem)
                        }
                        Divider()
                    }
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
                    if !isDone {
                        Button("番茄钟专注此任务") {
                            PomodoroService.shared.focusOnTask(id: reminderItem.id, title: reminderItem.reminder.title ?? "")
                            PinnedPanelController.shared.snapPomodoroToTopRightCorner()
                        }
                    }
                    Divider()
                    Button("移回待安排") {
                        pinnedStore.unscheduleCompletely(for: reminderItem.id)
                    }
                    Button("删除任务", role: .destructive) {
                        pinnedStore.removeItem(reminderItem.reminder)
                    }
                }
        }
    }

    private var cardContent: some View {
        ZStack {
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isVisuallyDone ? Color.green.opacity(isDone ? 0.55 : 0.9) : quadrantColor)
                    .frame(width: 3.5)
                    .padding(.vertical, 5)
                    .padding(.leading, 3.5)

                // Completion button isolated OUTSIDE drag/tap gesture & clear of top resize bar!
                InstantCompleteCircle(
                    color: quadrantColor,
                    isCompleted: isVisuallyDone
                ) {
                    pinnedStore.toggleComplete(reminderItem)
                }
                .padding(.leading, 7)
                .padding(.top, 8)

                // Tappable & draggable title/notes region (only active when not done)
                VStack(alignment: .leading, spacing: 3) {
                    Text(reminderItem.reminder.title ?? "")
                        .font(.system(size: 12, weight: isDone ? .medium : .semibold))
                        .strikethrough(isVisuallyDone, color: .secondary)
                        .foregroundColor(isVisuallyDone ? .secondary : .primary)
                        .lineLimit(liveHeight > 80 ? 3 : 2)

                    if let notes = notesPreview, liveHeight >= 60 {
                        Text(notes)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(liveHeight > 110 ? 2 : 1)
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 4)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isActiveDrag {
                        onTapEdit()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .named("dayCanvas"))
                        .onChanged { value in
                            guard !isDone else { return }
                            isMoving = true
                            moveDeltaY = value.translation.height
                        }
                        .onEnded { _ in
                            guard isMoving else { return }
                            let delta = moveDayDelta
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                if let baseStart = schedule.startDate,
                                   let nextStart = Calendar.current.date(byAdding: .day, value: delta, to: baseStart) {
                                    pinnedStore.setDaySpan(for: reminderItem.id, startDate: nextStart, spanDays: schedule.spanDays)
                                }
                                isMoving = false
                                moveDeltaY = 0
                            }
                        }
                )

                // Trailing hover actions isolated OUTSIDE drag/tap gesture
                trailingActions
                    .padding(.trailing, 7)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Top & Bottom AppKit-backed Resize Edges (only on unclipped edges so guide & saved dates match 1:1)
            if !isDone {
                VStack(spacing: 0) {
                    if !isStartClippedBeforeWeek {
                        CardVerticalResizeEdge(
                            color: quadrantColor,
                            isActive: isResizingTop,
                            isCardHovered: isHovered,
                            isInteractionActive: isBoardActive,
                            hitHeight: 11,
                            pillAlignment: .center,
                            helpText: "拖动上边缘调整开始日期",
                            onDragChanged: { dy in
                                isResizingTop = true
                                topResizeDeltaY = dy
                            },
                            onDragEnded: { dy in
                                topResizeDeltaY = dy
                                let delta = topDayDelta
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                    if let baseStart = schedule.startDate,
                                       let newStart = Calendar.current.date(byAdding: .day, value: delta, to: baseStart) {
                                        pinnedStore.setDaySpan(
                                            for: reminderItem.id,
                                            startDate: newStart,
                                            spanDays: max(1, schedule.spanDays - delta)
                                        )
                                    }
                                    isResizingTop = false
                                    topResizeDeltaY = 0
                                }
                            },
                            onDragCancelled: {
                                isResizingTop = false
                                topResizeDeltaY = 0
                            }
                        )
                        .padding(.horizontal, 12)
                        .offset(y: -3)
                    }

                    Spacer(minLength: 0)

                    if !isEndClippedAfterWeek {
                        CardVerticalResizeEdge(
                            color: quadrantColor,
                            isActive: isResizingBottom,
                            isCardHovered: isHovered,
                            isInteractionActive: isBoardActive,
                            hitHeight: 14,
                            pillAlignment: .center,
                            helpText: "拖动下边缘拉长或缩短占用天数",
                            onDragChanged: { dy in
                                isResizingBottom = true
                                bottomResizeDeltaY = dy
                            },
                            onDragEnded: { dy in
                                bottomResizeDeltaY = dy
                                let delta = bottomDayDelta
                                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                    if let baseStart = schedule.startDate {
                                        pinnedStore.setDaySpan(
                                            for: reminderItem.id,
                                            startDate: baseStart,
                                            spanDays: max(1, schedule.spanDays + delta)
                                        )
                                    }
                                    isResizingBottom = false
                                    bottomResizeDeltaY = 0
                                }
                            },
                            onDragCancelled: {
                                isResizingBottom = false
                                bottomResizeDeltaY = 0
                            }
                        )
                        .padding(.horizontal, 6)
                        .offset(y: 3)
                    }
                }
            }
        }
        .onChange(of: isBoardActive) { active in
            if !active {
                isMoving = false
                moveDeltaY = 0
                isResizingTop = false
                topResizeDeltaY = 0
                isResizingBottom = false
                bottomResizeDeltaY = 0
            }
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        if isCompleting {
            Text("已完成")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.green)
        } else if isDone {
            if isHovered {
                Button("恢复") {
                    pinnedStore.uncompleteItem(reminderItem)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        } else if isActiveDrag {
            Text(liveDragLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(quadrantColor))
        } else if isHovered {
            HStack(spacing: 4) {
                Button {
                    PomodoroService.shared.focusOnTask(id: reminderItem.id, title: reminderItem.reminder.title ?? "")
                    PinnedPanelController.shared.snapPomodoroToTopRightCorner()
                } label: {
                    Image(systemName: "timer")
                        .font(.system(size: 10.5))
                        .foregroundColor(PomodoroPhase.focus.accentColor)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("右上角番茄钟专注")

                Button {
                    let targetDay = schedule.covers(date: pinnedStore.selectedDate)
                        ? pinnedStore.selectedDate
                        : (schedule.startDate ?? pinnedStore.selectedDate)
                    let comps = Calendar.current.dateComponents([.hour], from: Date())
                    let startMin = max(7, min(21, comps.hour ?? 9)) * 60
                    pinnedStore.selectDate(targetDay)
                    pinnedStore.setTimeSlot(for: reminderItem.id, on: targetDay, startMinute: startMin)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 11))
                        .foregroundColor(quadrantColor)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("排入右栏当日时段")
            }
        }
    }
}

// MARK: - Column 3 (Right 38%): Same-Day Hourly Slots

@MainActor
private struct HourlySlotsColumn: View {
    let columnWidth: CGFloat
    let startHour: Int
    let endHour: Int
    let hourHeight: CGFloat
    let hoveredDropMinute: Int?
    let isBoardActive: Bool
    let onStartDragDayTask: (ReminderItem, CGPoint) -> Void
    let onEndDragDayTask: (ReminderItem, CGPoint) -> Void
    let onSelectTaskForEdit: (ReminderItem) -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @State private var didInitialScroll = false

    private var timeAxisWidth: CGFloat {
        columnWidth < 230 ? 36 : 42
    }
    private var canvasHeight: CGFloat { CGFloat(endHour - startHour) * hourHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.accentColor)

                Text(selectedDayHeaderText)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    Button {
                        pinnedStore.shiftSelectedDate(byDays: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                    Button {
                        pinnedStore.shiftSelectedDate(byDays: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, columnWidth < 230 ? 8 : 11)
            .padding(.vertical, 7.5)

            if !pinnedStore.dayCoveredWithoutSlotOnSelectedDate.isEmpty {
                Divider().opacity(0.3)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("当日待排")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)

                        ForEach(pinnedStore.dayCoveredWithoutSlotOnSelectedDate) { item in
                            CompactDragChip(
                                reminderItem: item,
                                onTap: { onSelectTaskForEdit(item) },
                                onDragChanged: { onStartDragDayTask(item, $0) },
                                onDragEnded: { onEndDragDayTask(item, $0) }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                }
                .background(Color.accentColor.opacity(0.035))
            }

            Divider().opacity(0.35)

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(startHour..<endHour, id: \.self) { hour in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(String(format: "%02d:00", hour))
                                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondary.opacity(0.75))
                                        .frame(width: timeAxisWidth, alignment: .trailing)
                                        .offset(y: -5)

                                    VStack(spacing: 0) {
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.08))
                                            .frame(height: 0.75)
                                        Spacer()
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.03))
                                            .frame(height: 0.5)
                                        Spacer()
                                    }
                                }
                                .frame(height: hourHeight)
                                .id("hour-\(hour)")
                            }
                        }

                        if let dropMin = hoveredDropMinute {
                            let previewDur = max(15, min(60, endHour * 60 - dropMin))
                            let topY = CGFloat(dropMin - startHour * 60) / 60.0 * hourHeight
                            let previewH = max(26, CGFloat(previewDur) / 60.0 * hourHeight)
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.4, dash: [5, 3]))
                                )
                                .overlay(
                                    HStack {
                                        Text("\(DayTimeSlot.formatMinute(dropMin))–\(DayTimeSlot.formatMinute(dropMin + previewDur))")
                                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.accentColor)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                )
                                .frame(height: previewH)
                                .padding(.leading, timeAxisWidth + 7)
                                .padding(.trailing, 8)
                                .offset(y: topY)
                                .allowsHitTesting(false)
                        }

                        GeometryReader { geo in
                            let trackLeft = timeAxisWidth + 7
                            let trackWidth = max(110, geo.size.width - trackLeft - 8)
                            let laidOut = layoutHourlySlots(pinnedStore.timeSlotItemsForSelectedDate)

                            ForEach(laidOut, id: \.item.id) { placed in
                                let colW = max(24, (trackWidth - CGFloat(placed.totalColumns - 1) * 5) / CGFloat(placed.totalColumns))
                                let colX = trackLeft + CGFloat(placed.columnIndex) * (colW + 5)

                                HourlySlotBlockView(
                                    reminderItem: placed.item,
                                    slot: placed.slot,
                                    startHour: startHour,
                                    endHour: endHour,
                                    hourHeight: hourHeight,
                                    blockWidth: colW,
                                    blockX: colX,
                                    isBoardActive: isBoardActive,
                                    onTapEdit: { onSelectTaskForEdit(placed.item) }
                                )
                            }
                        }

                        if pinnedStore.isViewingToday {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                if let nowY = currentTimeYOffset(for: context.date) {
                                    HStack(spacing: 0) {
                                        Spacer().frame(width: timeAxisWidth + 2)
                                        Circle()
                                            .fill(Color.red.opacity(0.9))
                                            .frame(width: 6, height: 6)
                                        Rectangle()
                                            .fill(Color.red.opacity(0.45))
                                            .frame(height: 1)
                                    }
                                    .offset(y: nowY - 3)
                                    .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .coordinateSpace(name: "timeCanvas")
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(height: canvasHeight + 24, alignment: .top)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TimeCanvasFrameKey.self, value: proxy.frame(in: .named("tripleBoardRoot")))
                        }
                    )
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TimeViewportFrameKey.self, value: proxy.frame(in: .named("tripleBoardRoot")))
                    }
                )
                .onAppear {
                    guard !didInitialScroll else { return }
                    didInitialScroll = true
                    let currentHour = Calendar.current.component(.hour, from: Date())
                    let targetHour = max(startHour, min(endHour - 3, currentHour - 1))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        scrollProxy.scrollTo("hour-\(targetHour)", anchor: .top)
                    }
                }
            }
        }
    }

    private var selectedDayHeaderText: String {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(pinnedStore.selectedDate)
        let isTomorrow = cal.isDateInTomorrow(pinnedStore.selectedDate)

        if columnWidth >= 255 {
            let s = RmbFormatters.monthDayChinese.string(from: pinnedStore.selectedDate)
            if isToday { return "当日时段 · 今天 \(s)" }
            if isTomorrow { return "当日时段 · 明天 \(s)" }
            return "当日时段 · \(s)"
        } else if columnWidth >= 195 {
            let s = RmbFormatters.monthDayChinese.string(from: pinnedStore.selectedDate)
            if isToday { return "今天 \(s)" }
            if isTomorrow { return "明天 \(s)" }
            return "时段 · \(s)"
        } else {
            let s = RmbFormatters.monthDay.string(from: pinnedStore.selectedDate)
            if isToday { return "今天 \(s)" }
            if isTomorrow { return "明天 \(s)" }
            return s
        }
    }

    private func currentTimeYOffset(for date: Date) -> CGFloat? {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard mins >= startHour * 60 && mins <= endHour * 60 else { return nil }
        return CGFloat(mins - startHour * 60) / 60.0 * hourHeight
    }

    private struct PlacedSlot {
        let item: ReminderItem
        let slot: DayTimeSlot
        let columnIndex: Int
        let totalColumns: Int
    }

    private func layoutHourlySlots(_ entries: [(item: ReminderItem, slot: DayTimeSlot)]) -> [PlacedSlot] {
        let sorted = entries.sorted { lhs, rhs in
            if lhs.slot.startMinute != rhs.slot.startMinute {
                return lhs.slot.startMinute < rhs.slot.startMinute
            }
            if lhs.slot.endMinute != rhs.slot.endMinute {
                return lhs.slot.endMinute > rhs.slot.endMinute
            }
            return lhs.item.id < rhs.item.id
        }

        // Account for visual minimum block height (26pt) so consecutive 15-minute slots sit
        // side-by-side instead of overlapping visually.
        let minVisualMinutes = Int(ceil(26.0 / hourHeight * 60.0))

        // Partition into connected overlap clusters so transitive overlaps never produce colliding column widths.
        var clusters: [[(item: ReminderItem, slot: DayTimeSlot)]] = []
        var clusterMaxEnd = Int.min
        for entry in sorted {
            let visualEnd = max(entry.slot.endMinute, entry.slot.startMinute + minVisualMinutes)
            if clusters.isEmpty || entry.slot.startMinute >= clusterMaxEnd {
                clusters.append([entry])
                clusterMaxEnd = visualEnd
            } else {
                clusters[clusters.count - 1].append(entry)
                clusterMaxEnd = max(clusterMaxEnd, visualEnd)
            }
        }

        var result: [PlacedSlot] = []
        for cluster in clusters {
            var colEnds: [Int] = []
            var assigned: [(item: ReminderItem, slot: DayTimeSlot, col: Int)] = []
            for entry in cluster {
                let s = entry.slot.startMinute
                let e = max(entry.slot.endMinute, s + minVisualMinutes)
                var placedCol: Int?
                for idx in colEnds.indices where colEnds[idx] <= s {
                    placedCol = idx
                    colEnds[idx] = e
                    break
                }
                if let c = placedCol {
                    assigned.append((entry.item, entry.slot, c))
                } else {
                    colEnds.append(e)
                    assigned.append((entry.item, entry.slot, colEnds.count - 1))
                }
            }
            let totalCols = max(1, colEnds.count)
            for cur in assigned {
                result.append(PlacedSlot(item: cur.item, slot: cur.slot, columnIndex: cur.col, totalColumns: totalCols))
            }
        }
        return result
    }
}

// MARK: - Right Column Hourly Block

@MainActor
private struct HourlySlotBlockView: View {
    let reminderItem: ReminderItem
    let slot: DayTimeSlot
    let startHour: Int
    let endHour: Int
    let hourHeight: CGFloat
    let blockWidth: CGFloat
    let blockX: CGFloat
    let isBoardActive: Bool
    let onTapEdit: () -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared

    @State private var moveDeltaY: CGFloat = 0
    @State private var topResizeDeltaY: CGFloat = 0
    @State private var bottomResizeDeltaY: CGFloat = 0
    @State private var isMoving = false
    @State private var isResizingTop = false
    @State private var isResizingBottom = false
    @State private var isHovered = false

    private var isDone: Bool {
        reminderItem.reminder.isCompleted
    }

    private var isCompleting: Bool {
        pinnedStore.isCompleting(reminderItem.id)
    }

    private var isVisuallyDone: Bool {
        isDone || isCompleting
    }

    private var quadrantColor: Color {
        reminderItem.reminder.ekPriority.quadrantColor
    }

    private var notesPreview: String? {
        guard userPreferences.showNotesInReminderItem else { return nil }
        let trimmed = (reminderItem.reminder.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var isActiveDrag: Bool {
        isMoving || isResizingTop || isResizingBottom
    }

    private var minBlockHeight: CGFloat {
        max(26, (15.0 / 60.0) * hourHeight)
    }

    private var totalCanvasPx: CGFloat {
        CGFloat(endHour - startHour) * hourHeight
    }

    private var baseTopY: CGFloat {
        CGFloat(slot.startMinute - startHour * 60) / 60.0 * hourHeight
    }

    private var baseHeight: CGFloat {
        max(minBlockHeight, CGFloat(slot.durationMinutes) / 60.0 * hourHeight - 2)
    }

    private var snappedStartMinute: Int {
        if isMoving {
            let delta = Int(((moveDeltaY / hourHeight) * 60.0 / 15.0).rounded()) * 15
            let maxStart = max(startHour * 60, endHour * 60 - slot.durationMinutes)
            return max(startHour * 60, min(maxStart, slot.startMinute + delta))
        } else if isResizingTop {
            let delta = Int(((topResizeDeltaY / hourHeight) * 60.0 / 15.0).rounded()) * 15
            let minStart = max(startHour * 60, slot.endMinute - 480)
            let maxStart = max(minStart, slot.endMinute - 15)
            return max(minStart, min(maxStart, slot.startMinute + delta))
        }
        return slot.startMinute
    }

    private var snappedDurationMinutes: Int {
        if isResizingBottom {
            let delta = Int(((bottomResizeDeltaY / hourHeight) * 60.0 / 15.0).rounded()) * 15
            let maxDur = max(15, min(480, endHour * 60 - slot.startMinute))
            return max(15, min(maxDur, slot.durationMinutes + delta))
        } else if isResizingTop {
            return max(15, min(480, slot.endMinute - snappedStartMinute))
        }
        return slot.durationMinutes
    }

    private var liveTopY: CGFloat {
        if isMoving {
            return (baseTopY + moveDeltaY).constrainedTo(min: 0, max: max(0, totalCanvasPx - baseHeight))
        } else if isResizingTop {
            let bottomEdge = baseTopY + baseHeight
            let minTop = max(0, bottomEdge - 8.0 * hourHeight)
            let maxTop = max(minTop, bottomEdge - minBlockHeight)
            return (baseTopY + topResizeDeltaY).constrainedTo(min: minTop, max: maxTop)
        }
        return baseTopY
    }

    private var liveHeight: CGFloat {
        if isResizingBottom {
            let maxH = max(minBlockHeight, min(8.0 * hourHeight, totalCanvasPx - baseTopY))
            return (baseHeight + bottomResizeDeltaY).constrainedTo(min: minBlockHeight, max: maxH)
        } else if isResizingTop {
            let bottomEdge = baseTopY + baseHeight
            return max(minBlockHeight, bottomEdge - liveTopY)
        }
        return baseHeight
    }

    private var snappedGuideTopY: CGFloat {
        CGFloat(snappedStartMinute - startHour * 60) / 60.0 * hourHeight
    }

    private var snappedGuideHeight: CGFloat {
        max(minBlockHeight, CGFloat(snappedDurationMinutes) / 60.0 * hourHeight - 2)
    }

    private var liveDragTimeLabel: String {
        let start = snappedStartMinute
        let dur = snappedDurationMinutes
        let end = min(24 * 60, start + dur)
        return "\(DayTimeSlot.formatMinute(start))–\(DayTimeSlot.formatMinute(end)) · \(DayTimeSlot.formatDuration(dur))"
    }

    var body: some View {
        let compact = liveHeight < 40

        ZStack(alignment: .topLeading) {
            if isActiveDrag {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(quadrantColor.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(quadrantColor.opacity(0.65), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                    )
                    .frame(width: blockWidth, height: snappedGuideHeight)
                    .offset(x: blockX, y: snappedGuideTopY)
                    .allowsHitTesting(false)
            }

            blockContent(compact: compact)
                .frame(width: blockWidth, height: liveHeight)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isVisuallyDone
                                ? Color.green.opacity(isDone ? (isHovered ? 0.10 : 0.065) : 0.14)
                                : quadrantColor.opacity(isActiveDrag ? 0.22 : (isHovered ? 0.18 : 0.13))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isVisuallyDone
                                ? Color.green.opacity(isHovered ? 0.42 : 0.22)
                                : (isActiveDrag ? quadrantColor : quadrantColor.opacity(isHovered ? 0.5 : 0.3)),
                            lineWidth: isActiveDrag ? 1.5 : 0.75
                        )
                )
                .shadow(color: isActiveDrag ? .black.opacity(0.16) : .clear, radius: 7, y: 3)
                .opacity(isCompleting ? 0.65 : (isDone ? 0.80 : 1.0))
                .offset(x: blockX, y: liveTopY)
                .zIndex(isActiveDrag ? 10 : 1)
                .onHover { isHovered = $0 }
                .contextMenu {
                    if isDone {
                        Button("恢复为未完成") {
                            pinnedStore.uncompleteItem(reminderItem)
                        }
                        Divider()
                    }
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
                    if !isDone {
                        Button("番茄钟专注此任务") {
                            PomodoroService.shared.focusOnTask(id: reminderItem.id, title: reminderItem.reminder.title ?? "")
                            PinnedPanelController.shared.snapPomodoroToTopRightCorner()
                        }
                    }
                    Divider()
                    Button("移除今日时段占用") {
                        pinnedStore.clearTimeSlot(for: reminderItem.id)
                    }
                    Button("移回待安排") {
                        pinnedStore.unscheduleCompletely(for: reminderItem.id)
                    }
                    Button("删除任务", role: .destructive) {
                        pinnedStore.removeItem(reminderItem.reminder)
                    }
                }
        }
    }

    private func blockContent(compact: Bool) -> some View {
        let narrowBlock = blockWidth < 118

        return ZStack {
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isVisuallyDone ? Color.green.opacity(isDone ? 0.55 : 0.9) : quadrantColor)
                    .frame(width: narrowBlock ? 2.5 : 3.5)
                    .padding(.vertical, 4.5)
                    .padding(.leading, narrowBlock ? 2.5 : 3.5)

                // Completion button isolated OUTSIDE drag/tap gesture & clear of top resize bar!
                InstantCompleteCircle(
                    color: quadrantColor,
                    isCompleted: isVisuallyDone
                ) {
                    pinnedStore.toggleComplete(reminderItem)
                }
                .padding(.leading, narrowBlock ? 4.5 : 7)
                .padding(.top, compact ? 5 : 7)

                // Tappable & draggable title/notes region
                VStack(alignment: .leading, spacing: 3) {
                    Text(reminderItem.reminder.title ?? "")
                        .font(.system(size: (compact || narrowBlock) ? 11 : 12, weight: isDone ? .medium : .semibold))
                        .strikethrough(isVisuallyDone, color: .secondary)
                        .foregroundColor(isVisuallyDone ? .secondary : .primary)
                        .lineLimit(compact ? 1 : 2)

                    if let notes = notesPreview, liveHeight >= 56, !narrowBlock {
                        Text(notes)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                            .lineLimit(liveHeight > 100 ? 2 : 1)
                    }
                }
                .padding(.leading, narrowBlock ? 4 : 6)
                .padding(.trailing, 4)
                .padding(.vertical, compact ? 4 : 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isActiveDrag {
                        onTapEdit()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .named("timeCanvas"))
                        .onChanged { value in
                            guard !isDone else { return }
                            isMoving = true
                            moveDeltaY = value.translation.height
                        }
                        .onEnded { _ in
                            guard isMoving else { return }
                            let finalStart = snappedStartMinute
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                pinnedStore.setTimeSlot(
                                    for: reminderItem.id,
                                    on: pinnedStore.selectedDate,
                                    startMinute: finalStart,
                                    durationMinutes: slot.durationMinutes
                                )
                                isMoving = false
                                moveDeltaY = 0
                            }
                        }
                )

                // Trailing hover actions isolated OUTSIDE drag/tap gesture
                slotTrailingActions(narrowBlock: narrowBlock)
                    .padding(.trailing, narrowBlock ? 4.5 : 7)
                    .padding(.top, compact ? 5 : 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if !isDone {
                VStack(spacing: 0) {
                    CardVerticalResizeEdge(
                        color: quadrantColor,
                        isActive: isResizingTop,
                        isCardHovered: isHovered,
                        isInteractionActive: isBoardActive,
                        hitHeight: compact ? 8 : 11,
                        pillAlignment: .center,
                        helpText: "拖动上边缘调整开始时间",
                        onDragChanged: { dy in
                            isResizingTop = true
                            topResizeDeltaY = dy
                        },
                        onDragEnded: { dy in
                            topResizeDeltaY = dy
                            let finalStart = snappedStartMinute
                            let finalDur = snappedDurationMinutes
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                pinnedStore.setTimeSlot(
                                    for: reminderItem.id,
                                    on: pinnedStore.selectedDate,
                                    startMinute: finalStart,
                                    durationMinutes: finalDur
                                )
                                isResizingTop = false
                                topResizeDeltaY = 0
                            }
                        },
                        onDragCancelled: {
                            isResizingTop = false
                            topResizeDeltaY = 0
                        }
                    )
                    .padding(.horizontal, compact ? 24 : 12)
                    .offset(y: -1)

                    Spacer(minLength: 0)

                    CardVerticalResizeEdge(
                        color: quadrantColor,
                        isActive: isResizingBottom,
                        isCardHovered: isHovered,
                        isInteractionActive: isBoardActive,
                        hitHeight: compact ? 9 : 13,
                        pillAlignment: .center,
                        helpText: "拖动下边缘拉长或缩短占用时长",
                        onDragChanged: { dy in
                            isResizingBottom = true
                            bottomResizeDeltaY = dy
                        },
                        onDragEnded: { dy in
                            bottomResizeDeltaY = dy
                            let finalDur = snappedDurationMinutes
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                                pinnedStore.setTimeSlot(
                                    for: reminderItem.id,
                                    on: pinnedStore.selectedDate,
                                    startMinute: slot.startMinute,
                                    durationMinutes: finalDur
                                )
                                isResizingBottom = false
                                bottomResizeDeltaY = 0
                            }
                        },
                        onDragCancelled: {
                            isResizingBottom = false
                            bottomResizeDeltaY = 0
                        }
                    )
                    .padding(.horizontal, 6)
                    .offset(y: 1)
                }
            }
        }
        .onChange(of: isBoardActive) { active in
            if !active {
                isMoving = false
                moveDeltaY = 0
                isResizingTop = false
                topResizeDeltaY = 0
                isResizingBottom = false
                bottomResizeDeltaY = 0
            }
        }
    }

    @ViewBuilder
    private func slotTrailingActions(narrowBlock: Bool) -> some View {
        if isCompleting {
            Text("已完成")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.green)
        } else if isDone {
            if isHovered && !narrowBlock {
                Button("恢复") {
                    pinnedStore.uncompleteItem(reminderItem)
                }
                .buttonStyle(.plain)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        } else if isActiveDrag {
            Text(liveDragTimeLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(quadrantColor))
        } else if isHovered && !narrowBlock {
            HStack(spacing: 4) {
                Button {
                    PomodoroService.shared.focusOnTask(id: reminderItem.id, title: reminderItem.reminder.title ?? "")
                    PinnedPanelController.shared.snapPomodoroToTopRightCorner()
                } label: {
                    Image(systemName: "timer")
                        .font(.system(size: 10.5))
                        .foregroundColor(PomodoroPhase.focus.accentColor)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("右上角番茄钟专注")

                Button {
                    pinnedStore.clearTimeSlot(for: reminderItem.id)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("移除今日时段占用")
            }
        }
    }
}

/// AppKit-backed vertical resize handle for day-span & hourly-slot cards.
/// Uses native `resetCursorRects()` (`.resizeUpDown`) and screen-space `NSEvent.mouseLocation.y`
/// drag tracking so resizing responds on the very first pixel, keeps the ↕ cursor locked throughout,
/// and never loses drags to enclosing `ScrollView` or card tap/move gestures.
private struct CardVerticalResizeEdge: View {
    let color: Color
    let isActive: Bool
    let isCardHovered: Bool
    let isInteractionActive: Bool
    let hitHeight: CGFloat
    let pillAlignment: Alignment
    let helpText: String
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    var onDragCancelled: (() -> Void)? = nil

    @State private var isHandleHovered = false

    private var pillWidth: CGFloat {
        (isActive || isHandleHovered) ? 42 : 30
    }

    private var pillHeight: CGFloat {
        (isActive || isHandleHovered) ? 3.5 : 2.5
    }

    private var pillOpacity: Double {
        if isActive {
            return 1.0
        }
        if isHandleHovered {
            return 0.90
        }
        if isCardHovered {
            return 0.50
        }
        return 0.0
    }

    var body: some View {
        ZStack(alignment: pillAlignment) {
            Capsule()
                .fill(color.opacity(pillOpacity))
                .frame(width: pillWidth, height: pillHeight)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: isHandleHovered)

            VerticalResizeMouseCatcher(
                isInteractionActive: isInteractionActive,
                onHoverChanged: { hovering in
                    isHandleHovered = hovering
                },
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded,
                onDragCancelled: onDragCancelled
            )
        }
        .frame(maxWidth: .infinity)
        .frame(height: hitHeight)
        .contentShape(Rectangle())
        .help(helpText)
    }
}

private struct VerticalResizeMouseCatcher: NSViewRepresentable {
    let isInteractionActive: Bool
    let onHoverChanged: (Bool) -> Void
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void
    let onDragCancelled: (() -> Void)?

    func makeNSView(context: Context) -> VerticalResizeMouseNSView {
        let view = VerticalResizeMouseNSView()
        view.onHoverChanged = onHoverChanged
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onDragCancelled = onDragCancelled
        view.setInteractionActive(isInteractionActive)
        return view
    }

    func updateNSView(_ nsView: VerticalResizeMouseNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.onDragCancelled = onDragCancelled
        nsView.setInteractionActive(isInteractionActive)
    }
}

private final class VerticalResizeMouseNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?
    var onDragCancelled: (() -> Void)?

    private var isInteractionActive = true
    private var initialMouseScreenY: CGFloat = 0
    private var isDragging = false
    private var hasMoved = false
    private var isPointerInside = false
    private var hoverTrackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setInteractionActive(_ active: Bool) {
        let shouldHide = !active
        guard isInteractionActive != active || isHidden != shouldHide else { return }
        isInteractionActive = active
        isHidden = shouldHide
        if !active && (isPointerInside || isDragging) {
            let wasDragging = isDragging
            isDragging = false
            hasMoved = false
            isPointerInside = false
            onHoverChanged?(false)
            if wasDragging {
                onDragCancelled?()
            }
            NSCursor.arrow.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil && (isPointerInside || isDragging) {
            let wasDragging = isDragging
            isDragging = false
            hasMoved = false
            isPointerInside = false
            if wasDragging {
                onDragCancelled?()
            }
            NSCursor.arrow.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isInteractionActive, !isHiddenOrHasHiddenAncestor else { return }
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInteractionActive, !isHiddenOrHasHiddenAncestor else { return }
        NSCursor.resizeUpDown.set()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractionActive, !isHiddenOrHasHiddenAncestor else { return }
        isPointerInside = true
        NSCursor.resizeUpDown.set()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isInteractionActive, !isHiddenOrHasHiddenAncestor else {
            isPointerInside = false
            return
        }
        isPointerInside = false
        if !isDragging {
            NSCursor.arrow.set()
            onHoverChanged?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractionActive, !isHiddenOrHasHiddenAncestor else { return }
        initialMouseScreenY = NSEvent.mouseLocation.y
        isDragging = true
        hasMoved = false
        NSCursor.resizeUpDown.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, isInteractionActive, !isHiddenOrHasHiddenAncestor else { return }
        NSCursor.resizeUpDown.set()
        let dy = initialMouseScreenY - NSEvent.mouseLocation.y
        hasMoved = true
        onDragChanged?(dy)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        let dy = initialMouseScreenY - NSEvent.mouseLocation.y
        let didMove = hasMoved
        isDragging = false
        hasMoved = false

        if didMove && isInteractionActive {
            onDragEnded?(dy)
        }

        if isInteractionActive, !isHiddenOrHasHiddenAncestor, let window {
            let ptInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let ptInSelf = convert(ptInWindow, from: nil)
            let stillInside = bounds.contains(ptInSelf)
            isPointerInside = stillInside
            onHoverChanged?(stillInside)
            if stillInside {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
            window.invalidateCursorRects(for: self)
        } else {
            isPointerInside = false
            onHoverChanged?(false)
            NSCursor.arrow.set()
        }
    }
}

// MARK: - Compact Drag Chip (Used in Right Column's "当日待排" strip)

@MainActor
private struct CompactDragChip: View {
    let reminderItem: ReminderItem
    let onTap: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    @State private var isHovered = false
    @State private var isDragging = false

    private var quadrantColor: Color {
        reminderItem.reminder.ekPriority.quadrantColor
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(quadrantColor)
                .frame(width: 7, height: 7)

            Text(reminderItem.reminder.title ?? "")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(quadrantColor.opacity(isHovered ? 0.16 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(quadrantColor.opacity(isHovered ? 0.45 : 0.22), lineWidth: 0.75)
        )
        .opacity(isDragging ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDisappear { isDragging = false }
        .onTapGesture {
            if !isDragging { onTap() }
        }
        .contextMenu {
            Button("排入当前时段") {
                let comps = Calendar.current.dateComponents([.hour], from: Date())
                let startMin = max(7, min(21, comps.hour ?? 9)) * 60
                PinnedRemindersStore.shared.setTimeSlot(
                    for: reminderItem.id,
                    on: PinnedRemindersStore.shared.selectedDate,
                    startMinute: startMin
                )
            }
            Button("标记完成") {
                PinnedRemindersStore.shared.toggleComplete(reminderItem)
            }
            Button("番茄钟专注此任务") {
                PomodoroService.shared.focusOnTask(id: reminderItem.id, title: reminderItem.reminder.title ?? "")
                PinnedPanelController.shared.enterCornerMiniMode(tab: .pomodoro)
            }
            Divider()
            Button("编辑任务…") { onTap() }
        }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named("tripleBoardRoot"))
                .onChanged { value in
                    isDragging = true
                    onDragChanged(value.location)
                }
                .onEnded { value in
                    isDragging = false
                    onDragEnded(value.location)
                }
        )
    }
}

// MARK: - Shared Components

struct InstantCompleteCircle: View {
    let color: Color
    let isCompleted: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            isHovered = false
            action()
        } label: {
            ZStack {
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .foregroundColor(.green)
                        .transition(.scale(scale: 0.45).combined(with: .opacity))
                } else {
                    Image(systemName: isHovered ? "checkmark.circle" : "circle")
                        .resizable()
                        .foregroundColor(isHovered ? .green : color)
                }
            }
            .frame(width: 14, height: 14)
            .scaleEffect(isCompleted ? 1.15 : (isHovered ? 1.08 : 1.0))
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isCompleted)
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isCompleted ? "点击恢复为未完成" : "点击完成任务")
    }
}

// MARK: - Shared Completed Tasks Section, Zero-Jitter Row & Floating Undo Toast

@MainActor
struct CompletedTasksSection: View {
    let onTapEdit: (ReminderItem) -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @State private var isExpanded = false
    @State private var showAll = false

    private let previewLimit = 8

    var body: some View {
        let items = pinnedStore.rangedCompletedItems

        VStack(alignment: .leading, spacing: 6) {
            // Section header with collapse toggle + time-range selector
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9.5))
                            .foregroundColor(.green.opacity(0.85))
                        Text("已完成")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("\(items.count)")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.85))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                // Compact time-range filter menu (`今日` / `近 7 天` / `近 30 天`)
                Menu {
                    ForEach(CompletedTimeRange.allCases) { range in
                        Button {
                            pinnedStore.completedTimeRange = range
                            showAll = false
                            if !isExpanded { isExpanded = true }
                        } label: {
                            HStack {
                                Text(range.title)
                                if pinnedStore.completedTimeRange == range {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(pinnedStore.completedTimeRange.shortTitle) ▾")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                }
                .modifier(RmbPlainMenuStyle())
                .fixedSize()
                .help("筛选已完成任务的时间范围")
            }
            .padding(.horizontal, 2)

            if isExpanded {
                VStack(spacing: 0) {
                    if items.isEmpty {
                        HStack(spacing: 6) {
                            Text("\(pinnedStore.completedTimeRange.title)暂无已完成")
                                .font(.system(size: 10.5))
                                .foregroundColor(.secondary.opacity(0.72))

                            Spacer()

                            if pinnedStore.completedTimeRange == .today {
                                Button("看近7天") {
                                    pinnedStore.completedTimeRange = .last7Days
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                    } else {
                        let displayed = showAll ? items : Array(items.prefix(previewLimit))
                        ForEach(Array(displayed.enumerated()), id: \.element.id) { idx, item in
                            CompletedTaskRow(
                                reminderItem: item,
                                onTapEdit: { onTapEdit(item) }
                            )

                            if idx < displayed.count - 1 {
                                Divider()
                                    .padding(.leading, 29)
                                    .opacity(0.24)
                            }
                        }

                        if items.count > previewLimit {
                            Divider().opacity(0.24)
                            Button {
                                withAnimation(.easeInOut(duration: 0.14)) {
                                    showAll.toggle()
                                }
                            } label: {
                                Text(showAll ? "收起较早记录" : "展开其余 \(items.count - previewLimit) 项")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.026))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }
}

/// Strictly fixed-height (`32pt`), fixed-trailing-width completed row — 0.0px layout shift on hover!
@MainActor
struct CompletedTaskRow: View {
    let reminderItem: ReminderItem
    let onTapEdit: () -> Void

    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Button {
                pinnedStore.uncompleteItem(reminderItem)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(isHovered ? .green : .green.opacity(0.75))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("点击恢复为未完成")

            Text(reminderItem.reminder.title ?? "")
                .font(.system(size: 11.5, weight: .regular))
                .strikethrough(true, color: .secondary.opacity(0.65))
                .foregroundColor(isHovered ? .primary.opacity(0.78) : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Fixed-width trailing slot: opacity-only swap guarantees ZERO row width/height jitter!
            ZStack(alignment: .trailing) {
                Text(pinnedStore.completionTimeText(for: reminderItem.reminder))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.65))
                    .lineLimit(1)
                    .opacity(isHovered ? 0 : 1)

                Button("恢复") {
                    isHovered = false
                    pinnedStore.uncompleteItem(reminderItem)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.accentColor)
                .padding(.horizontal, 6)
                .frame(height: 19)
                .background(Capsule().fill(Color.accentColor.opacity(0.13)))
                .contentShape(Capsule())
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .help("恢复为未完成任务")
            }
            .frame(width: 40, height: 20, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(isHovered ? Color.primary.opacity(0.045) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture {
            onTapEdit()
        }
        .transaction { $0.animation = nil }
        .contextMenu {
            Button("恢复为未完成") {
                pinnedStore.uncompleteItem(reminderItem)
            }
            Button("编辑任务…") {
                onTapEdit()
            }
            Divider()
            Button("删除任务", role: .destructive) {
                pinnedStore.removeItem(reminderItem.reminder)
            }
        }
    }
}

@MainActor
struct CompletionUndoToastBanner: View {
    let toast: CompletionUndoToast
    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12.5))
                .foregroundColor(.green)

            Text("已完成「\(toast.title)」")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)

            Button("撤销") {
                pinnedStore.undoLastCompletion()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .contentShape(Capsule())

            Button {
                pinnedStore.dismissCompletionToast()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7.5)
        .background(
            Capsule()
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.95))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.green.opacity(0.32), lineWidth: 0.85)
        )
    }
}

struct RmbPlainMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}

private struct PinnedHeaderIconButton: View {
    let symbol: RmbSymbol
    let isHighlighted: Bool
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            isHovered = false
            action()
        } label: {
            Image(rmbSymbol: symbol)
                .font(.system(size: 11, weight: .medium))
                .contentTransition(.identity)
                .foregroundColor(isHighlighted ? .accentColor : (isHovered ? .primary : .secondary))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(
                            isHighlighted
                                ? Color.accentColor.opacity(isHovered ? 0.20 : 0.14)
                                : (isHovered ? Color.primary.opacity(0.08) : Color.clear)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .strokeBorder(
                            isHighlighted ? Color.accentColor.opacity(0.32) : Color.clear,
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
        .transaction { $0.animation = nil }
    }
}
