import Combine
import SwiftUI

@available(macOS 14.0, *)
@MainActor
final class SettingsOpenerBridge {
    private enum State {
        case listenerUnavailable
        case reopening
        case awaitingListener
        case listenerReady
    }

    static let shared = SettingsOpenerBridge()

    private var state = State.listenerUnavailable

    private init() {}

    func requestOpen() {
        switch state {
        case .listenerReady:
            postRequest()
            return
        case .reopening:
            return
        case .listenerUnavailable, .awaitingListener:
            state = .reopening
            reopenApplication()
        }
    }

    func listenerDidAppear() {
        let shouldOpenSettings = state == .reopening || state == .awaitingListener
        state = .listenerReady

        if shouldOpenSettings {
            DispatchQueue.main.async { [weak self] in
                self?.postRequest()
            }
        }
    }

    func listenerDidDisappear() {
        state = .listenerUnavailable
    }

    private func reopenApplication() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false

        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration,
            completionHandler: { [weak self] _, error in
                Task { @MainActor in
                    guard let self, self.state == .reopening else { return }
                    self.state = error == nil ? .awaitingListener : .listenerUnavailable
                }
            }
        )
    }

    private func postRequest() {
        NotificationCenter.default.post(name: .openSettingsRequest, object: nil)
    }
}

@available(macOS 14.0, *)
struct SettingsOpenerView: View {
    @Environment(\.openSettings) private var openSettings
    @State private var isOpeningSettings = false
    @State private var settingsOpenCancellable: AnyCancellable?
    @State private var settingsCloseCancellable: AnyCancellable?
    @State private var settingsWindow: NSWindow?
    @State private var pendingCancel: (() -> Void)?
    @State private var didSwitchFromAccessory = false

    var body: some View {
        SettingsOpenerHiddenWindow()
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear {
                SettingsOpenerBridge.shared.listenerDidAppear()
            }
            .onDisappear {
                pendingCancel?()
                pendingCancel = nil
                settingsOpenCancellable?.cancel()
                settingsOpenCancellable = nil
                SettingsOpenerBridge.shared.listenerDidDisappear()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequest)) { _ in
                Task { @MainActor in
                    await handleOpenSettingsRequest()
                }
            }
    }

    private func handleOpenSettingsRequest() async {
        // If settings window is already open (including minimized/hidden), restore and bring it above floating panels.
        if let existingWindow = settingsWindow ?? NSApp.windows.first(where: { Self.isSettingsWindow($0, allowHiddenOrMiniaturized: true) }),
           (existingWindow.isVisible || existingWindow.isMiniaturized) {
            settingsWindow = existingWindow
            if existingWindow.isMiniaturized {
                existingWindow.deminiaturize(nil)
            }
            existingWindow.level = .floating
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.orderFrontRegardless()
            return
        }

        guard !isOpeningSettings else { return }
        isOpeningSettings = true
        defer { isOpeningSettings = false }

        // Clear any stale reference from a previous session.
        settingsWindow = nil

        // Temporarily show dock icon so macOS allows the window to come to front; preserve
        // `didSwitchFromAccessory` across minimize/reopen so closing never leaks the Dock icon.
        let switchedThisOpen = NSApp.activationPolicy() == .accessory
        if switchedThisOpen {
            didSwitchFromAccessory = true
            NSApp.setActivationPolicy(.regular)
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Capture already-visible non-settings windows so we never mistake them for Settings.
        let preExistingVisibleIds = Set(
            NSApp.windows
                .filter { $0.isVisible && !Self.isSettingsWindow($0) }
                .map(\.windowNumber)
        )

        // Two parallel detection strategies:
        // 1. Notification-based (fast path): captures the window the instant it becomes key or main.
        // 2. Periodic window scan (fallback): checks NSApp.windows every interval.
        // Calling openSettings() after subscription setup.
        let window: NSWindow? = await withCheckedContinuation { continuation in
            var capturedWindow: NSWindow?
            var hasResumed = false

            let finish: (NSWindow?) -> Void = { result in
                guard !hasResumed else { return }
                hasResumed = true
                settingsOpenCancellable?.cancel()
                settingsOpenCancellable = nil
                pendingCancel = nil
                continuation.resume(returning: result)
            }

            pendingCancel = {
                finish(nil)
            }

            let matcher: (NSWindow) -> Bool = { candidate in
                !preExistingVisibleIds.contains(candidate.windowNumber) && Self.isSettingsWindow(candidate)
            }

            let windowNotifications = Publishers.Merge(
                NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification),
                NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)
            )
                .compactMap { $0.object as? NSWindow }
                .filter(matcher)

            let windowScan = Timer.publish(every: 0.25, on: .main, in: .common)
                .autoconnect()
                .compactMap { _ in NSApp.windows.first(where: matcher) }

            settingsOpenCancellable = windowNotifications
                .merge(with: windowScan)
                .first()
                .timeout(.seconds(5), scheduler: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in
                        finish(capturedWindow)
                    },
                    receiveValue: { window in
                        capturedWindow = window
                    }
                )

            openSettings()
        }

        if let window {
            settingsWindow = window
            // Float above Piko's floating board/mini panels so Settings is never buried behind them.
            window.level = .floating
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()

            // Clean settingsWindow state and restore accessory policy when the settings window closes.
            observeSettingsClose(window)
        } else if switchedThisOpen {
            // Window never appeared; restore accessory policy immediately.
            didSwitchFromAccessory = false
            NSApp.setActivationPolicy(.accessory)
        }
    }

    static func isSettingsWindow(_ window: NSWindow, allowHiddenOrMiniaturized: Bool = false) -> Bool {
        guard !(window is NSPanel),
              window.styleMask.contains(.titled),
              (allowHiddenOrMiniaturized || window.isVisible),
              window.frame.height > 100 else {
            return false
        }
        let rawId = window.identifier?.rawValue ?? ""
        if rawId == "SettingsOpener" {
            return false
        }
        let idMatch = rawId.localizedCaseInsensitiveContains("settings")
        let titleMatch = window.title.localizedCaseInsensitiveContains("settings")
            || window.title.contains("设置")
        let swiftUISettingsClass = window.className.contains("SwiftUI")
        return idMatch || titleMatch || swiftUISettingsClass
    }

    private func observeSettingsClose(_ window: NSWindow) {
        settingsCloseCancellable?.cancel()
        settingsCloseCancellable = NotificationCenter.default
            .publisher(for: NSWindow.willCloseNotification, object: window)
            .first()
            .sink { _ in
                settingsWindow = nil
                if didSwitchFromAccessory {
                    didSwitchFromAccessory = false
                    NSApp.setActivationPolicy(.accessory)
                }
            }
    }
}

private struct SettingsOpenerHiddenWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        HelperNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private class HelperNSView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let existing = observer {
                NotificationCenter.default.removeObserver(existing)
                observer = nil
            }
            guard window != nil else { return }
            applyHiddenBehavior()
            // Re-apply whenever app becomes active (covers activation policy resets)
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.applyHiddenBehavior()
            }
        }

        private func applyHiddenBehavior() {
            guard let window else { return }
            window.collectionBehavior.insert([.ignoresCycle, .transient])
            window.isExcludedFromWindowsMenu = true
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
