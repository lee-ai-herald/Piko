import Cocoa
import SwiftUI

@main
struct PikoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        if #available(macOS 14.0, *) {
            Window(String(""), id: "SettingsOpener") {
                SettingsOpenerView()
            }
            .windowResizability(.contentSize)
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 0, height: 0)
        }

        Settings {
            SettingsView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    // swiftlint:disable:next implicitly_unwrapped_optional
    static private(set) var shared: AppDelegate!

    private var sharedAuthorizationErrorMessage: String?
    private var isPresentingAuthorizationAlert = false
    private var currentMenuBarCount = 0
    private var currentPomodoroText: String?

    lazy var statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        AppDelegate.shared = self

        _ = ClipboardHistoryStore.shared
        _ = QuickNotesStore.shared

        configureMenuBarButton()
        configureKeyboardShortcuts()
        AppUpdateService.shared.startAutomaticCheckSchedule()

        if RemindersService.shared.isAuthorized {
            PinnedRemindersStore.shared.launchAndRestore()
        } else {
            requestAuthorization()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardHistoryStore.shared.stopMonitoring()
        ClipboardHistoryStore.shared.flushPendingWrites()
        QuickNotesStore.shared.flushPendingSave()
        PinnedPanelController.shared.flushPendingFrameSave()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func updateMenuBarCount(to count: Int) {
        currentMenuBarCount = count
        refreshMenuBarAppearance()
    }

    func updatePomodoroMenuBarText(_ text: String?) {
        currentPomodoroText = text
        refreshMenuBarAppearance()
    }

    func refreshMenuBarAppearance() {
        let countText = currentMenuBarCount > 0 ? String(currentMenuBarCount) : nil
        let pomodoroText = currentPomodoroText

        switch (countText, pomodoroText) {
        case let (count?, timer?):
            statusBarItem.button?.title = "\(count) · \(timer)"
        case let (nil, timer?):
            statusBarItem.button?.title = timer
        case let (count?, nil):
            statusBarItem.button?.title = count
        case (nil, nil):
            statusBarItem.button?.title = ""
        }
        loadMenuBarIcon()
    }

    func loadMenuBarIcon() {
        let hasText = currentMenuBarCount > 0 || currentPomodoroText != nil
        let shouldHideIcon = UserPreferences.shared.hideMenuBarIconWhenContentIsShown && hasText
        statusBarItem.button?.image = shouldHideIcon ? nil : UserPreferences.shared.reminderMenuBarIcon.image
    }

    private func configureMenuBarButton() {
        loadMenuBarIcon()
        statusBarItem.button?.toolTip = AppConstants.appName
        statusBarItem.button?.imagePosition = .imageLeading
        statusBarItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusBarItem.button?.action = #selector(handleStatusBarButtonAction)
    }

    private func configureKeyboardShortcuts() {
        KeyboardShortcutService.shared.action(for: .openRemindersMenuBar) { [weak self] in
            self?.openOrToggleBoard(tab: .board)
        }
        KeyboardShortcutService.shared.action(for: .openClipboardHistory) { [weak self] in
            self?.openOrToggleBoard(tab: .clipboard)
        }
        KeyboardShortcutService.shared.action(for: .openQuickNotes) { [weak self] in
            self?.openOrToggleBoard(tab: .notes)
        }
        KeyboardShortcutService.shared.action(for: .toggleCornerMiniWindow) {
            PinnedPanelController.shared.toggleCornerMiniMode()
        }
    }

    @objc private func handleStatusBarButtonAction() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            openOrToggleBoard(tab: nil)
        }
    }

    private func showRightClickMenu() {
        guard let button = statusBarItem.button else { return }
        let menu = RightClickMenuHelper.shared.buildRightClickMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    private func openOrToggleBoard(tab: BoardTab?) {
        let requiresRemindersAuth = (tab != .clipboard && tab != .notes)
        if requiresRemindersAuth && !RemindersService.shared.isAuthorized {
            requestAuthorization()
            return
        }
        PinnedRemindersStore.shared.togglePanelVisibility(tab: tab)
    }
}

// MARK: - Authorization

extension AppDelegate: NSAlertDelegate {
    private func requestAuthorization() {
        RemindersService.shared.requestAccess { [weak self] granted, errorMessage in
            if granted {
                Task { @MainActor in
                    PinnedRemindersStore.shared.launchAndRestore()
                }
                return
            }

            print("Access to reminders not granted:", errorMessage ?? "no error description")
            DispatchQueue.main.async {
                self?.sharedAuthorizationErrorMessage = errorMessage
                self?.presentNoAuthorizationAlert()
            }
        }
    }

    private func presentNoAuthorizationAlert() {
        guard !isPresentingAuthorizationAlert else { return }
        isPresentingAuthorizationAlert = true
        defer { isPresentingAuthorizationAlert = false }

        let alert = NSAlert()
        alert.messageText = rmbLocalized(.appNoRemindersAccessAlertMessage, arguments: AppConstants.appName)
        let reasonDescription = rmbLocalized(
            .appNoRemindersAccessAlertReasonDescription,
            arguments: AppConstants.appName
        )
        let actionDescription = rmbLocalized(
            .appNoRemindersAccessAlertActionDescription,
            arguments: AppConstants.appName
        )
        alert.informativeText = "\(reasonDescription)\n\(actionDescription)"
        if sharedAuthorizationErrorMessage != nil {
            alert.delegate = self
            alert.showsHelp = true
        }

        alert.addButton(withTitle: rmbLocalized(.okButton))
        alert.addButton(withTitle: rmbLocalized(.openSystemPreferencesButton))
        alert.addButton(withTitle: rmbLocalized(.appQuitButton)).hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        let modalResponse = alert.runModal()
        switch modalResponse {
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                NSWorkspace.shared.open(url)
            }
        case .alertThirdButtonReturn:
            NSApp.terminate(self)
        default:
            sharedAuthorizationErrorMessage = nil
        }
    }

    internal func alertShowHelp(_ alert: NSAlert) -> Bool {
        let helpAlert = NSAlert()
        let errorDescription = sharedAuthorizationErrorMessage ?? "no error description"
        helpAlert.icon = NSImage(systemSymbolName: "calendar.badge.exclamationmark", accessibilityDescription: nil)
        helpAlert.messageText = rmbLocalized(.appNoRemindersAccessAlertMessage, arguments: AppConstants.appName)
        helpAlert.informativeText = "Authorization error: \(errorDescription)"
        helpAlert.runModal()
        return true
    }
}
