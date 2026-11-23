import Cocoa
import QuartzCore
import SwiftUI

private final class PinnedFloatingPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// AppKit-backed drag region placed strictly in empty header space so dragging
/// the borderless panel is 100% smooth without overlapping any SwiftUI buttons.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableAreaNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DraggableAreaNSView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// AppKit-backed bottom-right resize handle using screen coordinates (`NSEvent.mouseLocation`)
/// to completely eliminate SwiftUI `.global` coordinate feedback jitter during window resizing.
struct WindowResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ResizeHandleNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResizeHandleNSView: NSView {
    private var initialMouseScreenLocation: NSPoint = .zero
    private var initialWindowFrame: NSRect = .zero

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialMouseScreenLocation = NSEvent.mouseLocation
        initialWindowFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - initialMouseScreenLocation.x
        let dy = initialMouseScreenLocation.y - current.y // dragging downward increases height

        let minSize = window.minSize
        let maxSize = window.maxSize
        let inset = PinnedPanelController.shadowInset
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maxAllowedWidth = visibleFrame.map { min(maxSize.width, max(minSize.width, ($0.maxX + inset) - initialWindowFrame.minX)) } ?? maxSize.width
        let maxAllowedHeight = visibleFrame.map { min(maxSize.height, max(minSize.height, initialWindowFrame.maxY - ($0.minY - inset))) } ?? maxSize.height
        let newWidth = max(minSize.width, min(maxAllowedWidth, initialWindowFrame.width + dx))
        let newHeight = max(minSize.height, min(maxAllowedHeight, initialWindowFrame.height + dy))
        let newOriginY = initialWindowFrame.maxY - newHeight

        let newFrame = NSRect(x: initialWindowFrame.minX, y: newOriginY, width: newWidth, height: newHeight)
        window.setFrame(newFrame, display: true, animate: false)
    }

    override func mouseUp(with event: NSEvent) {
        Task { @MainActor in
            PinnedPanelController.shared.finishManualResize()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .rmbDiagonalResize)
    }
}

/// NSHostingView subclass that makes the transparent GPU shadow margin 100% click-through
/// so underlying desktop windows receive mouse events right up to the visible card border.
private final class ShadowPassthroughHostingView<Content: View>: NSHostingView<Content> {
    var cardInset: CGFloat = PinnedPanelController.shadowInset

    override func hitTest(_ point: NSPoint) -> NSView? {
        let cardRect = bounds.insetBy(dx: cardInset, dy: cardInset)
        guard cardRect.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class PinnedPanelController: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = PinnedPanelController()

    /// Transparent outer padding around each floating card so crisp SwiftUI/GPU shadows
    /// and spring transitions never clip and WindowServer never recomputes alpha-mask shadows.
    static let shadowInset: CGFloat = 22

    static let defaultSize = NSSize(width: 880, height: 580)
    static let minExpandedSize = NSSize(width: 360, height: 340)
    static let maxExpandedSize = NSSize(width: 1_440, height: 980)

    static let miniWidth: CGFloat = 336
    static let miniPomodoroHeight: CGFloat = 138
    static let miniDefaultListHeight: CGFloat = 436
    static let minMiniListSize = NSSize(width: 312, height: 280)
    static let maxMiniListSize = NSSize(width: 460, height: 780)

    static let collapsedHeight: CGFloat = 44
    private static let defaultScreenInset: CGFloat = 20
    private static let cornerInset: CGFloat = 16

    private static let smoothFrameEase = CAMediaTimingFunction(controlPoints: 0.22, 0.94, 0.32, 1.0)
    private static let fadeOutCurve = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.22, 1.0)
    private static let fadeInCurve = CAMediaTimingFunction(controlPoints: 0.16, 0.90, 0.28, 1.0)

    @Published private(set) var isCornerMiniMode = false

    /// Persistent dual panels: keeps both the full workspace and corner mini panel warm in memory
    /// so transitions fire on the very next VSync (< 1ms click latency) via pure CoreAnimation GPU transforms.
    private var mainPanel: PinnedFloatingPanel?
    private var miniPanel: PinnedFloatingPanel?
    private var hasScheduledMiniPrewarm = false

