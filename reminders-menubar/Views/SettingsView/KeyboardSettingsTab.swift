import SwiftUI
import KeyboardShortcuts

struct KeyboardSettingsTab: View {
    @ObservedObject var keyboardShortcutService = KeyboardShortcutService.shared
    @State private var conflictMessage: String?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(title: "快捷键")

                SettingsCard(title: "全局呼出") {
                    shortcutRow(
                        title: "显示 / 隐藏窗口",
                        name: .openRemindersMenuBar,
                        isEnabled: $keyboardShortcutService.isOpenRemindersMenuBarEnabled
                    )

                    shortcutRow(
                        title: "剪贴板",
                        name: .openClipboardHistory,
                        isEnabled: $keyboardShortcutService.isOpenClipboardHistoryEnabled
                    )

                    shortcutRow(
                        title: "随笔",
                        name: .openQuickNotes,
                        isEnabled: $keyboardShortcutService.isOpenQuickNotesEnabled
                    )

                    shortcutRow(
                        title: "右上角小窗",
                        name: .toggleCornerMiniWindow,
                        isEnabled: $keyboardShortcutService.isToggleCornerMiniWindowEnabled,
                        showDivider: false
                    )
                }

                if let conflictMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                        Text(conflictMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.orange.opacity(0.10))
                    )
                }

                Text("默认组合键为 ⌃⌥R / ⌃⌥V / ⌃⌥N / ⌃⌥M（避免与系统及常用软件冲突），点击录制框可自定义。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            .padding(20)
        }
        .onAppear {
            refreshConflictState()
        }
    }

    private func shortcutRow(
        title: String,
        name: KeyboardShortcuts.Name,
        isEnabled: Binding<Bool>,
        showDivider: Bool = true
    ) -> some View {
        SettingsRow(title, showDivider: showDivider) {
            HStack(spacing: 8) {
                KeyboardShortcuts.Recorder(for: name) { newShortcut in
                    if let newShortcut,
                       let conflicting = KeyboardShortcutService.shared.conflictingTitle(
                           for: newShortcut,
                           excluding: name
                       ) {
                        conflictMessage = "快捷键冲突：「\(title)」与「\(conflicting)」使用了相同的组合键，建议调整其一。"
                    } else {
                        refreshConflictState()
                    }
                }
                .disabled(!isEnabled.wrappedValue)

                Button("默认") {
                    KeyboardShortcutService.shared.reset(name)
                    refreshConflictState()
                }
                .controlSize(.small)
                .disabled(!isEnabled.wrappedValue)

                Toggle("", isOn: isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    private func refreshConflictState() {
        var seen: [KeyboardShortcuts.Shortcut: String] = [:]
        for entry in KeyboardShortcuts.Name.allPikoActions {
            guard let shortcut = KeyboardShortcuts.getShortcut(for: entry.name) else { continue }
            if let existingTitle = seen[shortcut] {
                conflictMessage = "快捷键冲突：「\(existingTitle)」与「\(entry.title)」使用了相同的组合键，建议调整其一。"
                return
            }
            seen[shortcut] = entry.title
        }
        conflictMessage = nil
    }
}
