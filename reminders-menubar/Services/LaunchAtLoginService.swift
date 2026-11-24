import Combine
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService: ObservableObject {
    enum Status {
        case enabled
        case disabled
        case requiresApproval
        case unavailable
    }

    static let shared = LaunchAtLoginService()

    @Published private(set) var status: Status = .disabled

    private init() {
        refresh()
    }

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    func setEnabled(_ isEnabled: Bool) {
        let mainAppService = SMAppService.mainApp
        let isRegistered = mainAppService.status == .enabled || mainAppService.status == .requiresApproval
        guard isRegistered != isEnabled else {
            refresh()
            return
        }

        do {
            if isEnabled {
                try mainAppService.register()
            } else {
                try mainAppService.unregister()
            }
        } catch {
            print("Failed to \(isEnabled ? "enable" : "disable") launch at login:", error.localizedDescription)
        }
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notFound:
            status = .unavailable
        case .notRegistered:
            status = .disabled
        @unknown default:
            status = .disabled
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