    private var expandedCardFrameBeforeSpecialMode: NSRect?
    private var customMiniListSize = NSSize(width: miniWidth, height: miniDefaultListHeight)
    private var isProgrammaticFrameUpdate = false
    private var modeTransitionToken = 0
    private var frameAnimationToken = 0

    private override init() {
        super.init()
    }

    private func paddedWindowFrame(for cardFrame: NSRect) -> NSRect {
        cardFrame.insetBy(dx: -Self.shadowInset, dy: -Self.shadowInset)
    }

    private func cardFrame(from windowFrame: NSRect) -> NSRect {
        windowFrame.insetBy(dx: Self.shadowInset, dy: Self.shadowInset)
    }

    private func paddedSize(for cardSize: NSSize) -> NSSize {
        NSSize(width: cardSize.width + Self.shadowInset * 2, height: cardSize.height + Self.shadowInset * 2)
    }

    private func scheduleMiniPrewarmIfNeeded() {
        guard !hasScheduledMiniPrewarm, miniPanel == nil else { return }
        hasScheduledMiniPrewarm = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
            guard let self, self.miniPanel == nil else { return }
            _ = self.ensureMiniPanel(for: PinnedRemindersStore.shared.activeTab)
        }
    }

    private func resetLayerImmediately(of panel: NSPanel?) {
        guard let layer = panel?.contentView?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1.0
        layer.shouldRasterize = false
        CATransaction.commit()
    }

    private func pivotTransform(
        on layer: CALayer,
        pivot: CGPoint,
        scale: CGFloat,
        tx: CGFloat,
        ty: CGFloat
    ) -> CATransform3D {
        let ax = layer.bounds.width * layer.anchorPoint.x
        let ay = layer.bounds.height * layer.anchorPoint.y
        let dx = pivot.x - ax
        let dy = pivot.y - ay
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, dx + tx, dy + ty, 0)
        t = CATransform3DScale(t, scale, scale, 1.0)
        t = CATransform3DTranslate(t, -dx, -dy, 0)
        return t
    }

    private func makeSpringAnimation(
        keyPath: String,
        from: Any,
        to: Any,
        stiffness: CGFloat = 330,
        damping: CGFloat = 29
    ) -> CASpringAnimation {
        let anim = CASpringAnimation(keyPath: keyPath)
        anim.mass = 1.0
        anim.stiffness = stiffness
        anim.damping = damping
        anim.initialVelocity = 0
        anim.fromValue = from
        anim.toValue = to
        anim.duration = anim.settlingDuration
        anim.fillMode = .both
        return anim
    }

    private func makeBasicAnimation(
        keyPath: String,
        from: Any,
        to: Any,
        duration: CFTimeInterval,
        curve: CAMediaTimingFunction
    ) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = duration
        anim.timingFunction = curve
        anim.fillMode = .both
        return anim
    }

    private func runInstantGPUTransition(
        outgoing: NSPanel,
        incoming: NSPanel,
        outgoingCardFrame: NSRect,
        incomingCardFrame: NSRect,
        expanding: Bool,
        token: Int
    ) {
        guard let outView = outgoing.contentView,
              let inView = incoming.contentView else {
            outgoing.orderOut(nil)
            incoming.alphaValue = 1
            incoming.orderFrontRegardless()
            incoming.makeKey()
            return
        }

        outView.wantsLayer = true
        inView.wantsLayer = true
        guard let outLayer = outView.layer, let inLayer = inView.layer else {
            outgoing.orderOut(nil)
            incoming.alphaValue = 1
            incoming.orderFrontRegardless()
            incoming.makeKey()
            return
        }

        let outScaleFactor = outgoing.backingScaleFactor > 0 ? outgoing.backingScaleFactor : 2.0
        let inScaleFactor = incoming.backingScaleFactor > 0 ? incoming.backingScaleFactor : 2.0

        // Compute directional vector between visible card centers (capped cleanly within shadowInset)
        let rawDx = incomingCardFrame.midX - outgoingCardFrame.midX
        let rawDy = incomingCardFrame.midY - outgoingCardFrame.midY
        let dist = hypot(rawDx, rawDy)
        let dirX: CGFloat = dist > 4 ? (rawDx / dist) : (expanding ? -0.85 : 0.85)
        let dirY: CGFloat = dist > 4 ? (rawDy / dist) : (expanding ? -0.52 : 0.52)

        let outTravel: CGFloat = 16
        let inTravel: CGFloat = 18

        // Pivot point on incoming card pointing directly toward the outgoing card
        let inPivotX = (outgoingCardFrame.midX - incoming.frame.minX).constrainedTo(
            min: Self.shadowInset + incomingCardFrame.width * 0.15,
            max: Self.shadowInset + incomingCardFrame.width * 0.92
        )
        let inPivotY = (outgoingCardFrame.midY - incoming.frame.minY).constrainedTo(
            min: Self.shadowInset + incomingCardFrame.height * 0.15,
            max: Self.shadowInset + incomingCardFrame.height * 0.92
        )
        let inPivot = CGPoint(x: inPivotX, y: inPivotY)

        // Pivot point on outgoing card pointing toward the incoming card
        let outPivotX = (incomingCardFrame.midX - outgoing.frame.minX).constrainedTo(
            min: Self.shadowInset + outgoingCardFrame.width * 0.15,
            max: Self.shadowInset + outgoingCardFrame.width * 0.92
        )
        let outPivotY = (incomingCardFrame.midY - outgoing.frame.minY).constrainedTo(
            min: Self.shadowInset + outgoingCardFrame.height * 0.15,
            max: Self.shadowInset + outgoingCardFrame.height * 0.92
        )
        let outPivot = CGPoint(x: outPivotX, y: outPivotY)

        let inStartTransform = pivotTransform(
            on: inLayer,
            pivot: inPivot,
            scale: expanding ? 0.88 : 0.86,
            tx: -dirX * inTravel,
            ty: -dirY * inTravel
        )
        let outEndTransform = pivotTransform(
            on: outLayer,
            pivot: outPivot,
            scale: expanding ? 0.90 : 0.88,
            tx: dirX * outTravel,
            ty: dirY * outTravel
        )

        // GPU-rasterize each window into a single Metal texture (< 0.5ms on GPU, ZERO CPU cacheDisplay!)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        outLayer.removeAllAnimations()
        outLayer.shouldRasterize = true
        outLayer.rasterizationScale = outScaleFactor

        inLayer.removeAllAnimations()
        inLayer.shouldRasterize = true
        inLayer.rasterizationScale = inScaleFactor
        inLayer.transform = inStartTransform
        inLayer.opacity = 0.0

        CATransaction.commit()

        incoming.alphaValue = 1
        incoming.orderFrontRegardless()
        incoming.makeKey()

        // Submit pure CoreAnimation Metal spring animations immediately — ZERO delay, locked 120Hz!
        let inSpring = makeSpringAnimation(
            keyPath: "transform",
            from: NSValue(caTransform3D: inStartTransform),
            to: NSValue(caTransform3D: CATransform3DIdentity),
            stiffness: expanding ? 310 : 340,
            damping: expanding ? 28 : 30
        )
        let inOpacityAnim = makeBasicAnimation(
            keyPath: "opacity",
            from: 0.0,
            to: 1.0,
            duration: 0.18,
            curve: Self.fadeInCurve
        )
        let outTransformAnim = makeBasicAnimation(
            keyPath: "transform",
            from: NSValue(caTransform3D: CATransform3DIdentity),
            to: NSValue(caTransform3D: outEndTransform),
            duration: 0.18,
            curve: Self.fadeOutCurve
        )
        let outOpacityAnim = makeBasicAnimation(
            keyPath: "opacity",
            from: 1.0,
            to: 0.0,
            duration: 0.16,
            curve: Self.fadeOutCurve
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        inLayer.transform = CATransform3DIdentity
        inLayer.opacity = 1.0
        inLayer.add(inSpring, forKey: "piko_in_transform")
        inLayer.add(inOpacityAnim, forKey: "piko_in_opacity")

        outLayer.transform = outEndTransform
        outLayer.opacity = 0.0
        outLayer.add(outTransformAnim, forKey: "piko_out_transform")
        outLayer.add(outOpacityAnim, forKey: "piko_out_opacity")

        CATransaction.commit()

        // Cleanly hide outgoing panel as soon as its fade finishes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.19) { [weak self, weak outgoing] in
            guard let self, self.modeTransitionToken == token else { return }
            outgoing?.orderOut(nil)
            self.resetLayerImmediately(of: outgoing)
        }

        // Disable GPU rasterization once spring settles so text returns to native subpixel sharpness
        let settleDelay = min(0.42, max(0.28, inSpring.settlingDuration * 0.85))
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self, weak incoming] in
            guard let self, self.modeTransitionToken == token else { return }
            guard let layer = incoming?.contentView?.layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.shouldRasterize = false
            CATransaction.commit()
        }
    }

    func show() {
        modeTransitionToken += 1
        resetLayerImmediately(of: mainPanel)
        resetLayerImmediately(of: miniPanel)

        if isCornerMiniMode {
            let mini = ensureMiniPanel(for: PinnedRemindersStore.shared.activeTab)
            mainPanel?.orderOut(nil)
            mini.alphaValue = 1
            mini.orderFrontRegardless()
            mini.makeKey()
            return
        }

        let panel = ensureMainPanel()
        miniPanel?.orderOut(nil)
        if PinnedRemindersStore.shared.isCollapsed {
            applyCollapsedState(true)
        }
        applyMainWindowLevel(to: panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        scheduleMiniPrewarmIfNeeded()
    }

    func toggleAlwaysOnTop() {
        UserPreferences.shared.isBoardAlwaysOnTop.toggle()
    }

    func syncWindowLevelFromPreferences() {
        guard let mainPanel else { return }
        applyMainWindowLevel(to: mainPanel)
        if !isCornerMiniMode && UserPreferences.shared.isBoardAlwaysOnTop && PinnedRemindersStore.shared.isPanelVisible {
            mainPanel.orderFrontRegardless()
        }
    }

    private func applyMainWindowLevel(to panel: NSPanel) {
        if UserPreferences.shared.isBoardAlwaysOnTop {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        } else {
            panel.level = .normal
            panel.collectionBehavior = [.managed, .participatesInCycle]
        }
    }

    private func applyMiniWindowLevel(to panel: NSPanel) {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    func hide() {
        modeTransitionToken += 1
        frameAnimationToken += 1
        resetLayerImmediately(of: mainPanel)
        resetLayerImmediately(of: miniPanel)
        if let mainPanel {
            if !isCornerMiniMode && mainPanel.isVisible {
                persistCurrentFrame(for: mainPanel)
            }
            mainPanel.orderOut(nil)
            mainPanel.alphaValue = 1
        }
        if let miniPanel {
            miniPanel.orderOut(nil)
            miniPanel.alphaValue = 1
        }
    }

    func resetDefaultBoardSize() {
        modeTransitionToken += 1
        resetLayerImmediately(of: mainPanel)
        resetLayerImmediately(of: miniPanel)
        let wasMini = isCornerMiniMode
        isCornerMiniMode = false
        if PinnedRemindersStore.shared.isCollapsed {
            PinnedRemindersStore.shared.isCollapsed = false
        }
        PinnedRemindersStore.shared.isPanelVisible = true

        let visibleFrame = defaultScreenVisibleFrame()
        let size = Self.defaultSize
        let targetCardFrame = NSRect(
            x: visibleFrame.maxX - size.width - Self.defaultScreenInset,
            y: visibleFrame.maxY - size.height - Self.defaultScreenInset,
            width: size.width,
            height: size.height
        )
        UserPreferences.shared.pinnedPanelFrame = targetCardFrame
        expandedCardFrameBeforeSpecialMode = targetCardFrame

        let panel = ensureMainPanel()
        miniPanel?.orderOut(nil)
        miniPanel?.alphaValue = 1

        let targetWindowFrame = paddedWindowFrame(for: targetCardFrame)
        isProgrammaticFrameUpdate = true
        panel.minSize = paddedSize(for: Self.minExpandedSize)
        panel.maxSize = paddedSize(for: Self.maxExpandedSize)
        applyMainWindowLevel(to: panel)

        if wasMini || !panel.isVisible {
            panel.setFrame(targetWindowFrame, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.makeKey()
            isProgrammaticFrameUpdate = false
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.makeKey()
            animateFrame(of: panel, to: targetWindowFrame, duration: 0.24)
        }
    }

    // MARK: - Unified Top-Right Corner Mini Window Mode

    func enterCornerMiniMode(tab: BoardTab? = nil) {
        let targetTab = tab ?? PinnedRemindersStore.shared.activeTab
        let previousMainPanel = mainPanel
        let shouldAnimateFromMain = !isCornerMiniMode && (previousMainPanel?.isVisible == true)

        if !isCornerMiniMode {
            if let previousMainPanel, !PinnedRemindersStore.shared.isCollapsed {
                expandedCardFrameBeforeSpecialMode = cardFrame(from: previousMainPanel.frame)
                persistCurrentFrame(for: previousMainPanel)
            }
            isCornerMiniMode = true
        }

        PinnedRemindersStore.shared.isPanelVisible = true
        if PinnedRemindersStore.shared.isCollapsed {
            PinnedRemindersStore.shared.isCollapsed = false
        }
        PinnedRemindersStore.shared.activeTab = targetTab

        let token = nextModeTransitionToken()
        let mini = ensureMiniPanel(for: targetTab)

        let screenFrame = previousMainPanel.map { currentVisibleFrame(for: $0) } ?? currentVisibleFrame(for: mini)
        let size = miniSize(for: targetTab)
        let cornerCardFrame = NSRect(
            x: screenFrame.maxX - size.width - Self.cornerInset,
            y: screenFrame.maxY - size.height - Self.cornerInset,
            width: size.width,
            height: size.height
        )
        let cornerWindowFrame = paddedWindowFrame(for: cornerCardFrame)

        configureMiniConstraints(for: targetTab, on: mini, cardWidth: cornerCardFrame.width)
        isProgrammaticFrameUpdate = true
        mini.setFrame(cornerWindowFrame, display: false)
        isProgrammaticFrameUpdate = false

        guard shouldAnimateFromMain, let outgoingMain = previousMainPanel else {
            resetLayerImmediately(of: mini)
            resetLayerImmediately(of: previousMainPanel)
            mini.alphaValue = 1
            mini.orderFrontRegardless()
            mini.makeKey()
            previousMainPanel?.orderOut(nil)
            return
        }

        runInstantGPUTransition(
            outgoing: outgoingMain,
            incoming: mini,
            outgoingCardFrame: cardFrame(from: outgoingMain.frame),
            incomingCardFrame: cornerCardFrame,
            expanding: false,
            token: token
        )
    }

    func snapPomodoroToTopRightCorner() {
        enterCornerMiniMode(tab: .pomodoro)
    }

    func snapMiniWindowToTopRightCorner() {
        guard isCornerMiniMode, let miniPanel else {
            enterCornerMiniMode(tab: PinnedRemindersStore.shared.activeTab)
            return
        }
        let targetTab = PinnedRemindersStore.shared.activeTab
        let screenFrame = currentVisibleFrame(for: miniPanel)
        let size = miniSize(for: targetTab)
        let cornerCardFrame = NSRect(
            x: screenFrame.maxX - size.width - Self.cornerInset,
            y: screenFrame.maxY - size.height - Self.cornerInset,
            width: size.width,
            height: size.height
        )
        configureMiniConstraints(for: targetTab, on: miniPanel, cardWidth: cornerCardFrame.width)
        animateFrame(of: miniPanel, to: paddedWindowFrame(for: cornerCardFrame), duration: 0.24)
    }

    func switchCornerMiniTab(_ tab: BoardTab) {
        PinnedRemindersStore.shared.activeTab = tab
        guard isCornerMiniMode, let miniPanel else { return }

        let screenFrame = currentVisibleFrame(for: miniPanel)
        let size = miniSize(for: tab)
        let currentCard = cardFrame(from: miniPanel.frame)

        // Anchor the top-right corner so the mini header bar stays completely steady when switching tabs
        let anchorMaxX = currentCard.maxX
        let anchorMaxY = currentCard.maxY
        let originX = (anchorMaxX - size.width).constrainedTo(
            min: screenFrame.minX,
            max: max(screenFrame.minX, screenFrame.maxX - size.width)
        )
        let originY = (anchorMaxY - size.height).constrainedTo(
            min: screenFrame.minY,
            max: max(screenFrame.minY, screenFrame.maxY - size.height)
        )
        let targetCardFrame = NSRect(x: originX, y: originY, width: size.width, height: size.height)
        configureMiniConstraints(for: tab, on: miniPanel, cardWidth: targetCardFrame.width)
        animateFrame(of: miniPanel, to: paddedWindowFrame(for: targetCardFrame), duration: 0.24)
        if PinnedRemindersStore.shared.isPanelVisible {
            miniPanel.makeKey()
        }
    }

    func exitCornerMiniMode(targetTab: BoardTab? = nil) {
        let resolvedTab = targetTab ?? PinnedRemindersStore.shared.activeTab
        let outgoingMini = miniPanel
        let shouldAnimateFromMini = (outgoingMini?.isVisible == true)

        guard isCornerMiniMode || shouldAnimateFromMini else {
            PinnedRemindersStore.shared.activeTab = resolvedTab
            return
        }

        isCornerMiniMode = false
        PinnedRemindersStore.shared.activeTab = resolvedTab
        PinnedRemindersStore.shared.isPanelVisible = true
        if PinnedRemindersStore.shared.isCollapsed {
            PinnedRemindersStore.shared.isCollapsed = false
        }

        let token = nextModeTransitionToken()
        let main = ensureMainPanel()
        let targetCardFrame = expandedCardFrameBeforeSpecialMode ?? restoredCardFrame()
        let targetWindowFrame = paddedWindowFrame(for: targetCardFrame)

        isProgrammaticFrameUpdate = true
        main.minSize = paddedSize(for: Self.minExpandedSize)
        main.maxSize = paddedSize(for: Self.maxExpandedSize)
        applyMainWindowLevel(to: main)
        if main.frame != targetWindowFrame {
            main.setFrame(targetWindowFrame, display: false)
        }
        isProgrammaticFrameUpdate = false

        guard shouldAnimateFromMini, let outgoingMini else {
            resetLayerImmediately(of: main)
            resetLayerImmediately(of: outgoingMini)
            main.alphaValue = 1
            main.orderFrontRegardless()
            main.makeKey()
            outgoingMini?.orderOut(nil)
            return
        }

        runInstantGPUTransition(
            outgoing: outgoingMini,
            incoming: main,
            outgoingCardFrame: cardFrame(from: outgoingMini.frame),
            incomingCardFrame: targetCardFrame,
            expanding: true,
            token: token
        )
    }

    func exitMiniPomodoroCornerMode(targetTab: BoardTab = .board) {
        exitCornerMiniMode(targetTab: targetTab)
    }

    func toggleCornerMiniMode() {
        if (isCornerMiniMode || miniPanel?.isVisible == true) && PinnedRemindersStore.shared.isPanelVisible {
            exitCornerMiniMode()
        } else {
            enterCornerMiniMode(tab: PinnedRemindersStore.shared.activeTab)
        }
    }

    private func nextModeTransitionToken() -> Int {
        modeTransitionToken += 1
        return modeTransitionToken
    }

    private func animateFrame(of panel: NSPanel, to frame: NSRect, duration: TimeInterval) {
        frameAnimationToken += 1
        let token = frameAnimationToken
        isProgrammaticFrameUpdate = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = Self.smoothFrameEase
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.frameAnimationToken == token else { return }
                self.isProgrammaticFrameUpdate = false
            }
        })
    }

    private func miniSize(for tab: BoardTab) -> NSSize {
        switch tab {
        case .pomodoro:
            return NSSize(width: customMiniListSize.width, height: Self.miniPomodoroHeight)
        case .board, .clipboard, .notes:
            return customMiniListSize
        }
    }

    private func configureMiniConstraints(for tab: BoardTab, on panel: NSPanel, cardWidth: CGFloat) {
        if tab == .pomodoro {
            let fixedCardSize = NSSize(width: cardWidth, height: Self.miniPomodoroHeight)
            panel.minSize = paddedSize(for: fixedCardSize)
            panel.maxSize = paddedSize(for: NSSize(width: Self.maxMiniListSize.width, height: Self.miniPomodoroHeight))
        } else {
            panel.minSize = paddedSize(for: Self.minMiniListSize)
            panel.maxSize = paddedSize(for: Self.maxMiniListSize)
        }
        applyMiniWindowLevel(to: panel)
    }

    // MARK: - Collapse / Resize

    func applyCollapsedState(_ collapsed: Bool) {
        guard let mainPanel, !isCornerMiniMode else { return }

        let currentCard = cardFrame(from: mainPanel.frame)
        let topLeft = NSPoint(x: currentCard.minX, y: currentCard.maxY)
        let width = currentCard.width

        let newCardFrame: NSRect
        if collapsed {
            if currentCard.height > Self.collapsedHeight + 20 {
                expandedCardFrameBeforeSpecialMode = currentCard
            }
            mainPanel.minSize = paddedSize(for: NSSize(width: Self.minExpandedSize.width, height: Self.collapsedHeight))
            newCardFrame = NSRect(
                x: topLeft.x,
                y: topLeft.y - Self.collapsedHeight,
                width: width,
                height: Self.collapsedHeight
            )
        } else {
            let savedHeight = expandedCardFrameBeforeSpecialMode?.height ?? Self.defaultSize.height
            let targetHeight = max(Self.minExpandedSize.height, savedHeight)
            mainPanel.minSize = paddedSize(for: Self.minExpandedSize)
            let screenFrame = currentVisibleFrame(for: mainPanel)
            let originY = (topLeft.y - targetHeight).constrainedTo(
                min: screenFrame.minY,
                max: max(screenFrame.minY, screenFrame.maxY - targetHeight)
            )
            newCardFrame = NSRect(x: topLeft.x, y: originY, width: width, height: targetHeight)
        }
        animateFrame(of: mainPanel, to: paddedWindowFrame(for: newCardFrame), duration: 0.20)
    }

    func finishManualResize() {
        if isCornerMiniMode, let miniPanel {
            if PinnedRemindersStore.shared.activeTab != .pomodoro {
                customMiniListSize = cardFrame(from: miniPanel.frame).size
            }
            return
        }
        guard let mainPanel else { return }
        expandedCardFrameBeforeSpecialMode = cardFrame(from: mainPanel.frame)
        persistCurrentFrame(for: mainPanel)
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticFrameUpdate else { return }
        guard let window = notification.object as? NSPanel, window === mainPanel else { return }
        expandedCardFrameBeforeSpecialMode = cardFrame(from: window.frame)
        persistCurrentFrame(for: window)
    }

    func windowDidResize(_ notification: Notification) {
        guard !isProgrammaticFrameUpdate else { return }
        guard let window = notification.object as? NSPanel else { return }
        if window === miniPanel {
            if PinnedRemindersStore.shared.activeTab != .pomodoro {
                customMiniListSize = cardFrame(from: window.frame).size
            }
            return
        }
        if window === mainPanel {
            if !PinnedRemindersStore.shared.isCollapsed {
                expandedCardFrameBeforeSpecialMode = cardFrame(from: window.frame)
            }
            persistCurrentFrame(for: window)
        }
    }

    // MARK: - Panel creation

    private func ensureMainPanel() -> PinnedFloatingPanel {
        if let existing = mainPanel {
            return existing
        }

        let initialCardFrame = restoredCardFrame()
        expandedCardFrameBeforeSpecialMode = initialCardFrame
        let initialWindowFrame = paddedWindowFrame(for: initialCardFrame)

        let newPanel = PinnedFloatingPanel(
            contentRect: initialWindowFrame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.title = AppConstants.appName
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        // Disable WindowServer's dynamic alpha-mask shadow so GPU layer transitions run at locked 120Hz;
        // crisp drop shadow is rendered inside the padded card layer.
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.isMovableByWindowBackground = false
        newPanel.isReleasedWhenClosed = false
        applyMainWindowLevel(to: newPanel)
        newPanel.minSize = paddedSize(for: Self.minExpandedSize)
        newPanel.maxSize = paddedSize(for: Self.maxExpandedSize)
        newPanel.delegate = self

        let hostingView = ShadowPassthroughHostingView(rootView: PinnedPanelView())
        hostingView.wantsLayer = true
        hostingView.frame = NSRect(origin: .zero, size: initialWindowFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostingView

        isProgrammaticFrameUpdate = true
        newPanel.setFrame(initialWindowFrame, display: false)
        isProgrammaticFrameUpdate = false

        self.mainPanel = newPanel
        return newPanel
    }

    private func ensureMiniPanel(for tab: BoardTab) -> PinnedFloatingPanel {
        if let existing = miniPanel {
            return existing
        }

        let visibleFrame = defaultScreenVisibleFrame()
        let size = miniSize(for: tab)
        let initialCardFrame = NSRect(
            x: visibleFrame.maxX - size.width - Self.cornerInset,
            y: visibleFrame.maxY - size.height - Self.cornerInset,
            width: size.width,
            height: size.height
        )
        let initialWindowFrame = paddedWindowFrame(for: initialCardFrame)

        let newPanel = PinnedFloatingPanel(
            contentRect: initialWindowFrame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "\(AppConstants.appName) 小窗"
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.hidesOnDeactivate = false
        newPanel.isMovableByWindowBackground = false
        newPanel.isReleasedWhenClosed = false
        configureMiniConstraints(for: tab, on: newPanel, cardWidth: size.width)
        newPanel.delegate = self

        let hostingView = ShadowPassthroughHostingView(rootView: CornerMiniWindowView())
        hostingView.wantsLayer = true
        hostingView.frame = NSRect(origin: .zero, size: initialWindowFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        newPanel.contentView = hostingView

        isProgrammaticFrameUpdate = true
        newPanel.setFrame(initialWindowFrame, display: false)
        isProgrammaticFrameUpdate = false

        self.miniPanel = newPanel
        return newPanel
    }

    // MARK: - Frame helpers

    private func persistCurrentFrame(for panel: NSPanel) {
        var frameToSave = cardFrame(from: panel.frame)
        if PinnedRemindersStore.shared.isCollapsed {
            let expandedHeight = max(Self.minExpandedSize.height, expandedCardFrameBeforeSpecialMode?.height ?? Self.defaultSize.height)
            frameToSave.origin.y = frameToSave.maxY - expandedHeight
            frameToSave.size.height = expandedHeight
        }
        UserPreferences.shared.pinnedPanelFrame = frameToSave
    }

    private func restoredCardFrame() -> NSRect {
        let visibleFrame = defaultScreenVisibleFrame()

        if let saved = UserPreferences.shared.pinnedPanelFrame {
            let width = max(Self.minExpandedSize.width, saved.width).constrainedTo(
                min: Self.minExpandedSize.width,
                max: Self.maxExpandedSize.width
            )
            let height = max(Self.minExpandedSize.height, saved.height).constrainedTo(
                min: Self.minExpandedSize.height,
                max: Self.maxExpandedSize.height
            )

            let targetScreen = NSScreen.screens.first { screen in
                screen.visibleFrame.contains(NSPoint(x: saved.midX, y: saved.maxY - 20))
            } ?? NSScreen.main

            let screenFrame = targetScreen?.visibleFrame ?? visibleFrame
            let originX = saved.minX.constrainedTo(
                min: screenFrame.minX,
                max: max(screenFrame.minX, screenFrame.maxX - width)
            )
            let originY = saved.minY.constrainedTo(
                min: screenFrame.minY,
                max: max(screenFrame.minY, screenFrame.maxY - height)
            )
            return NSRect(x: originX, y: originY, width: width, height: height)
        }

        let size = Self.defaultSize
        let originX = visibleFrame.maxX - size.width - Self.defaultScreenInset
        let originY = visibleFrame.maxY - size.height - Self.defaultScreenInset
        return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
    }

    private func currentVisibleFrame(for panel: NSPanel) -> NSRect {
        panel.screen?.visibleFrame ?? defaultScreenVisibleFrame()
    }

    private func defaultScreenVisibleFrame() -> NSRect {
        if let screen = AppDelegate.shared?.statusBarItem.button?.window?.screen {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
    }
}
