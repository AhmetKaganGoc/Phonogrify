import CoreGraphics
import Foundation

/// A record hanging by its rim from a cord.
///
/// The record is two weights held a diameter apart: one where the cord ties on
/// at the rim, one at the opposite edge. That is the least that gives a disc
/// what a single point cannot have, a way of turning about its own middle, so
/// it rocks on its cord when it is stopped short and tumbles when it is thrown
/// slack. The cord itself is a rule, not a thing: the rim may be anywhere within
/// the cord's length of the anchor and no further.
///
/// Positions are stepped with Verlet integration and then corrected to obey
/// those two rules, which is exact about the cord never stretching and costs a
/// few dozen multiplications a step. The cord that is *drawn* is `CordChain`,
/// which follows this and never pushes back on it.
///
/// Coordinates are screen-style: `y` grows downward.
public struct Pendulum {
    public struct Tuning {
        /// Points per second squared.
        public var gravity = 2000.0
        /// Fraction of speed lost to the air each second, for a swing with energy to spare.
        public var drag = 0.5
        /// Extra drag that fades in as the swing dies away, so the last small
        /// wobble takes seconds rather than half a minute. Frames cost more than
        /// those wobbles are worth.
        public var settlingDrag = 1.7
        /// The speed, at the bottom of the swing, below which `settlingDrag` starts to bite.
        public var settlingSpeed = 260.0
        /// How quickly the record stops rocking about its own middle.
        public var rockingDrag = 2.2
        public var step = 1.0 / 240.0
        public var passes = 8
        public var maxSpeed = 6000.0
        /// Slower than this and closer than `restOffset` to hanging straight counts as still.
        public var restSpeed = 6.0
        public var restOffset = 1.0
        /// Seconds of stillness before the record is put to sleep.
        public var restTime = 0.3

        public init() {}
    }

    public var tuning = Tuning()
    public var anchor: CGPoint
    /// How much cord there is between the anchor and the record's rim.
    public var cordLength: Double
    public var radius: Double

    public private(set) var isAsleep = true
    public private(set) var isHeld = false
    public private(set) var cord: CordChain

    /// The two weights: where the cord ties on, and the opposite edge.
    private var top: CGPoint
    private var bottom: CGPoint
    private var topBefore: CGPoint
    private var bottomBefore: CGPoint
    private var holdTarget = CGPoint.zero
    private var stillFor = 0.0
    private var carry = 0.0

    public init(anchor: CGPoint, cordLength: Double, radius: Double) {
        self.anchor = anchor
        self.cordLength = cordLength
        self.radius = radius
        top = CGPoint(x: anchor.x, y: anchor.y + cordLength)
        bottom = CGPoint(x: anchor.x, y: anchor.y + cordLength + radius * 2)
        topBefore = top
        bottomBefore = bottom
        cord = CordChain(from: anchor, to: top)
    }

    // MARK: - Reading it

    /// The furthest the record's centre can be from the anchor.
    public var reach: Double { cordLength + radius }

    /// The record's centre.
    public var position: CGPoint { (top + bottom) * 0.5 }

    /// Where the cord ties on.
    public var rim: CGPoint { top }

    /// The way the record points, from the rim it hangs by toward the far edge.
    public var heading: CGPoint {
        let along = (bottom - top).unit
        return along == .zero ? CGPoint(x: 0, y: 1) : along
    }

    /// The centre's velocity, in points per second.
    public var velocity: CGPoint {
        ((top - topBefore) + (bottom - bottomBefore)) / (2 * tuning.step)
    }

    public var restPosition: CGPoint {
        CGPoint(x: anchor.x, y: anchor.y + reach)
    }

    public var isTaut: Bool {
        (top - anchor).length >= cordLength - 0.5
    }

    public mutating func wake() {
        isAsleep = false
        stillFor = 0
    }

    /// Hangs the record straight down, at rest.
    public mutating func settle() {
        top = CGPoint(x: anchor.x, y: anchor.y + cordLength)
        bottom = CGPoint(x: anchor.x, y: anchor.y + cordLength + radius * 2)
        topBefore = top
        bottomBefore = bottom
        cord.straighten(from: anchor, to: top)
        isAsleep = true
        isHeld = false
        carry = 0
    }

    // MARK: - In the hand

    /// Carries the record's centre to `target`, or as near as the cord allows.
    /// Which way it points is left to the cord and to its own turning.
    public mutating func hold(at target: CGPoint) {
        isHeld = true
        wake()
        holdTarget = withinReach(target)
    }

