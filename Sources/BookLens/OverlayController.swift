import AppKit
import Combine
import SwiftUI

/// A borderless panel that floats above other apps (including full-screen ones) without taking focus.
final class FloatingPanel: NSPanel {
    init(clickThrough: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = !clickThrough
        ignoresMouseEvents = clickThrough
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons in the popup respond to the first click without activating BookLens.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct HighlightView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.accentColor.opacity(0.22))
            .overlay(
                Rectangle()
                    .fill(Color.accentColor.opacity(0.9))
                    .frame(height: 2),
                alignment: .bottom
            )
    }
}

/// Shows the definition popup next to a word and a highlight over the word itself.
final class OverlayController {
    let state = PopupState()
    private let popup = FloatingPanel(clickThrough: false)
    private let highlight = FloatingPanel(clickThrough: true)
    private var hosting: FirstMouseHostingView<PopupView>!
    private var wordRect: CGRect = .zero
    private var placedBelow = true
    private var mouseDownMonitor: Any?
    private var stateObserver: AnyCancellable?

    var isVisible: Bool { popup.isVisible }
    var popupFrame: CGRect { popup.frame }
    /// The word currently highlighted, in global Cocoa coordinates.
    var currentWordRect: CGRect { wordRect }

    init() {
        hosting = FirstMouseHostingView(rootView: PopupView(state: state))
        hosting.sizingOptions = []
        popup.contentView = hosting
        highlight.contentView = NSHostingView(rootView: HighlightView())
        stateObserver = state.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.resizeToFit() }
        }
    }

    /// Shows the popup for a word located at `rect` (global Cocoa coordinates).
    func show(at rect: CGRect) {
        wordRect = rect
        let padded = rect.insetBy(dx: -2, dy: -1)
        highlight.setFrame(padded, display: true)
        highlight.orderFrontRegardless()
        placePopup()
        popup.orderFrontRegardless()
        installMouseDownMonitor()
    }

    func hide() {
        popup.orderOut(nil)
        highlight.orderOut(nil)
        if let m = mouseDownMonitor {
            NSEvent.removeMonitor(m)
            mouseDownMonitor = nil
        }
    }

    /// True if `point` is close to the word or inside the popup, so the popup should stay open.
    func isNear(_ point: CGPoint, margin: CGFloat = 36) -> Bool {
        guard isVisible else { return false }
        if popup.frame.insetBy(dx: -8, dy: -8).contains(point) { return true }
        // The corridor between the word and the popup, so the mouse can travel onto the popup.
        let corridor = wordRect.union(popup.frame)
        if corridor.contains(point), point.x >= popup.frame.minX, point.x <= popup.frame.maxX { return true }
        return wordRect.insetBy(dx: -margin, dy: -margin * 0.6).contains(point)
    }

    private func installMouseDownMonitor() {
        guard mouseDownMonitor == nil else { return }
        // Global monitors for mouse clicks do not need Accessibility permission.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            guard let self else { return }
            if !self.popup.frame.contains(NSEvent.mouseLocation) { self.hide() }
        }
    }

    private func fittingSize() -> CGSize {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        return CGSize(width: PopupView.width, height: max(40, ceil(size.height)))
    }

    private func placePopup() {
        let size = fittingSize()
        let screen = NSScreen.screens.first { $0.frame.intersects(wordRect) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8
        var x = wordRect.minX - 14
        x = min(max(x, screen.minX + 6), screen.maxX - size.width - 6)
        let spaceBelow = wordRect.minY - screen.minY
        placedBelow = spaceBelow >= size.height + gap + 6 || spaceBelow > screen.maxY - wordRect.maxY
        var y = placedBelow ? wordRect.minY - gap - size.height : wordRect.maxY + gap
        y = min(max(y, screen.minY + 6), screen.maxY - size.height - 6)
        popup.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func resizeToFit() {
        guard popup.isVisible else { return }
        let size = fittingSize()
        var frame = popup.frame
        guard abs(frame.height - size.height) > 0.5 else { return }
        if placedBelow {
            frame.origin.y = frame.maxY - size.height // grow downward, keep top edge
        }
        frame.size = size
        if let screen = popup.screen?.visibleFrame, frame.minY < screen.minY + 6 {
            frame.origin.y = screen.minY + 6
        }
        popup.setFrame(frame, display: true)
    }
}
