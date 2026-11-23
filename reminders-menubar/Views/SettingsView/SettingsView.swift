import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case tools
    case keyboard
    case maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .tools: return "工具"
        case .keyboard: return "快捷键"
        case .maintenance: return "数据与关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .tools: return "square.grid.2x2"
        case .keyboard: return "command"
        case .maintenance: return "tray.full"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var coordinator = SettingsCoordinator.shared
    @ObservedObject private var userPreferences = UserPreferences.shared

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 162)
                .background(Color.primary.opacity(0.025))

            Divider().opacity(0.45)

            Group {
                switch coordinator.selectedTab {
                case .general:
                    GeneralSettingsTab()
                case .tools:
                    ToolsSettingsTab()
                case .keyboard:
                    KeyboardSettingsTab()
                case .maintenance:
                    MaintenanceSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 620, height: 472)
        .preferredColorScheme(userPreferences.rmbColorScheme.colorScheme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                PikoAppIconView(size: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(AppConstants.appName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(AppConstants.displayVersion)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 16)

            VStack(spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    SettingsSidebarItem(
                        tab: tab,
                        isSelected: coordinator.selectedTab == tab
                    ) {
                        coordinator.selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
    }
}

private struct SettingsSidebarItem: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 18, alignment: .center)

                Text(tab.title)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.primary.opacity(0.085)
                            : (isHovered ? Color.primary.opacity(0.045) : Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .transaction { $0.animation = nil }
    }
}
