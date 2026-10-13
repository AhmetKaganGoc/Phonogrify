import AppKit
import Combine
import IOKit.ps
import PhonogrifyCore
import QuartzCore

/// A borderless, transparent window that never takes focus.
final class ClearPanel: NSPanel {
    init(takesMouse: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = !takesMouse
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The contents of a handle: an invisible patch of screen that takes the mouse.
///
/// The overlay itself lets every click through, always. What can be taken hold
/// of, the disc and the pin, each has one of these laid exactly over it in a
/// small window of its own. The system then tells the app when the pointer
/// arrives and when a button goes down there, and the app never has to watch
/// the pointer move across the rest of the screen to find out.
final class HandleView: NSView {
    var cursor = NSCursor.openHand
    var onDown: (() -> Void)?
    var onDragged: (() -> Void)?
    var onUp: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onDown?() }
    override func mouseDragged(with event: NSEvent) { onDragged?() }
    override func mouseUp(with event: NSEvent) { onUp?() }
    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) { cursor.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Active always: this window is never key and its app is never in front.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }
}

enum Power {
    /// Whether the Mac is running off its battery.
    static var isOnBattery: Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
        return source == kIOPMBatteryPowerKey
    }

    /// The most frames a second worth asking for. A swinging disc at a hundred
    /// and twenty frames is a pleasure on mains power; on battery it is sixty,
    /// and in Low Power Mode thirty.
    static var frameCeiling: Float {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return 30 }
        return isOnBattery ? 60 : 120
    }
}

/// Owns the overlay: where it is, what hangs in it, and what the hand does to it.
///
/// Frames are only asked for while something is physically moving: the disc
/// swinging, the cord being reeled, the disc held. Settled, there is no clock,
/// no timer, no polling and no watching of the pointer.
@MainActor
final class Overlay: NSObject {
    enum Metrics {
        /// The standard cord and disc, in points, before the user's sliders.
        static let rope = 250.0
        static let radius = 34.0
        /// How far in from the screen's sides the cord can be hung.
        static let margin = 48.0
        /// The most a downward pull draws the cord out, and how long it takes
        /// to go back in when let go. Slow enough that the disc is lowered
        /// back up, not flicked.
        static let give = 10.0
        static let giveReturn = 0.24
        static let grabPadding = 9.0
        static let pinReach = 13.0
    }

    private struct Layout: Equatable {
        var size: CGSize
        /// How far below the top of the screen the window's own top is.
        var lowered: Double
        var anchor: CGPoint
        var rope: Double
        var radius: Double
        var scale: Double
        var showsPin: Bool
    }

    private enum Hold {
        case none
        case disc
        case pin
    }

    private let settings: Settings
    private let spotify: SpotifyBridge
    private let covers: CoverStore

    private var panel: ClearPanel?
    private let stage = Stage(frame: .zero)
    private let discHandle = ClearPanel(takesMouse: true)
    private let pinHandle = ClearPanel(takesMouse: true)
    private var discHandleCentre = CGPoint(x: -1, y: -1)

    private var layout: Layout?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var frameCeiling: Float = 120
    private var subscriptions: Set<AnyCancellable> = []

    private var pendulum = Pendulum(anchor: .zero, cordLength: Metrics.rope, radius: Metrics.radius)
    private var loops = LoopCounter()
    private var tug = TugDetector()
    private var reel = Reel(isDown: false)
    private var give = 0.0

    private var hold = Hold.none
    private var grabOffset = CGPoint.zero
    private var samples: [(time: TimeInterval, point: CGPoint)] = []
    private var recentSpeed = 0.0

    /// Whether the disc should be down: there is a track to hang, and its
    /// record has been cut. Until then there is nothing to let down.
    private var wantsDown: Bool {
        hasDisc && spotify.nowPlaying.hanging != nil
    }

    private var hasDisc = false
    private var discKey: String?
    private var shownTrackID: String?
    /// The order tracks have played in, for telling a step back from a step on,
    /// and which way the step into the playing track was.
    private var trail = Trail()
    private var steps: [String: Trail.Step] = [:]

