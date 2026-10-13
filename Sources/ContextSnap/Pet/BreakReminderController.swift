import AppKit
import Combine
import SwiftUI

/// Watches how long the user has been at the keyboard without a break and
/// sends a small pet to the middle of the screen when it is time to get up.
///
/// "At the keyboard" is measured from the system-wide idle clock, so time
/// spent away from the machine counts as the break itself — the reminder
/// never fires just because the app was left running overnight.
@MainActor
final class BreakReminderController {
    static let shared = BreakReminderController()

    /// How often the work clock advances. Coarse on purpose: this runs all day.
    private static let tick: TimeInterval = 15
    /// Idle time that counts as a real break and resets the work clock.
    private static let awayResetsAfter: TimeInterval = 180
    /// An ignored pet wanders off after this long and tries again later.
    private static let nudgeTimeout: TimeInterval = 60
    private static let snooze: TimeInterval = 5 * 60
    private static let panelSize = NSSize(width: 292, height: 288)

    private let settings = SettingsStore.shared
    private let model = PetModel()
    private var panel: NSPanel?
    private var workClock: TimeInterval = 0
    private var snoozedUntil: Date?
    private var breakEndsAt: Date?
    private var previewing = false
    private var tickTimer: Timer?
    private var petTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        model.onRest = { [weak self] in self?.startBreak() }
        model.onSnooze = { [weak self] in self?.snoozeNudge() }
        model.onBackToWork = { [weak self] in self?.finishBreak(welcome: false) }
        model.onDismiss = { [weak self] in self?.dismiss() }
    }

    func start() {
        settings.$breakReminderEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.applyEnabled(enabled) }
            .store(in: &cancellables)

        // A changed interval should take effect against the time already
        // worked, not start the day over.
        settings.$breakIntervalMinutes
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.snoozedUntil = nil }
            .store(in: &cancellables)
    }

    /// Shows the pet right now without touching the work clock, so the user
    /// can see what the reminder looks like from Settings.
    func preview() {
        previewing = true
        presentNudge(minutes: settings.breakIntervalMinutes)
    }

    // MARK: Clock

    private func applyEnabled(_ enabled: Bool) {
        tickTimer?.invalidate()
        tickTimer = nil
        guard enabled else {
            if !previewing { hidePanel() }
            return
        }
        workClock = 0
        snoozedUntil = nil
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickWorkClock() }
        }
        timer.tolerance = Self.tick / 3
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func tickWorkClock() {
        guard settings.breakReminderEnabled else { return }
        // The pet is already on screen (or the user is mid-break): the clock
        // restarts when it leaves, not while it is being shown.
        guard panel == nil || panel?.isVisible != true else { return }

        let idle = Self.systemIdleSeconds()
        if idle >= Self.awayResetsAfter {
            workClock = 0
            snoozedUntil = nil
            return
        }
        // Idle stretches shorter than a break still aren't work.
        guard idle < Self.tick else { return }
        workClock += Self.tick

        if let until = snoozedUntil {
            guard Date() >= until else { return }
            snoozedUntil = nil
        }
        guard workClock >= TimeInterval(settings.breakIntervalMinutes) * 60 else { return }
        presentNudge(minutes: Int(workClock / 60))
    }

    /// Seconds since the last keyboard/mouse/trackpad event anywhere in the
    /// session. Needs no accessibility permission.
    private static func systemIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: Pet states

    private func presentNudge(minutes: Int) {
        model.mood = .nudge
        model.headline = "You've been at it for \(max(minutes, 1)) min"
        model.detail = "Stand up, roll your shoulders, look out the window."
        showPanel()
        schedulePetTimer(after: Self.nudgeTimeout) { [weak self] in
            // Ignored — slip away quietly and come back later.
            self?.snoozeNudge()
        }
    }

    private func startBreak() {
        let seconds = max(settings.breakLengthMinutes, 1) * 60
        breakEndsAt = Date().addingTimeInterval(TimeInterval(seconds))
        model.mood = .resting
        model.remaining = seconds
        updateBreakCountdown()
        schedulePetTimer(after: 1, repeats: true) { [weak self] in
            self?.updateBreakCountdown()
        }
    }

    private func updateBreakCountdown() {
        guard let endsAt = breakEndsAt else { return }
        let left = Int(endsAt.timeIntervalSinceNow.rounded(.up))
        guard left > 0 else {
            finishBreak(welcome: true)
            return
        }
        model.remaining = left
        model.headline = "Stretching… \(left / 60):\(String(format: "%02d", left % 60))"
        model.detail = "Away from the screen is fine — I'll wait."
    }

    private func finishBreak(welcome: Bool) {
        breakEndsAt = nil
        guard welcome else {
            dismiss()
            return
        }
        model.mood = .happy
        model.headline = "Welcome back!"
        model.detail = "The clock starts over from here."
        schedulePetTimer(after: 3) { [weak self] in self?.dismiss() }
    }

    private func snoozeNudge() {
        snoozedUntil = Date().addingTimeInterval(Self.snooze)
        // Keep the work clock: the reminder is due again the moment the
        // snooze runs out.
        hidePanel()
    }

    private func dismiss() {
        workClock = 0
        snoozedUntil = nil
        hidePanel()
    }

    private func schedulePetTimer(after seconds: TimeInterval,
                                  repeats: Bool = false,
                                  action: @escaping () -> Void) {
        petTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: repeats) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        petTimer = timer
    }

    // MARK: Panel

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(Self.centeredFrame(), display: false)
        // orderFrontRegardless keeps the user's current app in front — the
        // pet appears without stealing focus from whatever they were typing.
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        previewing = false
        petTimer?.invalidate()
        petTimer = nil
        breakEndsAt = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu  // above fullscreen window content
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Let the user shove the pet aside instead of dismissing it.
        panel.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: PetPanelView(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Middle of the screen the user is working on. `NSScreen.main` is the
    /// one holding the active app's key window, which tracks attention better
    /// than the pointer — the mouse is often parked on a second display.
    private static func centeredFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Clamped, because a rotated or oddly-placed second display can put
        // the centre of one screen close enough to an edge that half the pet
        // would hang off it.
        let margin: CGFloat = 12
        let x = min(max(visible.midX - panelSize.width / 2, visible.minX + margin),
                    visible.maxX - panelSize.width - margin)
        let y = min(max(visible.midY - panelSize.height / 2, visible.minY + margin),
                    visible.maxY - panelSize.height - margin)
        return NSRect(origin: CGPoint(x: x, y: y), size: panelSize)
    }
}
