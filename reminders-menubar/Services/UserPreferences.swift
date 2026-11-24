import SwiftUI

private enum PreferencesKeys {
    static let reminderMenuBarIcon = "reminderMenuBarIcon"
    static let excludedReminderCalendarIdentifiers = "excludedReminderCalendarIdentifiers"
    static let calendarIdentifierForSaving = "calendarIdentifierForSaving"
    static let rmbColorScheme = "rmbColorScheme"
    static let preferTransparentBackground = "backgroundIsTransparent"
    static let menuBarCounterType = "menuBarCounterType"
    static let hideMenuBarIconWhenContentIsShown = "hideMenuBarIconWhenCounterIsShown"
    static let preferredLanguage = "preferredLanguage"
    static let showRemindersWithDueDateOnTop = "showRemindersWithDueDateOnTop"
    static let sortRemindersByFlagAndPriority = "sortRemindersByPriority"
    static let reminderSortingOrder = "reminderSortingOrder"
    static let timeFormatIs24Hour = "timeFormatIs24Hour"
    static let firstWeekday = "firstWeekday"
    static let showNotesInReminderItem = "showNotesInReminderItem"
    static let pinnedSchedules = "pinnedSchedules"
    static let pinnedPanelFrame = "pinnedPanelFrame"
    static let isPinnedPanelVisible = "isPinnedPanelVisible"
    static let isPinnedPanelCollapsed = "isPinnedPanelCollapsed"
    static let isBoardAlwaysOnTop = "isBoardAlwaysOnTop"
    static let completedTimeRange = "completedTimeRange"
    static let clipboardMaxItems = "clipboardMaxItems"
    static let defaultNoteColorTag = "defaultNoteColorTag"
    static let isNoteMarkdownEnabled = "isNoteMarkdownEnabled"
    static let pomodoroFocusMinutes = "pomodoroFocusMinutes"
    static let pomodoroShortBreakMinutes = "pomodoroShortBreakMinutes"
    static let pomodoroLongBreakMinutes = "pomodoroLongBreakMinutes"
    static let pomodoroSoundEnabled = "pomodoroSoundEnabled"
    static let pomodoroShowInMenuBar = "pomodoroShowInMenuBar"
    static let pomodoroCompletedTodayDate = "pomodoroCompletedTodayDate"
    static let pomodoroCompletedTodayCount = "pomodoroCompletedTodayCount"
    static let automaticallyCheckForUpdates = "automaticallyCheckForUpdates"
    static let lastUpdateCheckTimestamp = "lastUpdateCheckTimestamp"
}