    init(settings: Settings, spotify: SpotifyBridge, covers: CoverStore) {
        self.settings = settings
        self.spotify = spotify
        self.covers = covers
        super.init()
    }

    func start() {
        let disc = HandleView()
        disc.onDown = { [weak self] in self?.discPressed() }
        disc.onDragged = { [weak self] in self?.discDragged() }
        disc.onUp = { [weak self] in self?.discReleased() }
        discHandle.contentView = disc

        let pin = HandleView()
        pin.cursor = .resizeLeftRight
        pin.onDown = { [weak self] in self?.hold = .pin }
        pin.onDragged = { [weak self] in self?.pinDragged() }
        pin.onUp = { [weak self] in self?.hold = .none }
        pinHandle.contentView = pin

        settings.onChange = { [weak self] in self?.apply() }
        spotify.$nowPlaying
            .removeDuplicates()
            .sink { [weak self] in self?.musicChanged($0) }
            .store(in: &subscriptions)

        NotificationCenter.default.addObserver(
            self, selector: #selector(surroundingsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(surroundingsChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(powerChanged),
            name: .NSProcessInfoPowerStateDidChange, object: nil
        )
        apply()
    }

    @objc private func surroundingsChanged() {
        layout = nil
        apply()
    }

    /// Low Power Mode was switched: the ring turns or stops to suit.
    @objc private func powerChanged() {
        Task { @MainActor [weak self] in self?.stage.ensureSpin() }
    }

    // MARK: - Placement

    private var isGrabbable: Bool { reel.presence > 0.5 && panel != nil && settings.showsOverlay }
    private var restReach: Double { (layout?.rope ?? Metrics.rope) + (layout?.radius ?? Metrics.radius) }

    private func makeLayout(on screen: NSScreen) -> Layout {
        let rope = Metrics.rope * settings.ropeLength
        let radius = Metrics.radius * settings.discSize
        // From the very top of the screen, or from under the menu bar. With a
        // pin, a few points lower, so the whole pin shows.
        let menuBar = max(0, screen.frame.maxY - screen.visibleFrame.maxY)
        let top = (settings.hangsBelowMenuBar ? menuBar : 0) + (settings.showsPin ? 4 : 0)
            + settings.drop * screen.frame.height
        // Only as large as the disc can reach: transparent area still costs.
        // Hung lower down the screen, that includes the room above the anchor
        // that a loop goes through.
        let half = rope + radius * 2.4 + 24
        let above = min(top, half)
        let height = above + rope + radius * 2.4 + 60
        return Layout(
            size: CGSize(width: half * 2, height: height),
            lowered: top - above,
            anchor: CGPoint(x: half, y: above),
            rope: rope,
            radius: radius,
            scale: screen.backingScaleFactor,
            showsPin: settings.showsPin
        )
    }

