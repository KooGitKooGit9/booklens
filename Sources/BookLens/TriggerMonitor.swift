import AppKit

/// Watches the mouse and modifier keys and fires when the user asks for a lookup.
/// Polls `NSEvent.mouseLocation` / `NSEvent.modifierFlags`, which needs no Accessibility permission.
final class TriggerMonitor {
    /// Called with the global Cocoa point to look up.
    var onTrigger: ((CGPoint) -> Void)?
    /// Called on every tick with the current mouse location and whether the trigger key is held.
    var onTick: ((CGPoint, Bool) -> Void)?
    /// Called when the mouse starts sweeping across text with the trigger key held.
    var onSweepBegan: (() -> Void)?
    /// Called with the mouse path (global Cocoa points) when the key is released after a sweep.
    var onSweepEnded: (([CGPoint]) -> Void)?
    /// Whether `point` is still on the word (or popup) of the current lookup, so moving there is not a sweep;
    /// nil when no word is shown.
    var isOnCurrentLookup: ((CGPoint) -> Bool?)?

    private let settings: AppSettings
    private var timer: Timer?
    /// Keeps App Nap from throttling the polling timer while the app sits idle in the menu bar.
    private var activity: NSObjectProtocol?
    /// Input events wake an idle (napping) app and run a check right away, in case the timer was throttled.
    private var wakeMonitor: Any?
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var stillSince = Date()
    private var firedAt: CGPoint?
    private var lastMoveSeen = Date()
    private var lastTick = Date()
    private var pressOrigin: CGPoint?
    private var sweepPath: [CGPoint] = []
    private var sweeping = false

    /// How long the mouse must rest while the modifier is held.
    var modifierSettleDelay: TimeInterval = 0.12
    /// Movement (points) that counts as "still".
    var stillnessTolerance: CGFloat = 3
    /// Movement with the key held that starts a sentence sweep once the mouse is off the looked-up word.
    var sweepDistance: CGFloat = 12
    /// Movement that starts a sweep when no word is shown yet.
    var sweepDistanceWithoutWord: CGFloat = 40

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Watching for the lookup key")
        // Mouse events need no permission; flagsChanged only arrives if Input Monitoring is granted, which is fine.
        wakeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .flagsChanged]) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if let wakeMonitor { NSEvent.removeMonitor(wakeMonitor) }
        wakeMonitor = nil
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
        // Diagnostic: a long gap between ticks means the timer was throttled or the Mac slept.
        let gap = now.timeIntervalSince(lastTick)
        if gap > 1 { log.info("Trigger timer resumed after \(Int(gap))s gap") }
        lastTick = now
        let held = isModifierHeld
        onTick?(point, held)
        if settings.enabled, settings.triggerMode != .dwell, trackSweep(point, held: held) { return }

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

    /// Holding the key and moving across text sweeps a sentence; releasing the key translates it.
    /// Returns true while a sweep is in progress, which pauses word lookups.
    private func trackSweep(_ point: CGPoint, held: Bool) -> Bool {
        guard held else {
            defer { pressOrigin = nil; sweepPath = []; sweeping = false }
            if sweeping { onSweepEnded?(sweepPath) }
            return sweeping
        }
        guard let origin = pressOrigin else {
            pressOrigin = point
            sweepPath = [point]
            return false
        }
        if let last = sweepPath.last, hypot(point.x - last.x, point.y - last.y) > 2 { sweepPath.append(point) }
        if !sweeping {
            let distance = hypot(point.x - origin.x, point.y - origin.y)
            let onWord = isOnCurrentLookup?(point) ?? nil
            if onWord == false ? distance > sweepDistance : (onWord == nil && distance > sweepDistanceWithoutWord) {
                sweeping = true
                onSweepBegan?()
            }
        }
        return sweeping
    }
}
