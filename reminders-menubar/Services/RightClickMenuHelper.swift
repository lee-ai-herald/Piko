import Cocoa

@MainActor
final class RightClickMenuHelper: NSObject {
    static let shared = RightClickMenuHelper()

    private override init() {
        super.init()
    }

    func buildRightClickMenu() -> NSMenu {
        let menu = NSMenu()

        let isVisible = PinnedRemindersStore.shared.isPanelVisible
        let isMini = PinnedPanelController.shared.isCornerMiniMode

        menu.addItem(makeMenuItem(
            title: isVisible ? "隐藏 \(AppConstants.appName) 窗口" : "显示 \(AppConstants.appName) 窗口",
            action: #selector(toggleBoard),
            systemSymbolName: isVisible ? "eye.slash" : "rectangle.split.3x1"
        ))

        menu.addItem(makeMenuItem(
            title: isMini && isVisible ? "展开为完整窗口" : "切换右上角迷你小窗",
            action: #selector(toggleMiniWindow),
            systemSymbolName: isMini && isVisible ? "pip.exit" : "pip.enter"
        ))

        menu.addItem(.separator())

        let pomodoro = PomodoroService.shared
        menu.addItem(makeMenuItem(
            title: pomodoro.isRunning ? "暂停番茄钟 (\(pomodoro.formattedTime))" : "打开番茄钟",
            action: #selector(openPomodoro),
            systemSymbolName: pomodoro.isRunning ? "pause.circle" : "timer"
        ))

        menu.addItem(makeMenuItem(
            title: "打开剪贴板",
            action: #selector(openClipboard),
            systemSymbolName: "doc.on.clipboard"
        ))

        menu.addItem(makeMenuItem(
            title: "打开随笔记事",
            action: #selector(openQuickNotes),
            systemSymbolName: "note.text"
        ))

        menu.addItem(.separator())

        menu.addItem(makeMenuItem(
            title: "刷新提醒事项数据",
            action: #selector(reloadData),
            systemSymbolName: "arrow.clockwise"
        ))

        menu.addItem(makeMenuItem(
            title: "偏好设置…",
            action: #selector(openSettingsAction),
            systemSymbolName: "gearshape"
        ))

        menu.addItem(makeMenuItem(
            title: "退出 \(AppConstants.appName)",
            action: #selector(quitApp),
            systemSymbolName: "power"
        ))

        return menu
    }

    private func makeMenuItem(
        title: String,
        action: Selector,
        systemSymbolName: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let systemSymbolName {
            item.image = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)
        }
        return item
    }

    @objc private func toggleBoard() {
        PinnedRemindersStore.shared.togglePanelVisibility()
    }

    @objc private func toggleMiniWindow() {
        PinnedPanelController.shared.toggleCornerMiniMode()
    }

    @objc private func openPomodoro() {
        if PomodoroService.shared.isRunning {
            PomodoroService.shared.pause()
        } else {
            PinnedRemindersStore.shared.showPanel(tab: .pomodoro)
        }
    }

    @objc private func openClipboard() {
        PinnedRemindersStore.shared.showPanel(tab: .clipboard)
    }

    @objc private func openQuickNotes() {
        PinnedRemindersStore.shared.showPanel(tab: .notes)
    }

    @objc private func reloadData() {
        NotificationCenter.default.post(name: .remindersDataShouldUpdate, object: nil)
    }

    @objc private func openSettingsAction() {
        NSApp.openAppSettings()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