    /// Lets go, at the hand's speed.
    /// - Parameter assist: Zero to one. How much of the hand's speed *along* a
    ///   taut cord is turned into speed round the anchor. A straight flick on a
    ///   short cord ends up pulling outward, and without this it barely moves the record.
    public mutating func release(velocity thrown: CGPoint, assist: Double = 0) {
        isHeld = false
        wake()
        var speed = thrown.capped(at: tuning.maxSpeed)
        let outward = (position - anchor).unit
        let total = speed.length
        if assist > 0, (position - anchor).length >= reach - 1, total > 1 {
            let around = CGPoint(x: -outward.y, y: outward.x)
            let turning = speed.dot(around)
            // A pull straight along the cord is a tug, and has no way round to prefer.
            if abs(turning) >= total * 0.25 {
                let boosted = abs(turning) + assist.clamped(to: 0...1) * (total - abs(turning))
                speed = around * (turning < 0 ? -boosted : boosted)
            }
        }
        // Both weights leave at the hand's speed: thrown, not spun.
        topBefore = top - speed * tuning.step
        bottomBefore = bottom - speed * tuning.step
    }

    // MARK: - Time

    /// Moves everything on by one displayed frame, in fixed steps.
    public mutating func advance(by frameTime: Double) {
        guard !isAsleep else { return }
        carry += min(max(frameTime, 0), 0.1)
        while carry >= tuning.step {
            carry -= tuning.step
            step(tuning.step)
            if isAsleep { break }
        }
    }

    private mutating func step(_ dt: Double) {
        var topSpeed = (top - topBefore) / dt
        var bottomSpeed = (bottom - bottomBefore) / dt
        topBefore = top
        bottomBefore = bottom

        if !isHeld {
            topSpeed.y += tuning.gravity * dt
            bottomSpeed.y += tuning.gravity * dt
        }
        // The air slows the whole record; rocking about its middle dies faster.
        let keep = exp(-dragNow(topSpeed, bottomSpeed) * dt)
        let common = (topSpeed + bottomSpeed) * 0.5 * keep
        let rocking = (topSpeed - bottomSpeed) * 0.5 * keep * exp(-tuning.rockingDrag * dt)
        topSpeed = (common + rocking).capped(at: tuning.maxSpeed)
        bottomSpeed = (common - rocking).capped(at: tuning.maxSpeed)

        top = top + topSpeed * dt
        bottom = bottom + bottomSpeed * dt
        obeyRules()
        cord.step(from: anchor, to: top, length: cordLength, gravity: tuning.gravity, dt: dt)

        guard !isHeld else { return }
        let still = velocity.length < tuning.restSpeed
            && (position - restPosition).length < tuning.restOffset
            && abs(top.x - anchor.x) < tuning.restOffset
        if still {
            stillFor += dt
            if stillFor >= tuning.restTime {
                settle()
            }
        } else {
            stillFor = 0
        }
    }

    /// The record keeps its width, the hand keeps its hold, and last of all the
    /// cord keeps its length, so that whatever else gives a little it does not.
    private mutating func obeyRules() {
        for _ in 0..<tuning.passes {
            let across = bottom - top
            let width = across.length
            if width > 1e-9 {
                let fix = across * (0.5 * (width - radius * 2) / width)
                top = top + fix
                bottom = bottom - fix
            }
            if isHeld {
                let shift = holdTarget - (top + bottom) * 0.5
                top = top + shift
                bottom = bottom + shift
            }
            let out = top - anchor
            let distance = out.length
            if distance > cordLength, distance > 1e-9 {
                top = anchor + out * (cordLength / distance)
            }
        }
    }

    /// Light while the swing is lively, heavier as it dies. Judged by the swing's
    /// energy, not its speed this instant, which is nothing at each end of a swing.
    private func dragNow(_ topSpeed: CGPoint, _ bottomSpeed: CGPoint) -> Double {
        let speed = (topSpeed + bottomSpeed) * 0.5
        let height = max(0, restPosition.y - position.y)
        let bottomSpeedOfSwing = (speed.dot(speed) + 2 * tuning.gravity * height).squareRoot()
        let fading = (1 - bottomSpeedOfSwing / tuning.settlingSpeed).clamped(to: 0...1)
        return tuning.drag + tuning.settlingDrag * fading
    }

    private func withinReach(_ point: CGPoint) -> CGPoint {
        let offset = point - anchor
        let distance = offset.length
        guard distance > reach, distance > 1e-9 else { return point }
        return anchor + offset * (reach / distance)
    }
}
