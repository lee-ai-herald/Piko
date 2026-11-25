import SwiftUI

@MainActor
struct PomodoroView: View {
    @ObservedObject private var pomodoro = PomodoroService.shared
    @ObservedObject private var pinnedStore = PinnedRemindersStore.shared
    @ObservedObject private var userPreferences = UserPreferences.shared

    @State private var customMinutesInput = ""

    private var currentPhaseMinutes: Int {
        switch pomodoro.phase {
        case .focus:
            return userPreferences.pomodoroFocusMinutes
        case .shortBreak:
            return userPreferences.pomodoroShortBreakMinutes
        case .longBreak:
            return userPreferences.pomodoroLongBreakMinutes
        }
    }

    private var quickPresets: [Int] {
        switch pomodoro.phase {
        case .focus:
            return [15, 25, 30, 45, 60]
        case .shortBreak:
            return [3, 5, 8, 10]
        case .longBreak:
            return [10, 15, 20, 30]
        }
    }

    private var accentColor: Color {
        pomodoro.phase.accentColor
    }

    private var secondaryGradientColor: Color {
        switch pomodoro.phase {
        case .focus:
            return Color(red: 0.98, green: 0.56, blue: 0.34)
        case .shortBreak:
            return Color(red: 0.16, green: 0.80, blue: 0.66)
        case .longBreak:
            return Color(red: 0.48, green: 0.44, blue: 0.96)
        }
    }

    private var completedInCurrentCycle: Int {
        let mod = pomodoro.completedFocusToday % 4
        if pomodoro.completedFocusToday > 0 && mod == 0 {
            return 4
        }
        return mod
    }

