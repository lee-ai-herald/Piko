import Cocoa

extension Notification.Name {
    static let openSettingsRequest = Notification.Name("openSettingsRequest")
    static let remindersDataShouldUpdate = Notification.Name("remindersDataShouldUpdate")
}

extension NSApplication {
    @MainActor
    func openAppSettings(tab: SettingsTab = .general) {
        SettingsCoordinator.shared.selectedTab = tab

        if #available(macOS 14.0, *) {
            SettingsOpenerBridge.shared.requestOpen()
        } else {
            sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            activate(ignoringOtherApps: true)
        }
    }
}
