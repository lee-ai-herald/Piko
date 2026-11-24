import Cocoa
import Combine
import SwiftUI

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

/// Isolated 1Hz countdown state so ticking only redraws timer-display leaf views instead of the entire workspace.
@MainActor
final class PomodoroTicker: ObservableObject {
    @Published fileprivate(set) var remainingSeconds: Int
    @Published fileprivate(set) var totalSeconds: Int

    init(totalSeconds: Int) {
        self.totalSeconds = totalSeconds
        self.remainingSeconds = totalSeconds
    }

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return max(0, min(1, 1.0 - (Double(remainingSeconds) / Double(totalSeconds))))
    }

    var formattedTime: String {
        let clamped = max(0, remainingSeconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var estimatedFinishTimeText: String {
        let finishDate = Date().addingTimeInterval(TimeInterval(max(0, remainingSeconds)))
        return "预计 \(RmbFormatters.hourMinute.string(from: finishDate)) 结束"
    }
}

@MainActor
final class PomodoroService: ObservableObject {
    static let shared = PomodoroService()

    /// Fine-grained 1Hz countdown publisher — observe this only in countdown text / progress ring views.
    let ticker: PomodoroTicker

    @Published var phase: PomodoroPhase = .focus
    @Published private(set) var isRunning = false
    @Published var linkedTaskId: String?
    @Published var linkedTaskTitle: String?
    @Published private(set) var completedFocusToday: Int
    @Published var lastFinishedBanner: String?

    private var timer: Timer?
    private var phaseEndDate: Date?
    private var focusStreakInCycle: Int
    private var bannerDismissWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        let initialSeconds = UserPreferences.shared.pomodoroFocusMinutes * 60
        self.ticker = PomodoroTicker(totalSeconds: initialSeconds)
        let todayCount = Self.loadCompletedToday()
        self.completedFocusToday = todayCount
        self.focusStreakInCycle = todayCount % 4

        Publishers.MergeMany(
            UserPreferences.shared.$pomodoroFocusMinutes.dropFirst().map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$pomodoroShortBreakMinutes.dropFirst().map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$pomodoroLongBreakMinutes.dropFirst().map { _ in }.eraseToAnyPublisher(),
            UserPreferences.shared.$pomodoroShowInMenuBar.dropFirst().map { _ in }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            if !self.isRunning && self.ticker.remainingSeconds == self.ticker.totalSeconds {
                self.resetCurrentPhase()
            }
            self.notifyMenuBar()
        }
        .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDailyCounterIfNeeded()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshDailyCounterIfNeeded()
                self?.syncWallClockTick()
            }
            .store(in: &cancellables)
    }

    var remainingSeconds: Int { ticker.remainingSeconds }
    var totalSeconds: Int { ticker.totalSeconds }
    var progress: Double { ticker.progress }
    var formattedTime: String { ticker.formattedTime }

    var menuBarText: String? {
        guard UserPreferences.shared.pomodoroShowInMenuBar else { return nil }
        guard isRunning || ticker.remainingSeconds < ticker.totalSeconds else { return nil }
        let prefix = phase == .focus ? "🍅" : "☕"
        return "\(prefix) \(ticker.formattedTime)"
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
        refreshDailyCounterIfNeeded()
        if ticker.remainingSeconds <= 0 {
            resetCurrentPhase()
        }
        phaseEndDate = Date().addingTimeInterval(TimeInterval(ticker.remainingSeconds))
        isRunning = true
        lastFinishedBanner = nil
        notifyMenuBar()

        timer?.invalidate()
        let nextTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncWallClockTick()
            }
        }
        nextTimer.tolerance = 0.1
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    func pause() {
        if let endDate = phaseEndDate, isRunning {
            ticker.remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        }
        phaseEndDate = nil
        isRunning = false
        timer?.invalidate()
        timer = nil
        notifyMenuBar()
    }

    func resetCurrentPhase() {
        pause()
        let seconds = phase.defaultDurationMinutes * 60
        ticker.totalSeconds = seconds
        ticker.remainingSeconds = seconds
        notifyMenuBar()
    }

    func selectPhase(_ newPhase: PomodoroPhase) {
        pause()
        phase = newPhase
        let seconds = newPhase.defaultDurationMinutes * 60
        ticker.totalSeconds = seconds
        ticker.remainingSeconds = seconds
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
            ticker.totalSeconds = clamped * 60
            ticker.remainingSeconds = clamped * 60
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

    // MARK: - Wall-Clock Tick & Completion

    private func syncWallClockTick() {
        guard isRunning, let endDate = phaseEndDate else { return }
        let remaining = Int(ceil(endDate.timeIntervalSinceNow))
        if remaining > 0 {
            if ticker.remainingSeconds != remaining {
                ticker.remainingSeconds = remaining
                notifyMenuBar()
            }
        } else {
            ticker.remainingSeconds = 0
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
        ticker.totalSeconds = nextSeconds
        ticker.remainingSeconds = nextSeconds
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

    private func refreshDailyCounterIfNeeded() {
        let todayKey = PinnedTaskSchedule.dateKey(for: Date())
        if UserPreferences.shared.pomodoroCompletedTodayDate != todayKey {
            completedFocusToday = 0
            focusStreakInCycle = 0
        }
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