    var body: some View {
        GeometryReader { geo in
            let isWide = geo.size.width >= 620 && geo.size.height >= 390
            let heroAvailableHeight = max(250, geo.size.height - 40)
            let dialSize: CGFloat = isWide
                ? min(258, max(186, heroAvailableHeight - 156))
                : min(216, max(124, min(geo.size.width * 0.46, heroAvailableHeight - 156)))

            ZStack {
                // Soft layered ambient glow behind the timer stage
                RadialGradient(
                    colors: [
                        accentColor.opacity(pomodoro.isRunning ? 0.14 : 0.07),
                        secondaryGradientColor.opacity(pomodoro.isRunning ? 0.05 : 0.02),
                        Color.clear
                    ],
                    center: isWide ? UnitPoint(x: 0.27, y: 0.48) : UnitPoint(x: 0.5, y: 0.30),
                    startRadius: 24,
                    endRadius: 310
                )
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.45), value: pomodoro.phase)
                .animation(.easeInOut(duration: 0.45), value: pomodoro.isRunning)

                if isWide {
                    HStack(alignment: .center, spacing: 26) {
                        timerHeroStage(dialSize: dialSize)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        VStack(spacing: 14) {
                            focusTaskCard
                            durationControlCard
                            todayStatsCard
                        }
                        .frame(width: min(358, max(276, geo.size.width * 0.41)))
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 16) {
                            timerHeroStage(dialSize: dialSize)
                                .frame(minHeight: max(270, geo.size.height - 32))

                            VStack(spacing: 12) {
                                focusTaskCard
                                durationControlCard
                                todayStatsCard
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                    }
                }
            }
        }
        .onAppear { syncInputField() }
        .onChange(of: pomodoro.phase) { _ in syncInputField() }
        .onChange(of: currentPhaseMinutes) { _ in syncInputField() }
    }

    // MARK: - Left Hero Timer Stage

    private func timerHeroStage(dialSize: CGFloat) -> some View {
        let isTiny = dialSize < 154

        return VStack(spacing: isTiny ? 14 : 20) {
            if let banner = pomodoro.lastFinishedBanner {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text(banner)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 5.5)
                .background(
                    Capsule().fill(Color.green.opacity(0.14))
                )
                .overlay(
                    Capsule().strokeBorder(Color.green.opacity(0.28), lineWidth: 0.75)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Segmented Phase Switcher
            HStack(spacing: 3) {
                ForEach(PomodoroPhase.allCases) { phase in
                    let isSelected = pomodoro.phase == phase
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            pomodoro.selectPhase(phase)
                            syncInputField()
                        }
                    } label: {
                        Text(phase.title)
                            .font(.system(size: isTiny ? 11 : 12, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundColor(isSelected ? .white : .secondary)
                            .padding(.horizontal, isTiny ? 12 : 16)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(isSelected ? phase.accentColor : Color.clear)
                            )
                            .shadow(color: isSelected ? phase.accentColor.opacity(0.26) : .clear, radius: 5, y: 2)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3.5)
            .background(
                Capsule().fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
            )
            .overlay(
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )

            // Isolated 1Hz Concentric Dial (keeps right-side bento cards & layout static during ticks)
            PomodoroDialView(
                ticker: pomodoro.ticker,
                dialSize: dialSize,
                phase: pomodoro.phase,
                isRunning: pomodoro.isRunning,
                accentColor: accentColor,
                secondaryGradientColor: secondaryGradientColor
            )

            // Tactile Transport Controls
            HStack(spacing: isTiny ? 14 : 18) {
                CircularIconControl(
                    symbol: "arrow.counterclockwise",
                    size: isTiny ? 36 : 40,
                    helpText: "重置当前计时"
                ) {
                    pomodoro.resetCurrentPhase()
                }

                Button {
                    if !pomodoro.isRunning {
                        applyCustomInputIfChanged()
                    }
                    pomodoro.toggleStartPause()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                            .font(.system(size: isTiny ? 12 : 13.5, weight: .bold))
                        Text(pomodoro.isRunning ? "暂停计时" : "开始\(pomodoro.phase.title)")
                            .font(.system(size: isTiny ? 12.5 : 14, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, isTiny ? 22 : 30)
                    .padding(.vertical, isTiny ? 9 : 11)
                    .background(
                        Capsule().fill(
                            LinearGradient(
                                colors: [accentColor, secondaryGradientColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    )
                    .shadow(color: accentColor.opacity(0.32), radius: 10, y: 4)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                CircularIconControl(
                    symbol: "forward.end.fill",
                    size: isTiny ? 36 : 40,
                    helpText: "跳至下一阶段"
                ) {
                    pomodoro.skipPhase()
                    syncInputField()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right Companion Bento Cards

    private var focusTaskCard: some View {
        PomodoroGlassCard(title: "专注目标", icon: "target", accent: accentColor) {
            if let title = pomodoro.linkedTaskTitle {
                HStack(spacing: 9) {
                    if let linkedItem = pinnedStore.allItems.first(where: { $0.id == pomodoro.linkedTaskId }) {
                        InstantCompleteCircle(
                            color: linkedItem.reminder.ekPriority.quadrantColor,
                            isCompleted: linkedItem.reminder.isCompleted || pinnedStore.isCompleting(linkedItem.id)
                        ) {
                            pinnedStore.toggleComplete(linkedItem)
                        }
                    } else {
                        Circle()
                            .fill(accentColor)
                            .frame(width: 8, height: 8)
                    }

                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    Spacer()

                    Button {
                        pomodoro.clearLinkedTask()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13.5))
                            .foregroundColor(.secondary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("取消关联")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .fill(accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.22), lineWidth: 0.75)
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Menu {
                        if pinnedStore.allItems.isEmpty {
                            Text("暂无未完成待办")
                        } else {
                            ForEach(Array(pinnedStore.allItems.prefix(20))) { item in
                                Button(item.reminder.title ?? "") {
                                    pomodoro.linkedTaskId = item.id
                                    pomodoro.linkedTaskTitle = item.reminder.title ?? ""
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(pinnedStore.allItems.isEmpty ? "暂无未完成待办任务" : "从规划板选择一个任务绑定专注…")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .contentShape(Rectangle())
                    }
                    .modifier(RmbPlainMenuStyle())

                    // Quick 1-click chips for top active tasks
                    let quickTasks = Array(pinnedStore.allItems.prefix(3))
                    if !quickTasks.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(quickTasks) { item in
                                let qColor = item.reminder.ekPriority.quadrantColor
                                Button {
                                    pomodoro.linkedTaskId = item.id
                                    pomodoro.linkedTaskTitle = item.reminder.title ?? ""
                                } label: {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(qColor)
                                            .frame(width: 5.5, height: 5.5)
                                        Text(item.reminder.title ?? "")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundColor(.primary.opacity(0.85))
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule().fill(qColor.opacity(0.10))
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(qColor.opacity(0.22), lineWidth: 0.6)
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("点击绑定「\(item.reminder.title ?? "")」")
                            }
                        }
                    }
                }
            }
        }
    }

    private var durationControlCard: some View {
        PomodoroGlassCard(
            title: "\(pomodoro.phase.title)时长",
            icon: "slider.horizontal.3",
            accent: accentColor,
            trailingBadge: pomodoro.isRunning ? "计时中" : nil
        ) {
            VStack(spacing: 11) {
                HStack(spacing: 6) {
                    adjustMinuteButton(delta: -5, label: "−5")
                    adjustMinuteButton(delta: -1, label: "−1")

                    Spacer(minLength: 4)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        TextField("", text: $customMinutesInput)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 48)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.07))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(accentColor.opacity(0.22), lineWidth: 0.75)
                            )
                            .onSubmit { applyCustomInput() }

                        Text("分钟")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 4)

                    adjustMinuteButton(delta: 1, label: "+1")
                    adjustMinuteButton(delta: 5, label: "+5")
                }

                HStack(spacing: 6) {
                    ForEach(quickPresets, id: \.self) { mins in
                        let selected = currentPhaseMinutes == mins
                        Button {
                            pomodoro.setDurationMinutes(mins, for: pomodoro.phase)
                            syncInputField()
                        } label: {
                            Text("\(mins)m")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(selected ? .white : .secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(selected ? accentColor : Color.primary.opacity(0.055))
                                )
                                .shadow(color: selected ? accentColor.opacity(0.22) : .clear, radius: 4, y: 1.5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .opacity(pomodoro.isRunning ? 0.45 : 1.0)
            .disabled(pomodoro.isRunning)
        }
    }

    private var todayStatsCard: some View {
        PomodoroGlassCard(title: "今日专注统计", icon: "flame.fill", accent: .orange) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(pomodoro.completedFocusToday)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(.primary)
                        Text("个番茄")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    Text("累计专注约 \(pomodoro.completedFocusToday * userPreferences.pomodoroFocusMinutes) 分钟")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { idx in
                            let filled = idx < completedInCurrentCycle
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(filled ? Color.orange : Color.primary.opacity(0.08))
                                .frame(width: 16, height: 8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(Color.orange.opacity(filled ? 0 : 0.25), lineWidth: 0.75)
                                )
                        }
                    }

                    Text("本轮进度 \(completedInCurrentCycle)/4 · 满 4 轮长休息")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.85))
                }
            }
        }
    }

    // MARK: - Helpers

    private func adjustMinuteButton(delta: Int, label: String) -> some View {
        Button {
            let next = max(1, min(180, currentPhaseMinutes + delta))
            pomodoro.setDurationMinutes(next, for: pomodoro.phase)
            syncInputField()
        } label: {
            Text(label)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 34, height: 29)
                .background(
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func syncInputField() {
        customMinutesInput = "\(currentPhaseMinutes)"
    }

    private func applyCustomInput() {
        if let mins = Int(customMinutesInput.trimmingCharacters(in: .whitespacesAndNewlines)), mins > 0 {
            pomodoro.setDurationMinutes(mins, for: pomodoro.phase)
        }
        syncInputField()
    }

    private func applyCustomInputIfChanged() {
        if let mins = Int(customMinutesInput.trimmingCharacters(in: .whitespacesAndNewlines)),
           mins > 0,
           mins != currentPhaseMinutes {
            pomodoro.setDurationMinutes(mins, for: pomodoro.phase)
        }
        syncInputField()
    }
}

// MARK: - Isolated 1Hz Concentric Dial

@MainActor
private struct PomodoroDialView: View {
    @ObservedObject var ticker: PomodoroTicker
    let dialSize: CGFloat
    let phase: PomodoroPhase
    let isRunning: Bool
    let accentColor: Color
    let secondaryGradientColor: Color

    var body: some View {
        let showTicks = dialSize >= 175
        let ringSize = showTicks ? dialSize * 0.84 : dialSize * 0.92
        let strokeW: CGFloat = dialSize >= 190 ? 10 : 8
        let timeFontSize = max(26, dialSize * 0.205)
        let isTiny = dialSize < 154

        ZStack {
            Circle()
                .fill(accentColor.opacity(isRunning ? 0.07 : 0.03))
                .frame(width: ringSize + 24, height: ringSize + 24)
                .blur(radius: 10)

            if showTicks {
                ForEach(0..<60, id: \.self) { tick in
                    let isMajor = tick.isMultiple(of: 5)
                    let tickProgress = Double(tick) / 60.0
                    let isPassed = tickProgress <= ticker.progress && ticker.progress > 0.005
                    Rectangle()
                        .fill(
                            isPassed
                                ? accentColor.opacity(isMajor ? 0.65 : 0.32)
                                : Color.primary.opacity(isMajor ? 0.16 : 0.06)
                        )
                        .frame(width: isMajor ? 1.6 : 1, height: isMajor ? 7 : 3.5)
                        .offset(y: -(dialSize * 0.485))
                        .rotationEffect(.degrees(Double(tick) * 6))
                }
            }

            Circle()
                .fill(Color(NSColor.windowBackgroundColor).opacity(0.46))
                .frame(width: ringSize, height: ringSize)
                .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
                )

            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: strokeW)
                .frame(width: ringSize, height: ringSize)

            Circle()
                .trim(from: 0, to: max(0.003, ticker.progress))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [accentColor, secondaryGradientColor, accentColor]),
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: strokeW, lineCap: .round)
                )
                .frame(width: ringSize, height: ringSize)
                .rotationEffect(.degrees(-90))
                .shadow(color: accentColor.opacity(isRunning ? 0.34 : 0.12), radius: 8)
                .animation(.linear(duration: 0.25), value: ticker.progress)

            VStack(spacing: isTiny ? 4 : 6) {
                Text(ticker.formattedTime)
                    .font(.system(size: timeFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.primary)

                HStack(spacing: 5) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                        .opacity(isRunning ? 1.0 : 0.5)

                    Text(isRunning ? "\(phase.title)中" : "准备\(phase.title)")
                        .font(.system(size: isTiny ? 10.5 : 11.5, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                .padding(.horizontal, isTiny ? 8 : 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(accentColor.opacity(0.11)))

                if !isTiny && isRunning {
                    Text(ticker.estimatedFinishTimeText)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.85))
                }
            }
        }
        .frame(width: dialSize, height: dialSize)
    }
}

// MARK: - Elevated Glass Card Component

private struct PomodoroGlassCard<Content: View>: View {
    let title: String
    let icon: String
    let accent: Color
    var trailingBadge: String? = nil
    let content: Content

    init(
        title: String,
        icon: String,
        accent: Color,
        trailingBadge: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.accent = accent
        self.trailingBadge = trailingBadge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(accent.opacity(0.14))
                        .frame(width: 22, height: 22)
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(accent)
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary.opacity(0.88))

                Spacer()

                if let trailingBadge {
                    Text(trailingBadge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }
            }

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.085), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.035), radius: 8, y: 2)
    }
}

private struct CircularIconControl: View {
    let symbol: String
    var size: CGFloat = 40
    let helpText: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            isHovered = false
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundColor(isHovered ? .primary : .secondary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        isHovered
                            ? Color.primary.opacity(0.11)
                            : Color(NSColor.controlBackgroundColor).opacity(0.6)
                    )
                )
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}
