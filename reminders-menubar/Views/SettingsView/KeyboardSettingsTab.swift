import SwiftUI
import KeyboardShortcuts

struct KeyboardSettingsTab: View {
    @ObservedObject var keyboardShortcutService = KeyboardShortcutService.shared

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

                Text("点击录制框自定义组合键，可随时恢复默认。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            .padding(20)
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
                KeyboardShortcuts.Recorder(for: name)
                    .disabled(!isEnabled.wrappedValue)

                Button("默认") {
                    KeyboardShortcutService.shared.reset(name)
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
}
