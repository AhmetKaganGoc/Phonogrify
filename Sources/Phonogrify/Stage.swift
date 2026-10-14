import AppKit
import PhonogrifyCore
import QuartzCore

/// What is on screen: a cord, a disc, a ring round it, and for a moment a name.
///
/// Every part is a Core Animation layer. Moving the disc is moving a layer and
/// replacing one small path, which the system composites on the GPU; nothing is
/// redrawn by this app. Whatever moves by itself (the ring turning, the name
/// fading, the disc turning over, the glint) is an animation handed to the
/// system and costs this app no frames at all.
///
/// Callers speak in screen-style points, `y` downward from the top of the view.
final class Stage: NSView {
    private let content = CALayer()
    /// Everything that hangs, moved as one when the record is let down or hauled
    /// up, inside a fixed frame that clips it at the anchor while it does.
    private let clip = CALayer()
    private let hanging = CALayer()
    private let reelMask = CALayer()
    private var reelGeneration = 0
    private let dropShadow = CALayer()
    private let cordShade = CAShapeLayer()
    private let cord = CAShapeLayer()
    private let glintLayer = CAShapeLayer()
    private let pin = CALayer()
    private let group = CALayer()
    private let loop = CAShapeLayer()
    private let progressArc = CAShapeLayer()
    private let disc = CALayer()
    private let ring = CALayer()
    private let caption = CALayer()

    private(set) var radius = 34.0
    private var captionSize = CGSize.zero
    private var captionRequest = 0
    private var isSpinning = false
    private var swap: DispatchWorkItem?

    static let ringRadius = 1.17
    static let ringPeriod = 20.0
    static let cordColor = NSColor(white: 0.93, alpha: 1)
    static let green = NSColor(srgbRed: 0.114, green: 0.725, blue: 0.329, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Stage is made in code.")
    }

