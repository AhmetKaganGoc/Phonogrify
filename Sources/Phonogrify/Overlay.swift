import AppKit
import Combine
import PhonogrifyCore
import QuartzCore

/// The transparent window the cord hangs in. It never takes focus.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the overlay: where it is, what hangs in it, and what the hand does to it.
///
/// Frames are only asked for while something is physically moving: the disc
/// swinging, the cord being reeled, the disc held. Settled, there is no clock,
/// no timer and no polling; the pointer is noticed because the system reports
/// that it moved.
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

    private var panel: OverlayPanel?
    private let stage = Stage(frame: .zero)
    private var layout: Layout?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var watchers: [Any] = []
    private var subscriptions: Set<AnyCancellable> = []

    private var pendulum = Pendulum(anchor: .zero, cordLength: Metrics.rope, radius: Metrics.radius)
    private var loops = LoopCounter()
    private var tug = TugDetector()
    private var reel = Reel(isDown: false)
    private var give = 0.0

    private var hold = Hold.none
    private var grabOffset = CGPoint.zero
    private var samples: [(time: TimeInterval, point: CGPoint)] = []
    private var cursor: NSCursor?
    private var recentSpeed = 0.0

    /// Whether the disc should be down: there is a track to hang, and its
    /// record has been cut. Until then there is nothing to let down.
    private var wantsDown: Bool {
        hasDisc && spotify.nowPlaying.hanging != nil
    }

    private var hasDisc = false
    private var discKey: String?
    private var shownTrackID: String?

    init(settings: Settings, spotify: SpotifyBridge, covers: CoverStore) {
        self.settings = settings
        self.spotify = spotify
        self.covers = covers
        super.init()
    }

    func start() {
        stage.onMouseDown = { [weak self] in self?.mouseDown($0) }
        stage.onMouseDragged = { [weak self] in self?.mouseDragged($0) }
        stage.onMouseUp = { [weak self] in self?.mouseUp($0) }

        settings.onChange = { [weak self] in self?.apply() }
        spotify.$nowPlaying
            .removeDuplicates()
            .sink { [weak self] in self?.musicChanged($0) }
            .store(in: &subscriptions)

        // The pointer is followed by being told it moved, not by looking for it.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.updateHover()
        }) {
            watchers.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.updateHover()
            return event
        }) {
            watchers.append(local)
        }

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(surroundingsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(surroundingsChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        apply()
    }

    @objc private func surroundingsChanged() {
        layout = nil
        apply()
    }

    // MARK: - Placement

    private var isGrabbable: Bool { reel.presence > 0.5 && panel != nil }
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

    /// Brings the window into line with the settings.
    func apply() {
        guard settings.showsOverlay, let screen = NSScreen.screens.first else {
            stopLink()
            setCursor(nil)
            panel?.orderOut(nil)
            return
        }

        let panel = self.panel ?? makePanel()
        panel.level = settings.staysBehindWindows
            ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            : .statusBar
        panel.collectionBehavior = [
            .stationary, .ignoresCycle, .canJoinAllSpaces,
            settings.hidesInFullScreen ? .fullScreenNone : .fullScreenAuxiliary
        ]

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
            updateReach()
            if pendulum.isAsleep {
                pendulum.settle()
            }
        } else {
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        stage.ensureSpin()
        render(elapsed: 0)
        startLinkIfNeeded()
    }

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel()
        panel.contentView = stage
        self.panel = panel
        return panel
    }

    private func updateReach() {
        guard let layout else { return }
        pendulum.radius = layout.radius
        pendulum.cordLength = layout.rope * reel.length + give
    }

    // MARK: - Music

    private func musicChanged(_ now: NowPlaying) {
        stage.setSpinning(now.state == .playing)
        if let track = now.hanging {
            let key = track.id + "|" + (track.artworkURL?.absoluteString ?? "")
            if key != discKey {
                discKey = key
                hang(track, key: key)
            }
        }
        // `sink` is told before the value is stored; look again once it is.
        Task { @MainActor [weak self] in self?.startLinkIfNeeded() }
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
            // Out of sight it is simply changed; in view it turns over.
            self.stage.setDisc(image, turning: isNewTrack && self.reel.presence > 0.5)
            self.hasDisc = true
            self.startLinkIfNeeded()
            guard isNewTrack else { return }
            self.shownTrackID = track.id
            self.stage.showCaption(title: track.title, artist: track.artist, seconds: 3)
        }
    }

    // MARK: - Frames

    private var needsFrames: Bool {
        guard panel != nil, settings.showsOverlay else { return false }
        return !pendulum.isAsleep || pendulum.isHeld || give > 0 || reel.isDown != wantsDown
    }

    private func startLinkIfNeeded() {
        guard needsFrames, link == nil else { return }
        let link = stage.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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
        // Let go, a drawn-out cord goes back in over a tenth of a second.
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

        render(elapsed: elapsed)
        updateHover()
        setPace(elapsed: elapsed)
        if !needsFrames {
            stopLink()
        }
    }

    private func render(elapsed: Double) {
        guard let layout else { return }
        stage.place(
            anchor: layout.anchor,
            centre: pendulum.position,
            heading: pendulum.heading,
            cord: pendulum.cord.points
        )
        stage.setPresence(reel.presence * settings.opacity)
    }

    /// Full rate only while the disc is fast. A swing that has lost its speed
    /// looks the same at half the frames, and the last of it at a quarter.
    private func setPace(elapsed: Double) {
        guard let link else { return }
        recentSpeed = max(pendulum.velocity.length, recentSpeed * exp(-elapsed / 0.5))
        let wanted: CAFrameRateRange
        if pendulum.isHeld || recentSpeed >= 400 || reel.isDown != wantsDown {
            wanted = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        } else if recentSpeed >= 70 {
            wanted = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        } else {
            wanted = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
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

    // MARK: - The pointer

    private var pointer: CGPoint? {
        guard let panel else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
    }

    private func isOverDisc(_ point: CGPoint) -> Bool {
        guard isGrabbable, let layout else { return false }
        return (point - pendulum.position).length <= layout.radius + Metrics.grabPadding
    }

    /// Only a pin that is drawn can be taken hold of: an invisible handle at the
    /// top of the screen would swallow clicks meant for the menu bar under it.
    private func isOverPin(_ point: CGPoint) -> Bool {
        guard isGrabbable, let layout, layout.showsPin else { return false }
        return (point - layout.anchor).length <= Metrics.pinReach
    }

    /// The window lets clicks through everywhere except on the disc and the pin.
    private func updateHover() {
        guard let panel, panel.isVisible, let point = pointer else { return }
        let overDisc = isOverDisc(point)
        let overPin = !overDisc && isOverPin(point)
        let takesMouse = hold != .none || overDisc || overPin
        if panel.ignoresMouseEvents == takesMouse {
            panel.ignoresMouseEvents = !takesMouse
        }
        switch hold {
        case .disc: setCursor(.closedHand)
        case .pin: setCursor(.resizeLeftRight)
        case .none: setCursor(overDisc ? .openHand : overPin ? .resizeLeftRight : nil)
        }
    }

    private func setCursor(_ wanted: NSCursor?) {
        guard wanted !== cursor else { return }
        if cursor != nil {
            NSCursor.pop()
        }
        wanted?.push()
        cursor = wanted
    }

    // MARK: - The hand

    private func mouseDown(_ point: CGPoint) {
        guard let layout else { return }
        if isOverDisc(point) {
            hold = .disc
            grabOffset = pendulum.position - point
            samples = [(ProcessInfo.processInfo.systemUptime, point)]
            loops.end()
            tug.grab(target: pendulum.position, anchor: layout.anchor, disc: pendulum.position, reach: restReach)
            pendulum.hold(at: pendulum.position)
            if !stage.isCaptionShowing, let track = spotify.nowPlaying.hanging {
                stage.showCaption(title: track.title, artist: track.artist, seconds: 1.2)
            }
            startLinkIfNeeded()
        } else if isOverPin(point) {
            hold = .pin
        }
        updateHover()
    }

    private func mouseDragged(_ point: CGPoint) {
        guard let layout else { return }
        switch hold {
        case .none:
            break
        case .pin:
            guard let screen = NSScreen.screens.first else { return }
            let span = screen.frame.width - Metrics.margin * 2
            let along = (NSEvent.mouseLocation.x - screen.frame.minX - Metrics.margin) / span
            settings.position = along.clamped(to: 0...1)
        case .disc:
            let target = point + grabOffset
            let now = ProcessInfo.processInfo.systemUptime
            samples.append((now, point))
            samples.removeAll { now - $0.time > 0.09 }
            tug.drag(target: target, anchor: layout.anchor, reach: restReach)
            give = PullCord.give(target: target, anchor: layout.anchor, reach: restReach, most: Metrics.give)
            updateReach()
            pendulum.hold(at: target)
        }
    }

    private func mouseUp(_ point: CGPoint) {
        defer {
            hold = .none
            updateHover()
        }
        guard hold == .disc, let layout else { return }
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

    /// The hand's speed over the last few moments of the drag.
    private var handVelocity: CGPoint {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.008 else { return .zero }
        return (last.point - first.point) / (last.time - first.time)
    }
}