    /// Brings the windows into line with the settings.
    func apply() {
        guard settings.showsOverlay, let screen = NSScreen.screens.first else {
            stopLink()
            panel?.orderOut(nil)
            return
        }

        let panel = self.panel ?? makePanel()
        let level = settings.staysBehindWindows
            ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            : .statusBar
        let behavior: NSWindow.CollectionBehavior = [
            .stationary, .ignoresCycle, .canJoinAllSpaces,
            settings.hidesInFullScreen ? .fullScreenNone : .fullScreenAuxiliary
        ]
        for window in [panel, discHandle, pinHandle] {
            window.level = level
            window.collectionBehavior = behavior
        }

        let next = makeLayout(on: screen)
        let span = screen.frame.width - Metrics.margin * 2
        let anchorX = screen.frame.minX + Metrics.margin + settings.position * span
        let origin = CGPoint(
            x: anchorX - next.size.width / 2,
            y: screen.frame.maxY - next.lowered - next.size.height
        )

        if next != layout {
            layout = next
            panel.setFrame(CGRect(origin: origin, size: next.size), display: false)
            stage.frame = CGRect(origin: .zero, size: next.size)
            stage.configure(size: next.size, radius: next.radius, scale: next.scale, showsPin: next.showsPin)
            pendulum.anchor = next.anchor
            // The stage has a new size, so the handles have to be laid again.
            discHandleCentre = CGPoint(x: -1, y: -1)
            updateReach()
            if pendulum.isAsleep {
                pendulum.settle()
            }
        } else {
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        stage.ensureSpin()
        showProgress()
        render()
        startLinkIfNeeded()
    }

    private func makePanel() -> ClearPanel {
        let panel = ClearPanel(takesMouse: false)
        panel.contentView = stage
        // Children of the overlay: they go where it goes and show when it shows.
        panel.addChildWindow(discHandle, ordered: .above)
        panel.addChildWindow(pinHandle, ordered: .above)
        self.panel = panel
        return panel
    }

    private func updateReach() {
        guard let layout else { return }
        pendulum.radius = layout.radius
        pendulum.cordLength = layout.rope * reel.length + give
    }

    /// Lays each handle over the thing it is the handle of.
    private func placeHandles() {
        guard let panel, let layout else { return }
        let canGrab = isGrabbable
        if discHandle.ignoresMouseEvents == canGrab {
            discHandle.ignoresMouseEvents = !canGrab
        }
        let pinLive = canGrab && layout.showsPin
        if pinHandle.ignoresMouseEvents == pinLive {
            pinHandle.ignoresMouseEvents = !pinLive
        }

        // Moving a window is a call to the window server, so the disc's handle
        // only follows it once it has gone a point or more.
        let centre = pendulum.position
        if (centre - discHandleCentre).length >= 1 {
            discHandleCentre = centre
            let side = (layout.radius + Metrics.grabPadding) * 2
            discHandle.setFrame(screenRect(centre: centre, width: side, height: side, in: panel), display: false)
        }
        let pinSide = Metrics.pinReach * 2
        let pinFrame = screenRect(centre: layout.anchor, width: pinSide, height: pinSide, in: panel)
        if pinHandle.frame != pinFrame {
            pinHandle.setFrame(pinFrame, display: false)
        }
    }

    /// A rectangle on screen for one given in the stage's own points.
    private func screenRect(centre: CGPoint, width: Double, height: Double, in panel: NSWindow) -> CGRect {
        CGRect(
            x: panel.frame.minX + centre.x - width / 2,
            y: panel.frame.maxY - centre.y - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Music

    private func musicChanged(_ now: NowPlaying) {
        stage.setSpinning(now.state == .playing)
        stage.setProgress(now.hanging == nil ? nil : now.progress(), isPlaying: now.state == .playing)
        if let track = now.hanging {
            // Read the moment Spotify says so, not when the record is finally
            // shown: a quick run of skips shows only its last.
            let evidence = evidence(forChangeTo: track, in: now)
            if let step = trail.move(to: track.id, evidence: evidence) {
                steps = [track.id: step]
            }
            let key = track.id + "|" + (track.artworkURL?.absoluteString ?? "")
            if key != discKey {
                discKey = key
                hang(track, key: key)
            }
        }
        // `sink` is told before the value is stored; look again once it is.
        Task { @MainActor [weak self] in self?.startLinkIfNeeded() }
    }

    /// Puts the progress bar where the track has got to. Needed again whenever
    /// the stage is rebuilt, which starts its animations afresh.
    private func showProgress() {
        let now = spotify.nowPlaying
        stage.setProgress(now.hanging == nil ? nil : now.progress(), isPlaying: now.state == .playing)
    }

    private func hang(_ track: Track, key: String) {
        let side = Int(Metrics.radius * 1.4 * 2 * 2.5)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Spotify announces a track before saying where its cover is. Wait
            // a moment for that rather than hang a plain record and swap it.
            if track.artworkURL == nil, self.spotify.isPermitted {
                try? await Task.sleep(for: .milliseconds(700))
                guard self.discKey == key else { return }
            }
            let cover = await self.covers.cover(for: track)
            guard self.discKey == key, let image = Artist.disc(cover: cover, seed: track.id, side: side) else { return }

            let isNewTrack = track.id != self.shownTrackID
            // Out of sight it is simply changed; in view it turns over, onward
            // or back by which way the music went.
            let inView = isNewTrack && self.reel.presence > 0.5
            let step = self.steps[track.id] ?? .onward
            self.stage.setDisc(image, flip: inView ? (step == .back ? .back : .onward) : nil)
            self.hasDisc = true
            self.startLinkIfNeeded()
            guard isNewTrack else { return }
            self.shownTrackID = track.id
            self.stage.showCaption(title: track.title, artist: track.artist, seconds: 3)
        }
    }

    /// What can be told about a change to `track`, from how the track before
    /// it stood. Called while `spotify.nowPlaying` is still that earlier state:
    /// a published value is announced before it is stored.
    private func evidence(forChangeTo track: Track, in now: NowPlaying) -> Trail.Evidence {
        let before = spotify.nowPlaying
        let progress = before.progress()
        let elapsed = progress.flatMap { reached in before.track?.duration.map { reached.fraction * $0 } }

        guard track.id != trail.current else {
            // The same track, back at its start from well in: one press of Previous.
            if let elapsed, elapsed > trail.previousWindow, let position = now.position, position < 2 {
                trail.restarted()
            }
            return Trail.Evidence()
        }

        var evidence = Trail.Evidence(previousElapsed: elapsed)
        if let skip = spotify.takeRecentSkip() {
            evidence.asked = skip == .previous ? .back : .onward
        }
        evidence.previousEnded = before.state == .playing && (progress?.remaining ?? .infinity) < 2.5
        if let old = before.track, !old.album.isEmpty, old.album == track.album,
           let oldNumber = old.trackNumber, let newNumber = track.trackNumber {
            let oldPlace = (old.discNumber ?? 1) * 1000 + oldNumber
            let newPlace = (track.discNumber ?? 1) * 1000 + newNumber
            evidence.albumOrder = newPlace - oldPlace
        }
        return evidence
    }

    // MARK: - Frames

    private var needsFrames: Bool {
        guard panel != nil, settings.showsOverlay else { return false }
        return !pendulum.isAsleep || pendulum.isHeld || give > 0 || reel.isDown != wantsDown
    }

    private func startLinkIfNeeded() {
        guard needsFrames, link == nil else { return }
        // Asked once per burst of movement, not per frame.
        frameCeiling = Power.frameCeiling
        let link = stage.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = range(upTo: frameCeiling)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = nil
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        lastTick = nil
        recentSpeed = 0
    }

    private func range(upTo rate: Float) -> CAFrameRateRange {
        let top = min(rate, frameCeiling)
        return CAFrameRateRange(minimum: max(15, top / 2), maximum: top, preferred: top)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let elapsed = min(0.05, max(0, now - (lastTick ?? now)))
        lastTick = now

        // The cord is let out or hauled in, and the disc goes with it.
        var isReeling = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if reel.isDown != wantsDown {
                reel.jump(down: wantsDown)
                isReeling = true
            }
        } else {
            isReeling = reel.advance(by: elapsed, down: wantsDown)
        }
        // Let go, a drawn-out cord goes back in over a quarter of a second.
        if !pendulum.isHeld, give > 0 {
            give = max(0, give - Metrics.give * elapsed / Metrics.giveReturn)
            isReeling = true
        }
        updateReach()
        if isReeling {
            pendulum.wake()
        }
        pendulum.advance(by: elapsed)

        if !pendulum.isHeld, loops.isCounting, let layout {
            if let turn = loops.track(anchor: layout.anchor, disc: pendulum.position, reach: pendulum.reach) {
                looped(turn)
            }
            if pendulum.isAsleep {
                loops.end()
            }
        }

        render()
        setPace(elapsed: elapsed)
        if !needsFrames {
            stopLink()
        }
    }

    private func render() {
        guard let layout else { return }
        stage.place(
            anchor: layout.anchor,
            centre: pendulum.position,
            heading: pendulum.heading,
            cord: pendulum.cord.points
        )
        stage.setPresence(reel.presence * settings.opacity)
        placeHandles()
    }

    /// Full rate only while the disc is fast. A swing that has lost its speed
    /// looks the same at half the frames, and the last of it at a quarter.
    private func setPace(elapsed: Double) {
        guard let link else { return }
        recentSpeed = max(pendulum.velocity.length, recentSpeed * exp(-elapsed / 0.5))
        let wanted: CAFrameRateRange
        if pendulum.isHeld || recentSpeed >= 400 || reel.isDown != wantsDown {
            wanted = range(upTo: 120)
        } else if recentSpeed >= 70 {
            wanted = range(upTo: 60)
        } else {
            wanted = range(upTo: 30)
        }
        if link.preferredFrameRateRange != wanted {
            link.preferredFrameRateRange = wanted
        }
    }

    private func looped(_ turn: Turn) {
        settings.count(loops: 1)
        // However many times a hard throw goes round, it asked once.
        if loops.loopsThisThrow == 1 {
            spotify.send(Remote.command(for: turn))
        }
        if settings.glintsOnLoop {
            stage.glint()
        }
    }

    // MARK: - The hand

    /// Where the pointer is, in the stage's own points.
    private var pointer: CGPoint? {
        guard let panel else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
    }

    private func discPressed() {
        guard isGrabbable, let layout, let point = pointer else { return }
        // The handle is square and the disc is round: its corners are not the disc.
        guard (point - pendulum.position).length <= layout.radius + Metrics.grabPadding else { return }

        hold = .disc
        NSCursor.closedHand.set()
        grabOffset = pendulum.position - point
        samples = [(ProcessInfo.processInfo.systemUptime, point)]
        loops.end()
        tug.grab(target: pendulum.position, anchor: layout.anchor, disc: pendulum.position, reach: restReach)
        pendulum.hold(at: pendulum.position)
        if !stage.isCaptionShowing, let track = spotify.nowPlaying.hanging {
            stage.showCaption(title: track.title, artist: track.artist, seconds: 1.2)
        }
        startLinkIfNeeded()
    }

    private func discDragged() {
        guard hold == .disc, let layout, let point = pointer else { return }
        let target = point + grabOffset
        let now = ProcessInfo.processInfo.systemUptime
        samples.append((now, point))
        samples.removeAll { now - $0.time > 0.09 }
        tug.drag(target: target, anchor: layout.anchor, reach: restReach)
        give = PullCord.give(target: target, anchor: layout.anchor, reach: restReach, most: Metrics.give)
        updateReach()
        pendulum.hold(at: target)
    }

    private func discReleased() {
        guard hold == .disc, let layout else { return }
        hold = .none
        NSCursor.openHand.set()
        var velocity = handVelocity
        if tug.release(velocity: velocity) {
            spotify.send(.playPause)
            // A tug is let go of, not thrown: the hand's rebound is not passed on.
            velocity = .zero
        }
        // The shorter the cord, the more help a flick needs to become a swing.
        let assist = ((1 - settings.ropeLength) / 0.6).clamped(to: 0...1)
        pendulum.release(velocity: velocity, assist: assist)
        loops.begin(anchor: layout.anchor, disc: pendulum.position)
        if velocity.length > 350 {
            settings.count(throws: 1)
        }
        startLinkIfNeeded()
    }

    private func pinDragged() {
        guard hold == .pin, let screen = NSScreen.screens.first else { return }
        let span = screen.frame.width - Metrics.margin * 2
        let along = (NSEvent.mouseLocation.x - screen.frame.minX - Metrics.margin) / span
        settings.position = along.clamped(to: 0...1)
    }

    /// The hand's speed over the last few moments of the drag.
    private var handVelocity: CGPoint {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.008 else { return .zero }
        return (last.point - first.point) / (last.time - first.time)
    }
}
