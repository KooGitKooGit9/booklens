import AppKit

/// Watches the mouse and modifier keys and fires when the user asks for a lookup.
/// Polls `NSEvent.mouseLocation` / `NSEvent.modifierFlags`, which needs no Accessibility permission.
final class TriggerMonitor {
    /// Called with the global Cocoa point to look up.
    var onTrigger: ((CGPoint) -> Void)?
    /// Called on every tick with the current mouse location and whether the trigger key is held.
    var onTick: ((CGPoint, Bool) -> Void)?

    private let settings: AppSettings
    private var timer: Timer?
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var stillSince = Date()
    private var firedAt: CGPoint?
    private var lastMoveSeen = Date()

    /// How long the mouse must rest while the modifier is held.
    var modifierSettleDelay: TimeInterval = 0.12
    /// Movement (points) that counts as "still".
    var stillnessTolerance: CGFloat = 3

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Forget the last fired point so the same spot can trigger again.
    func reset() {
        firedAt = nil
    }

    /// Current modifier keys. CGEventSource state is readable without Accessibility/Input Monitoring permission.
    static var currentFlags: NSEvent.ModifierFlags {
        let cg = CGEventSource.flagsState(.combinedSessionState)
        var flags: NSEvent.ModifierFlags = []
        if cg.contains(.maskAlternate) { flags.insert(.option) }
        if cg.contains(.maskControl) { flags.insert(.control) }
        if cg.contains(.maskCommand) { flags.insert(.command) }
        if cg.contains(.maskShift) { flags.insert(.shift) }
        return flags
    }

    var isModifierHeld: Bool {
        Self.isHeld(settings.triggerMode, flags: Self.currentFlags)
    }

    static func isHeld(_ mode: TriggerMode, flags: NSEvent.ModifierFlags) -> Bool {
        let relevant = flags.intersection([.option, .control, .command, .shift])
        switch mode {
        case .optionHover: return relevant == .option
        case .controlHover: return relevant == .control
        case .dwell: return false
        }
    }

    private func tick() {
        let point = NSEvent.mouseLocation
        let now = Date()
        let held = isModifierHeld
        onTick?(point, held)

        if hypot(point.x - lastPoint.x, point.y - lastPoint.y) > stillnessTolerance {
            lastPoint = point
            stillSince = now
            lastMoveSeen = now
            return
        }
        guard settings.enabled else { return }

        let delay: TimeInterval
        switch settings.triggerMode {
        case .optionHover, .controlHover:
            guard held else { firedAt = nil; return }
            delay = modifierSettleDelay
        case .dwell:
            // Do not fire while any modifier or mouse button is down (dragging, shortcuts).
            guard NSEvent.pressedMouseButtons == 0,
                  Self.currentFlags.isEmpty else { return }
            delay = settings.dwellDelay
        }
        guard now.timeIntervalSince(stillSince) >= delay else { return }
        if let firedAt, hypot(point.x - firedAt.x, point.y - firedAt.y) <= stillnessTolerance { return }
        firedAt = point
        onTrigger?(point)
    }
}
