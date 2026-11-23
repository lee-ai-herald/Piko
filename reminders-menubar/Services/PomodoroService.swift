import Cocoa
import SwiftUI
import Combine

enum PomodoroPhase: String, CaseIterable, Identifiable {
    case focus
    case shortBreak
    case longBreak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus:
            return "专注"
        case .shortBreak:
            return "短休息"
        case .longBreak:
            return "长休息"
        }
    }

    var accentColor: Color {
        switch self {
        case .focus:
            return Color(red: 0.92, green: 0.34, blue: 0.31)
        case .shortBreak:
            return Color(red: 0.20, green: 0.72, blue: 0.49)
        case .longBreak:
            return Color(red: 0.33, green: 0.52, blue: 0.95)
        }
    }

    var defaultDurationMinutes: Int {
        switch self {
        case .focus:
            return UserPreferences.shared.pomodoroFocusMinutes
        case .shortBreak:
            return UserPreferences.shared.pomodoroShortBreakMinutes
        case .longBreak:
            return UserPreferences.shared.pomodoroLongBreakMinutes
        }
    }
}

@MainActor
final class PomodoroService: ObservableObject {
    static let shared = PomodoroService()

    @Published var phase: PomodoroPhase = .focus
    @Published private(set) var isRunning = false
    @Published private(set) var remainingSeconds: Int
    @Published private(set) var totalSeconds: Int
    @Published var linkedTaskId: String?
    @Published var linkedTaskTitle: String?
    @Published private(set) var completedFocusToday: Int
    @Published var lastFinishedBanner: String?

    private var timer: Timer?
    private var focusStreakInCycle = 0
    private var bannerDismissWork: DispatchWorkItem?
    private var preferenceCancellable: AnyCancellable?

    private init() {
        let initialMinutes = UserPreferences.shared.pomodoroFocusMinutes
        self.totalSeconds = initialMinutes * 60
        self.remainingSeconds = initialMinutes * 60
        self.completedFocusToday = Self.loadCompletedToday()

        preferenceCancellable = Publishers.MergeMany(
            UserPreferences.shared.$pomodoroFocusMinutes.dropFirst().map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$pomodoroShortBreakMinutes.dropFirst().map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$pomodoroLongBreakMinutes.dropFirst().map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$pomodoroShowInMenuBar.dropFirst().map { _ in }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            if !self.isRunning && self.remainingSeconds == self.totalSeconds {
                self.resetCurrentPhase()
            }
            self.notifyMenuBar()
        }
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1.0 - (Double(remainingSeconds) / Double(totalSeconds))
    }

    var formattedTime: String {
        let mins = remainingSeconds / 60
        let secs = remainingSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var menuBarText: String? {
        guard UserPreferences.shared.pomodoroShowInMenuBar else { return nil }
        guard isRunning || remainingSeconds < totalSeconds else { return nil }
        let prefix = phase == .focus ? "🍅" : "☕"
        return "\(prefix) \(formattedTime)"
    }

    // MARK: - Controls

    func toggleStartPause() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning else { return }
        if remainingSeconds <= 0 {
            resetCurrentPhase()
        }
        isRunning = true
        lastFinishedBanner = nil
        notifyMenuBar()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        notifyMenuBar()
    }

    func resetCurrentPhase() {
        pause()
        let seconds = phase.defaultDurationMinutes * 60
        totalSeconds = seconds
        remainingSeconds = seconds
        notifyMenuBar()
    }

    func selectPhase(_ newPhase: PomodoroPhase) {
        pause()
        phase = newPhase
        let seconds = newPhase.defaultDurationMinutes * 60
        totalSeconds = seconds
        remainingSeconds = seconds
        notifyMenuBar()
    }

    func setCustomFocusMinutes(_ minutes: Int) {
        setDurationMinutes(minutes, for: .focus)
    }

    func setDurationMinutes(_ minutes: Int, for targetPhase: PomodoroPhase) {
        let clamped = max(1, min(180, minutes))
        switch targetPhase {
        case .focus:
            UserPreferences.shared.pomodoroFocusMinutes = clamped
        case .shortBreak:
            UserPreferences.shared.pomodoroShortBreakMinutes = clamped
        case .longBreak:
            UserPreferences.shared.pomodoroLongBreakMinutes = clamped
        }

        if phase == targetPhase {
            pause()
            totalSeconds = clamped * 60
            remainingSeconds = clamped * 60
            notifyMenuBar()
        }
    }

    func focusOnTask(id: String, title: String) {
        linkedTaskId = id
        linkedTaskTitle = title
        selectPhase(.focus)
        start()
    }

    func clearLinkedTask() {
        linkedTaskId = nil
        linkedTaskTitle = nil
    }

    func skipPhase() {
        completeCurrentPhase(playSound: false, countFocus: false)
    }

    // MARK: - Tick & Completion

    private func tick() {
        guard isRunning else { return }
        if remainingSeconds > 1 {
            remainingSeconds -= 1
            notifyMenuBar()
        } else {
            remainingSeconds = 0
            completeCurrentPhase(playSound: true, countFocus: true)
        }
    }

    private func completeCurrentPhase(playSound: Bool, countFocus: Bool) {
        pause()

        if playSound && UserPreferences.shared.pomodoroSoundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }

        if phase == .focus {
            if countFocus {
                incrementCompletedToday()
                focusStreakInCycle += 1
                showBanner("专注完成！休息一下吧")
            }
            let nextPhase: PomodoroPhase = (focusStreakInCycle >= 4) ? .longBreak : .shortBreak
            if nextPhase == .longBreak {
                focusStreakInCycle = 0
            }
            phase = nextPhase
        } else {
            if countFocus {
                showBanner("休息结束，准备开始下一轮专注")
            }
            phase = .focus
        }

        let nextSeconds = phase.defaultDurationMinutes * 60
        totalSeconds = nextSeconds
        remainingSeconds = nextSeconds
        notifyMenuBar()
    }

    private func showBanner(_ text: String) {
        lastFinishedBanner = text
        bannerDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.lastFinishedBanner = nil
            }
        }
        bannerDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func notifyMenuBar() {
        AppDelegate.shared?.updatePomodoroMenuBarText(menuBarText)
    }

    private static func loadCompletedToday() -> Int {
        let todayKey = PinnedTaskSchedule.dateKey(for: Date())
        if UserPreferences.shared.pomodoroCompletedTodayDate == todayKey {
            return UserPreferences.shared.pomodoroCompletedTodayCount
        }
        return 0
    }

    private func incrementCompletedToday() {
        let todayKey = PinnedTaskSchedule.dateKey(for: Date())
        if UserPreferences.shared.pomodoroCompletedTodayDate != todayKey {
            UserPreferences.shared.pomodoroCompletedTodayDate = todayKey
            completedFocusToday = 1
        } else {
            completedFocusToday += 1
        }
        UserPreferences.shared.pomodoroCompletedTodayCount = completedFocusToday
    }
}