    /// Layers measure `y` upward; everything else here measures it downward.
    private func flipped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: bounds.height - point.y)
    }

    // MARK: - Building

    private func build() {
        for line in [cordShade, cord, glintLayer] {
            line.fillColor = nil
            line.lineCap = .round
        }
        cordShade.strokeColor = NSColor(white: 0, alpha: 0.28).cgColor
        cordShade.lineWidth = 3.4
        cord.strokeColor = Self.cordColor.cgColor
        cord.lineWidth = 1.7
        glintLayer.strokeColor = NSColor.white.cgColor
        glintLayer.lineWidth = 2.8
        glintLayer.opacity = 0

        pin.backgroundColor = Self.cordColor.cgColor
        pin.borderColor = NSColor(white: 0, alpha: 0.3).cgColor
        pin.borderWidth = 0.5
        pin.cornerRadius = 2.5
        pin.bounds = CGRect(x: 0, y: 0, width: 16, height: 5)

        loop.fillColor = nil
        loop.strokeColor = Self.cordColor.cgColor
        progressArc.fillColor = nil
        progressArc.strokeColor = Self.green.cgColor
        progressArc.lineCap = .round
        progressArc.isHidden = true
        disc.contentsGravity = .resizeAspect
        disc.minificationFilter = .trilinear
        caption.opacity = 0

        group.addSublayer(loop)
        group.addSublayer(progressArc)
        group.addSublayer(disc)
        group.addSublayer(ring)
        for part in [dropShadow, cordShade, cord, glintLayer, group, caption] {
            hanging.addSublayer(part)
        }
        reelMask.backgroundColor = NSColor.black.cgColor
        clip.addSublayer(hanging)
        content.addSublayer(clip)
        content.addSublayer(pin)
        layer?.addSublayer(content)
    }

    /// Sizes everything for a view of `size` holding a disc of `radius`.
    func configure(size: CGSize, radius: Double, scale: Double, showsPin: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.radius = radius
        pin.isHidden = !showsPin
        content.frame = CGRect(origin: .zero, size: size)
        clip.frame = content.bounds
        hanging.frame = content.bounds
        for part in [cordShade, cord, glintLayer, loop, progressArc, caption, disc, dropShadow] {
            part.contentsScale = scale
        }

        disc.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        disc.position = .zero
        // Depth for the turn-over: the near half of a turning record looks
        // larger than the far half. Seen from about seven radii away.
        var depth = CATransform3DIdentity
        depth.m34 = -1 / max(200, radius * 7)
        group.sublayerTransform = depth

        // The loop the cord ends in sits on the rim, under the disc, so the
        // half of it that passes behind is hidden.
        let loopRadius = radius * 0.22
        loop.lineWidth = max(1.2, radius * 0.075)
        loop.path = CGPath(
            ellipseIn: CGRect(x: -loopRadius, y: radius - loopRadius, width: loopRadius * 2, height: loopRadius * 2),
            transform: nil
        )

        // The half of the loop that shows above the rim doubles as the track's
        // progress: a curved bar that fills from its left end, over the top, to
        // its right. Drawn over the loop and, like it, under the disc.
        let arc = CGMutablePath()
        arc.addArc(
            center: CGPoint(x: 0, y: radius),
            radius: loopRadius,
            startAngle: .pi + 0.3,
            endAngle: -0.3,
            clockwise: true
        )
        progressArc.path = arc
        progressArc.lineWidth = loop.lineWidth

        let reach = radius * 2.7
        dropShadow.bounds = CGRect(x: 0, y: 0, width: reach, height: reach)
        dropShadow.contents = Artist.shadow(side: Int(reach * scale))

        buildRing()
        CATransaction.commit()
        ensureSpin()
    }

    /// A hairline circle just outside the rim, lit along one soft arc and clear
    /// for a third of the way round: white over a wider, fainter black, so it
    /// shows on a dark desktop and a bright one.
    private func buildRing() {
        ring.sublayers?.forEach { $0.removeFromSuperlayer() }
        let ringRadius = radius * Self.ringRadius
        let width = max(1, radius * 0.03)
        let side = (ringRadius + width * 3) * 2
        ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ring.position = .zero

        let arc: [(at: Double, light: Double)] = [
            (0, 0), (0.33, 0), (0.45, 0.2), (0.58, 0.7), (0.67, 1), (0.76, 0.7), (0.89, 0.2), (1, 0)
        ]
        let passes: [(color: NSColor, strength: Double, width: Double)] = [
            (.black, 0.3, width * 2.1), (.white, 0.62, width)
        ]
        for pass in passes {
            let sweep = CAGradientLayer()
            sweep.type = .conic
            sweep.frame = ring.bounds
            sweep.startPoint = CGPoint(x: 0.5, y: 0.5)
            sweep.endPoint = CGPoint(x: 0.5, y: 1)
            sweep.colors = arc.map { pass.color.withAlphaComponent(pass.strength * $0.light).cgColor }
            sweep.locations = arc.map { NSNumber(value: $0.at) }

            let outline = CAShapeLayer()
            outline.frame = sweep.bounds
            outline.fillColor = nil
            outline.strokeColor = NSColor.black.cgColor
            outline.lineWidth = pass.width
            outline.path = CGPath(
                ellipseIn: CGRect(
                    x: side / 2 - ringRadius, y: side / 2 - ringRadius, width: ringRadius * 2, height: ringRadius * 2
                ),
                transform: nil
            )
            sweep.mask = outline
            ring.addSublayer(sweep)
        }
    }

    // MARK: - Each frame

    /// Puts the cord and the disc where the physics says they are.
    /// - Parameters:
    ///   - heading: The way the disc points, from the rim it hangs by.
    ///   - points: The cord, anchor first and rim last.
    func place(anchor: CGPoint, centre: CGPoint, heading: CGPoint, cord points: [CGPoint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // A smooth line through the chain: each point bends the curve toward
        // itself, and the curve passes through the middles between them.
        let path = CGMutablePath()
        if let first = points.first, let last = points.last, points.count >= 3 {
            path.move(to: flipped(first))
            for index in 1..<(points.count - 1) {
                let next = index == points.count - 2 ? last : (points[index] + points[index + 1]) * 0.5
                path.addQuadCurve(to: flipped(next), control: flipped(points[index]))
            }
        } else if let first = points.first, let last = points.last {
            path.move(to: flipped(first))
            path.addLine(to: flipped(last))
        }
        cordShade.path = path
        cord.path = path
        glintLayer.path = path

        pin.position = flipped(anchor)
        group.position = flipped(centre)
        // The disc hangs by its rim, and turns about it as the physics has it turn.
        group.setAffineTransform(CGAffineTransform(rotationAngle: atan2(heading.x, heading.y)))
        dropShadow.position = flipped(CGPoint(x: centre.x, y: centre.y + radius * 0.16))

        // The name sits under the disc and goes where it goes, kept on the stage.
        let half = captionSize.width / 2
        let x = min(max(centre.x, half + 2), max(half + 2, bounds.width - half - 2))
        let y = min(centre.y + radius * Self.ringRadius + 8 + captionSize.height / 2,
                    bounds.height - captionSize.height / 2 - 2)
        caption.position = flipped(CGPoint(x: x, y: y))
        CATransaction.commit()
    }

    // MARK: - Letting down and hauling up

    /// Lets the record down on its cord, or hauls it up out of sight, and says
    /// how long that will take.
    ///
    /// The whole hanging assembly slides along the cord's line while a clip at
    /// the anchor hides whatever has gone above it, so the cord seems to pay
    /// out of the anchor and wind back into it. It is handed to the system as
    /// one animation: it runs on the window server, smooth however busy the Mac
    /// is when Spotify opens or quits, and costs this app no frames at all.
    @discardableResult
    func reel(down: Bool, distance: Double, anchorY: Double, animated: Bool) -> TimeInterval {
        reelGeneration += 1
        let generation = reelGeneration
        let duration = animated ? (down ? 1.0 : 0.8) : 0
        // Layers measure upward, so hauling up is a positive shift.
        let target = down ? 0.0 : distance
        let shown = hanging.presentation()
        let from = (shown?.value(forKeyPath: "transform.translation.y") as? Double)
            ?? (hanging.value(forKeyPath: "transform.translation.y") as? Double) ?? target
        let fromOpacity = shown?.opacity ?? hanging.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reelMask.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - anchorY))
        clip.mask = reelMask
        hanging.setValue(target, forKeyPath: "transform.translation.y")
        hanging.opacity = down ? 1 : 0
        CATransaction.commit()

        guard duration > 0 else {
            if down { clip.mask = nil }
            return 0
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Down and settled, the clip goes, so a loop over the top is not cut off.
            guard let self, down, generation == self.reelGeneration else { return }
            self.clip.mask = nil
        }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = from
        move.toValue = target
        move.duration = duration
        // Starts gently, runs, and comes to its stop gently: never an even speed.
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        hanging.add(move, forKey: "reel")

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = down ? [fromOpacity, 1, 1] : [fromOpacity, fromOpacity, 0]
        fade.keyTimes = down ? [0, 0.3, 1] : [0, 0.7, 1]
        fade.duration = duration
        hanging.add(fade, forKey: "fade")
        CATransaction.commit()
        return duration
    }

    /// How much of the whole thing shows: the user's transparency.
    func setPresence(_ value: Double) {
        guard content.opacity != Float(value) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.opacity = Float(value)
        CATransaction.commit()
    }

    // MARK: - The disc

    /// Which way a record turns over on its cord: onward for the next track,
    /// back for the previous one.
    enum Flip {
        case onward
        case back
    }

    /// Shows a new record. With a `flip` it turns over on its cord, in depth:
    /// round to edge-on, where the picture changes, on round from the other
    /// side, a touch past flat, and back to rest. Which way round says whether
    /// the music went on or back.
    func setDisc(_ image: CGImage, flip: Flip?) {
        swap?.cancel()
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let flip, disc.contents != nil, !still else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            disc.contents = image
            CATransaction.commit()
            return
        }

        let way: Double = flip == .onward ? 1 : -1
        let duration = 0.78
        let edgeOn = 0.4

        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.y")
        // The jump at edge-on is from one face to the other: the new picture
        // arrives the right way round, still turning the same way.
        turn.values = [0, way * .pi / 2, -way * .pi / 2, way * 0.17, 0]
        turn.keyTimes = [0, NSNumber(value: edgeOn), NSNumber(value: edgeOn), 0.84, 1]
        turn.timingFunctions = [
            CAMediaTimingFunction(name: .easeIn),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]

        // It swells a little as it comes round, as a thing does turning toward you.
        let swell = CAKeyframeAnimation(keyPath: "transform.scale")
        swell.values = [1, 1.07, 1.03, 1]
        swell.keyTimes = [0, NSNumber(value: edgeOn), 0.84, 1]

        let both = CAAnimationGroup()
        both.animations = [turn, swell]
        both.duration = duration
        disc.add(both, forKey: "turn")

        let work = DispatchWorkItem { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.disc.contents = image
            CATransaction.commit()
        }
        swap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * edgeOn, execute: work)
    }

    // MARK: - The ring

    /// Turning while a track plays; standing still, a little dimmer, while it does not.
    func setSpinning(_ spinning: Bool) {
        isSpinning = spinning
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        ring.opacity = spinning ? 1 : 0.6
        CATransaction.commit()
        ensureSpin()
    }

    /// The ring's turning is one endless animation, paused and resumed. This
    /// puts it back if the system dropped it, and matches it to `isSpinning`.
    func ensureSpin() {
        // Still under Reduce Motion, and still in Low Power Mode: a ring that
        // turns all day is the one thing here that asks the screen for frames
        // while nothing is being touched.
        let mayTurn = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
        guard mayTurn else {
            ring.removeAnimation(forKey: "spin")
            ring.speed = 1
            ring.timeOffset = 0
            ring.beginTime = 0
            return
        }
        if ring.animation(forKey: "spin") == nil {
            ring.speed = 1
            ring.timeOffset = 0
            ring.beginTime = 0
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            // Layers turn counter-clockwise for a positive angle.
            spin.byValue = -2 * Double.pi
            spin.duration = Self.ringPeriod
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            // Something this slow needs very few frames to look continuous.
            spin.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 10)
            ring.add(spin, forKey: "spin")
        }

        let isPaused = ring.speed == 0
        if isSpinning, isPaused {
            let pausedAt = ring.timeOffset
            ring.speed = 1
            ring.timeOffset = 0
            ring.beginTime = 0
            ring.beginTime = ring.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        } else if !isSpinning, !isPaused {
            let now = ring.convertTime(CACurrentMediaTime(), from: nil)
            ring.speed = 0
            ring.timeOffset = now
        }
    }

    // MARK: - How far through the track

    /// Fills the loop's visible half to `fraction` and, while the track plays,
    /// lets it run on to full over the time that is left. The running is one
    /// animation given to the system, at a couple of frames a second: over a
    /// whole song the bar moves less than a point every ten seconds.
    func setProgress(_ progress: (fraction: Double, remaining: Double)?, isPlaying: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressArc.removeAnimation(forKey: "run")
        guard let progress else {
            progressArc.isHidden = true
            loop.opacity = 1
            CATransaction.commit()
            return
        }
        progressArc.isHidden = false
        // The loop itself steps back to being the bar's unfilled track.
        loop.opacity = 0.45
        progressArc.strokeEnd = progress.fraction
        CATransaction.commit()

        guard isPlaying, progress.remaining > 0.5 else { return }
        let run = CABasicAnimation(keyPath: "strokeEnd")
        run.fromValue = progress.fraction
        run.toValue = 1
        run.duration = progress.remaining
        run.fillMode = .forwards
        run.isRemovedOnCompletion = false
        run.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 5, preferred: 2)
        progressArc.add(run, forKey: "run")
    }

    // MARK: - The name

    var isCaptionShowing: Bool {
        caption.animation(forKey: "show") != nil
    }

    /// Shows the track's name under the disc for `seconds`, fading in and out.
    func showCaption(title: String, artist: String, seconds: Double) {
        let scale = window?.backingScaleFactor ?? 2
        captionRequest += 1
        let request = captionRequest
        // Setting text is slow enough to cost a frame, and a name is shown just
        // as the record starts moving; so it is set away from the main thread.
        Task { @MainActor [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                Artist.caption(title: title, artist: artist, scale: scale)
            }.value
            guard let self, request == self.captionRequest, let drawn else { return }
            self.presentCaption(drawn.image, size: drawn.size, seconds: seconds)
        }
    }

    private func presentCaption(_ image: CGImage, size: CGSize, seconds: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captionSize = size
        caption.bounds = CGRect(origin: .zero, size: size)
        caption.contents = image
        caption.position = CGPoint(x: group.position.x, y: group.position.y - radius * Self.ringRadius - 8 - size.height / 2)
        CATransaction.commit()

        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fadeIn = still ? 0.001 : min(0.25, seconds * 0.15)
        let fadeOut = still ? 0.001 : min(0.5, seconds * 0.25)
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, NSNumber(value: fadeIn / seconds), NSNumber(value: 1 - fadeOut / seconds), 1]
        show.duration = seconds
        caption.add(show, forKey: "show")
    }

    // MARK: - The glint

    /// A streak of light running down the cord, anchor to disc.
    func glint() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let head = CAKeyframeAnimation(keyPath: "strokeEnd")
        head.values = [0, 0.32, 1, 1]
        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.values = [0, 0, 0.72, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 0.95, 0.7, 0]
        let run = CAAnimationGroup()
        run.animations = [head, tail, fade]
        for part in [head, tail, fade] {
            part.keyTimes = [0, 0.25, 0.8, 1]
        }
        run.duration = 0.45
        glintLayer.add(run, forKey: "glint")
    }
}