class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    private var accessibilityObserver: NSObjectProtocol?
    private static let defaults = UserDefaults.standard

    private init() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
    }

    deinit {
        if let observer = accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    @Published var reminderMenuBarIcon: RmbIcon = {
        guard let icon = defaults.string(forKey: PreferencesKeys.reminderMenuBarIcon) else {
            return RmbIcon.defaultIcon
        }
        return RmbIcon(rawValue: icon) ?? RmbIcon.defaultIcon
    }() {
        didSet {
            Self.defaults.set(reminderMenuBarIcon.rawValue, forKey: PreferencesKeys.reminderMenuBarIcon)
        }
    }

    /// Apple Reminders list identifiers explicitly excluded from Piko sync.
    /// Empty by default so all lists (including newly created ones) sync automatically.
    @Published var excludedReminderCalendarIdentifiers: Set<String> = {
        Set(defaults.stringArray(forKey: PreferencesKeys.excludedReminderCalendarIdentifiers) ?? [])
    }() {
        didSet {
            Self.defaults.set(
                Array(excludedReminderCalendarIdentifiers).sorted(),
                forKey: PreferencesKeys.excludedReminderCalendarIdentifiers
            )
        }
    }

    @Published var preferredCalendarIdentifierForSaving: String? = {
        defaults.string(forKey: PreferencesKeys.calendarIdentifierForSaving)
    }() {
        didSet {
            Self.defaults.set(preferredCalendarIdentifierForSaving, forKey: PreferencesKeys.calendarIdentifierForSaving)
        }
    }

    func isCalendarSynced(_ calendarIdentifier: String) -> Bool {
        !excludedReminderCalendarIdentifiers.contains(calendarIdentifier)
    }

    func setCalendarSynced(_ isSynced: Bool, for calendarIdentifier: String) {
        if isSynced {
            excludedReminderCalendarIdentifiers.remove(calendarIdentifier)
        } else {
            excludedReminderCalendarIdentifiers.insert(calendarIdentifier)
        }
    }

    func enableAllCalendars() {
        excludedReminderCalendarIdentifiers.removeAll()
    }

    @Published var showRemindersWithDueDateOnTop: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.showRemindersWithDueDateOnTop)
    }() {
        didSet {
            Self.defaults.set(showRemindersWithDueDateOnTop, forKey: PreferencesKeys.showRemindersWithDueDateOnTop)
        }
    }

    @Published var sortRemindersByFlagAndPriority: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.sortRemindersByFlagAndPriority)
    }() {
        didSet {
            Self.defaults.set(sortRemindersByFlagAndPriority, forKey: PreferencesKeys.sortRemindersByFlagAndPriority)
        }
    }

    @Published var showNotesInReminderItem: Bool = {
        defaults.bool(forKey: PreferencesKeys.showNotesInReminderItem)
    }() {
        didSet {
            Self.defaults.set(showNotesInReminderItem, forKey: PreferencesKeys.showNotesInReminderItem)
        }
    }

    @Published var reminderSortingOrder: RmbSortingOrder = {
        guard let data = defaults.data(forKey: PreferencesKeys.reminderSortingOrder),
              let sorting = try? JSONDecoder().decode(RmbSortingOrder.self, from: data) else {
            return .newestFirst
        }
        return sorting
    }() {
        didSet {
            let data = try? JSONEncoder().encode(reminderSortingOrder)
            Self.defaults.set(data, forKey: PreferencesKeys.reminderSortingOrder)
        }
    }

    @Published var rmbColorScheme: RmbColorScheme = {
        guard let str = defaults.string(forKey: PreferencesKeys.rmbColorScheme) else {
            return .system
        }
        return RmbColorScheme(rawValue: str) ?? .system
    }() {
        didSet {
            Self.defaults.set(rmbColorScheme.rawValue, forKey: PreferencesKeys.rmbColorScheme)
        }
    }

    @Published var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    @Published var preferTransparentBackground: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.preferTransparentBackground)
    }() {
        didSet {
            Self.defaults.set(preferTransparentBackground, forKey: PreferencesKeys.preferTransparentBackground)
        }
    }

    var isTransparencyEnabled: Bool {
        preferTransparentBackground && !reduceTransparency
    }

    @Published var menuBarCounterType: RmbMenuBarCounterType = {
        guard let data = defaults.data(forKey: PreferencesKeys.menuBarCounterType),
              let counterType = try? JSONDecoder().decode(RmbMenuBarCounterType.self, from: data) else {
            return .today
        }
        return counterType
    }() {
        didSet {
            let data = try? JSONEncoder().encode(menuBarCounterType)
            Self.defaults.set(data, forKey: PreferencesKeys.menuBarCounterType)
        }
    }

    @Published var hideMenuBarIconWhenContentIsShown: Bool = {
        defaults.bool(forKey: PreferencesKeys.hideMenuBarIconWhenContentIsShown)
    }() {
        didSet {
            Self.defaults.set(hideMenuBarIconWhenContentIsShown, forKey: PreferencesKeys.hideMenuBarIconWhenContentIsShown)
            Task { @MainActor in
                AppDelegate.shared?.refreshMenuBarAppearance()
            }
        }
    }

    @Published var preferredLanguage: String? = {
        defaults.string(forKey: PreferencesKeys.preferredLanguage)
    }() {
        didSet {
            Self.defaults.set(preferredLanguage, forKey: PreferencesKeys.preferredLanguage)
        }
    }

    @Published var timeFormatIs24Hour: Bool = {
        guard defaults.object(forKey: PreferencesKeys.timeFormatIs24Hour) != nil else {
            return true
        }
        return defaults.bool(forKey: PreferencesKeys.timeFormatIs24Hour)
    }() {
        didSet {
            Self.defaults.set(timeFormatIs24Hour, forKey: PreferencesKeys.timeFormatIs24Hour)
        }
    }

    @Published var firstWeekday: Int? = {
        let weekday = defaults.integer(forKey: PreferencesKeys.firstWeekday)
        return (1...7).contains(weekday) ? weekday : nil
    }() {
        didSet {
            Self.defaults.set(firstWeekday, forKey: PreferencesKeys.firstWeekday)
        }
    }

    @Published var clipboardMaxItems: Int = {
        let val = defaults.integer(forKey: PreferencesKeys.clipboardMaxItems)
        return val > 0 ? val : 80
    }() {
        didSet {
            Self.defaults.set(clipboardMaxItems, forKey: PreferencesKeys.clipboardMaxItems)
        }
    }

    @Published var defaultNoteColorTag: NoteColorTag = {
        guard let raw = defaults.string(forKey: PreferencesKeys.defaultNoteColorTag),
              let tag = NoteColorTag(rawValue: raw) else {
            return .yellow
        }
        return tag
    }() {
        didSet {
            Self.defaults.set(defaultNoteColorTag.rawValue, forKey: PreferencesKeys.defaultNoteColorTag)
        }
    }

    @Published var isNoteMarkdownEnabled: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.isNoteMarkdownEnabled)
    }() {
        didSet {
            Self.defaults.set(isNoteMarkdownEnabled, forKey: PreferencesKeys.isNoteMarkdownEnabled)
        }
    }

    // MARK: - Pomodoro Preferences

    @Published var pomodoroFocusMinutes: Int = {
        let val = defaults.integer(forKey: PreferencesKeys.pomodoroFocusMinutes)
        return val > 0 ? val : 25
    }() {
        didSet {
            Self.defaults.set(pomodoroFocusMinutes, forKey: PreferencesKeys.pomodoroFocusMinutes)
        }
    }

    @Published var pomodoroShortBreakMinutes: Int = {
        let val = defaults.integer(forKey: PreferencesKeys.pomodoroShortBreakMinutes)
        return val > 0 ? val : 5
    }() {
        didSet {
            Self.defaults.set(pomodoroShortBreakMinutes, forKey: PreferencesKeys.pomodoroShortBreakMinutes)
        }
    }

    @Published var pomodoroLongBreakMinutes: Int = {
        let val = defaults.integer(forKey: PreferencesKeys.pomodoroLongBreakMinutes)
        return val > 0 ? val : 15
    }() {
        didSet {
            Self.defaults.set(pomodoroLongBreakMinutes, forKey: PreferencesKeys.pomodoroLongBreakMinutes)
        }
    }

    @Published var pomodoroSoundEnabled: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.pomodoroSoundEnabled)
    }() {
        didSet {
            Self.defaults.set(pomodoroSoundEnabled, forKey: PreferencesKeys.pomodoroSoundEnabled)
        }
    }

    @Published var pomodoroShowInMenuBar: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.pomodoroShowInMenuBar)
    }() {
        didSet {
            Self.defaults.set(pomodoroShowInMenuBar, forKey: PreferencesKeys.pomodoroShowInMenuBar)
        }
    }

    var pomodoroCompletedTodayDate: String? {
        get { Self.defaults.string(forKey: PreferencesKeys.pomodoroCompletedTodayDate) }
        set { Self.defaults.set(newValue, forKey: PreferencesKeys.pomodoroCompletedTodayDate) }
    }

    var pomodoroCompletedTodayCount: Int {
        get { Self.defaults.integer(forKey: PreferencesKeys.pomodoroCompletedTodayCount) }
        set { Self.defaults.set(newValue, forKey: PreferencesKeys.pomodoroCompletedTodayCount) }
    }

    // MARK: - Pinned Board Persistence

    var pinnedSchedules: [String: PinnedTaskSchedule] {
        get {
            guard let data = Self.defaults.data(forKey: PreferencesKeys.pinnedSchedules),
                  let dict = try? JSONDecoder().decode([String: PinnedTaskSchedule].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            Self.defaults.set(data, forKey: PreferencesKeys.pinnedSchedules)
        }
    }

    var pinnedPanelFrame: NSRect? {
        get {
            guard let data = Self.defaults.data(forKey: PreferencesKeys.pinnedPanelFrame),
                  let rect = try? JSONDecoder().decode(NSRect.self, from: data) else {
                return nil
            }
            return rect
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                Self.defaults.set(data, forKey: PreferencesKeys.pinnedPanelFrame)
            } else {
                Self.defaults.removeObject(forKey: PreferencesKeys.pinnedPanelFrame)
            }
        }
    }

    var isPinnedPanelVisible: Bool {
        get { Self.defaults.bool(forKey: PreferencesKeys.isPinnedPanelVisible) }
        set { Self.defaults.set(newValue, forKey: PreferencesKeys.isPinnedPanelVisible) }
    }

    var isPinnedPanelCollapsed: Bool {
        get { Self.defaults.bool(forKey: PreferencesKeys.isPinnedPanelCollapsed) }
        set { Self.defaults.set(newValue, forKey: PreferencesKeys.isPinnedPanelCollapsed) }
    }

    @Published var isBoardAlwaysOnTop: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.isBoardAlwaysOnTop)
    }() {
        didSet {
            Self.defaults.set(isBoardAlwaysOnTop, forKey: PreferencesKeys.isBoardAlwaysOnTop)
            Task { @MainActor in
                PinnedPanelController.shared.syncWindowLevelFromPreferences()
            }
        }
    }

    @Published var completedTimeRange: CompletedTimeRange = {
        guard let raw = defaults.string(forKey: PreferencesKeys.completedTimeRange),
              let range = CompletedTimeRange(rawValue: raw) else {
            return .today
        }
        return range
    }() {
        didSet {
            Self.defaults.set(completedTimeRange.rawValue, forKey: PreferencesKeys.completedTimeRange)
        }
    }

    // MARK: - App Updates

    @Published var automaticallyCheckForUpdates: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: PreferencesKeys.automaticallyCheckForUpdates)
    }() {
        didSet {
            Self.defaults.set(automaticallyCheckForUpdates, forKey: PreferencesKeys.automaticallyCheckForUpdates)
        }
    }

    var lastUpdateCheckTimestamp: TimeInterval {
        get { Self.defaults.double(forKey: PreferencesKeys.lastUpdateCheckTimestamp) }
        set { Self.defaults.set(newValue, forKey: PreferencesKeys.lastUpdateCheckTimestamp) }
    }
}
