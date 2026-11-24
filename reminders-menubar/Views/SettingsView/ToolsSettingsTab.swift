import SwiftUI

struct ToolsSettingsTab: View {
    @ObservedObject private var userPreferences = UserPreferences.shared
    @ObservedObject private var clipboardStore = ClipboardHistoryStore.shared
    @ObservedObject private var notesStore = QuickNotesStore.shared

    private var pinnedClipboardCount: Int {
        clipboardStore.items.filter(\.isPinned).count
    }

    private var focusDurationOptions: [Int] {
        Self.mergedOptions([15, 20, 25, 30, 45, 60], including: userPreferences.pomodoroFocusMinutes)
    }

    private var shortBreakDurationOptions: [Int] {
        Self.mergedOptions([3, 5, 8, 10], including: userPreferences.pomodoroShortBreakMinutes)
    }

    private var longBreakDurationOptions: [Int] {
        Self.mergedOptions([10, 15, 20, 30], including: userPreferences.pomodoroLongBreakMinutes)
    }

    private static func mergedOptions(_ defaults: [Int], including current: Int) -> [Int] {
        var values = defaults
        if current > 0 && !values.contains(current) {
            values.append(current)
            values.sort()
        }
        return values
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeader(title: "工具")

                SettingsCard(title: "番茄钟") {
                    SettingsRow("专注时长") {
                        Picker("", selection: $userPreferences.pomodoroFocusMinutes) {
                            ForEach(focusDurationOptions, id: \.self) { mins in
                                Text("\(mins) 分钟").tag(mins)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 108)
                    }

                    SettingsRow("短休息") {
                        Picker("", selection: $userPreferences.pomodoroShortBreakMinutes) {
                            ForEach(shortBreakDurationOptions, id: \.self) { mins in
                                Text("\(mins) 分钟").tag(mins)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 108)
                    }

                    SettingsRow("长休息", subtitle: "每完成 4 轮专注后触发") {
                        Picker("", selection: $userPreferences.pomodoroLongBreakMinutes) {
                            ForEach(longBreakDurationOptions, id: \.self) { mins in
                                Text("\(mins) 分钟").tag(mins)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 108)
                    }

                    SettingsRow("结束提示音", showDivider: false) {
                        Toggle("", isOn: $userPreferences.pomodoroSoundEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                }

                SettingsCard(title: "剪贴板") {
                    SettingsRow("保留上限", subtitle: "已收藏记录不受上限影响") {
                        Picker("", selection: $userPreferences.clipboardMaxItems) {
                            Text("30 条").tag(30)
                            Text("50 条").tag(50)
                            Text("80 条").tag(80)
                            Text("150 条").tag(150)
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .labelsHidden()
                        .frame(width: 108)
                    }

                    SettingsRow(
                        "历史记录",
                        subtitle: "共 \(clipboardStore.items.count) 条 · 已收藏 \(pinnedClipboardCount) 条",
                        showDivider: false
                    ) {
                        Button("清空未收藏") {
                            clipboardStore.clearUnpinned()
                        }
                        .controlSize(.small)
                        .disabled(clipboardStore.items.allSatisfy(\.isPinned))
                    }
                }

                SettingsCard(title: "随笔") {
                    SettingsRow("默认便签色") {
                        HStack(spacing: 6) {
                            ForEach(NoteColorTag.allCases) { tag in
                                let selected = userPreferences.defaultNoteColorTag == tag
                                Button {
                                    userPreferences.defaultNoteColorTag = tag
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(tag.accentColor)
                                            .frame(width: selected ? 14 : 12, height: selected ? 14 : 12)
                                        if selected {
                                            Circle()
                                                .strokeBorder(Color.primary.opacity(0.55), lineWidth: 1.5)
                                                .frame(width: 19, height: 19)
                                        }
                                    }
                                    .frame(width: 20, height: 20)
                                    .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help(tag.title)
                            }
                        }
                    }

                    SettingsRow("Markdown 实时排版", subtitle: "输入语法后即时转换样式") {
                        Toggle("", isOn: $userPreferences.isNoteMarkdownEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }

                    SettingsRow(
                        "本地随笔",
                        subtitle: "共 \(notesStore.notes.count) 篇，自动保存至本地",
                        showDivider: false
                    ) {
                        Button("打开") {
                            PinnedRemindersStore.shared.showPanel(tab: .notes)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(20)
        }
    }
}
