import SwiftUI
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openRemindersMenuBar = Self("OpenRemindersMenuBar", initial: .init(.r, modifiers: [.control, .option]))
    static let openClipboardHistory = Self("OpenClipboardHistory", initial: .init(.v, modifiers: [.control, .option]))
    static let openQuickNotes = Self("OpenQuickNotes", initial: .init(.n, modifiers: [.control, .option]))
    static let toggleCornerMiniWindow = Self("ToggleCornerMiniWindow", initial: .init(.m, modifiers: [.control, .option]))

    static let allPikoActions: [(name: KeyboardShortcuts.Name, title: String)] = [
        (.openRemindersMenuBar, "规划板"),
        (.openClipboardHistory, "剪贴板"),
        (.openQuickNotes, "随笔"),
        (.toggleCornerMiniWindow, "大窗 / 小窗切换")
    ]
}

private enum ShortcutsKeys {
    static let isOpenRemindersMenuBarEnabled = "isOpenRemindersMenuBarEnabled"
    static let isOpenClipboardHistoryEnabled = "isOpenClipboardHistoryEnabled"
    static let isOpenQuickNotesEnabled = "isOpenQuickNotesEnabled"
    static let isToggleCornerMiniWindowEnabled = "isToggleCornerMiniWindowEnabled"
}

@MainActor
class KeyboardShortcutService: ObservableObject {
    static let shared = KeyboardShortcutService()

    private init() {}

    private static let defaults = UserDefaults.standard

    @Published var isOpenRemindersMenuBarEnabled: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: ShortcutsKeys.isOpenRemindersMenuBarEnabled)
    }() {
        didSet {
            Self.defaults.set(isOpenRemindersMenuBarEnabled, forKey: ShortcutsKeys.isOpenRemindersMenuBarEnabled)
            setEnabled(isOpenRemindersMenuBarEnabled, for: .openRemindersMenuBar)
        }
    }

    @Published var isOpenClipboardHistoryEnabled: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: ShortcutsKeys.isOpenClipboardHistoryEnabled)
    }() {
        didSet {
            Self.defaults.set(isOpenClipboardHistoryEnabled, forKey: ShortcutsKeys.isOpenClipboardHistoryEnabled)
            setEnabled(isOpenClipboardHistoryEnabled, for: .openClipboardHistory)
        }
    }

    @Published var isOpenQuickNotesEnabled: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: ShortcutsKeys.isOpenQuickNotesEnabled)
    }() {
        didSet {
            Self.defaults.set(isOpenQuickNotesEnabled, forKey: ShortcutsKeys.isOpenQuickNotesEnabled)
            setEnabled(isOpenQuickNotesEnabled, for: .openQuickNotes)
        }
    }

    @Published var isToggleCornerMiniWindowEnabled: Bool = {
        defaults.boolWithDefaultValueTrue(forKey: ShortcutsKeys.isToggleCornerMiniWindowEnabled)
    }() {
        didSet {
            Self.defaults.set(isToggleCornerMiniWindowEnabled, forKey: ShortcutsKeys.isToggleCornerMiniWindowEnabled)
            setEnabled(isToggleCornerMiniWindowEnabled, for: .toggleCornerMiniWindow)
        }
    }

    func action(for shortcutName: KeyboardShortcuts.Name, action: @escaping () -> Void) {
        KeyboardShortcuts.removeHandler(for: shortcutName)
        KeyboardShortcuts.onKeyDown(for: shortcutName) {
            action()
        }
        setEnabled(isEnabled(shortcutName), for: shortcutName)
    }

    func reset(_ shortcutName: KeyboardShortcuts.Name) {
        KeyboardShortcuts.reset(shortcutName)
        setEnabled(isEnabled(shortcutName), for: shortcutName)
    }

    func conflictingTitle(
        for shortcut: KeyboardShortcuts.Shortcut,
        excluding currentName: KeyboardShortcuts.Name
    ) -> String? {
        for entry in KeyboardShortcuts.Name.allPikoActions where entry.name != currentName {
            if KeyboardShortcuts.getShortcut(for: entry.name) == shortcut {
                return entry.title
            }
        }
        return nil
    }

    private func isEnabled(_ shortcutName: KeyboardShortcuts.Name) -> Bool {
        switch shortcutName {
        case .openRemindersMenuBar:
            return isOpenRemindersMenuBarEnabled
        case .openClipboardHistory:
            return isOpenClipboardHistoryEnabled
        case .openQuickNotes:
            return isOpenQuickNotesEnabled
        case .toggleCornerMiniWindow:
            return isToggleCornerMiniWindowEnabled
        default:
            return false
        }
    }

    private func setEnabled(_ isEnabled: Bool, for shortcutName: KeyboardShortcuts.Name) {
        if isEnabled {
            KeyboardShortcuts.enable(shortcutName)
        } else {
            KeyboardShortcuts.disable(shortcutName)
        }
    }
}
