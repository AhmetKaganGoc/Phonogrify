import CoreGraphics
import Foundation

/// Which way round the anchor, as seen on screen.
public enum Turn: String, Sendable {
    case clockwise
    case counterClockwise
}

/// Counts the times a thrown disc goes all the way round its anchor.
///
/// It adds up the signed change in the direction from anchor to disc. A loop is
/// that sum moving a whole turn past where the last loop was counted, so a swing
/// that climbs high on one side and falls back never counts, however far it went.
public struct LoopCounter {
    /// A loop wound closer to the anchor than this fraction of the reach is a
    /// slack cord flopping across it, not a loop.
    public var minimumRadius = 0.3

    public private(set) var loopsThisThrow = 0

    private var winding = 0.0
    private var counted = 0.0
    private var lastAngle: Double?
    private var closest = Double.infinity

    public init() {}

    public var isCounting: Bool { lastAngle != nil }

    /// The disc has just been let go.
    public mutating func begin(anchor: CGPoint, disc: CGPoint) {
        winding = 0
        counted = 0
        closest = .infinity
        loopsThisThrow = 0
        lastAngle = Self.angle(from: anchor, to: disc) ?? 0
    }

    /// The throw is over: caught, or come to rest.
    public mutating func end() {
        lastAngle = nil
    }

    /// One sample of the flight.
    /// - Returns: The direction of a loop completed on this sample, if one was.
    public mutating func track(anchor: CGPoint, disc: CGPoint, reach: Double) -> Turn? {
        guard let previous = lastAngle else { return nil }
        if reach > 1e-9 {
            closest = min(closest, (disc - anchor).length / reach)
        }
        guard let angle = Self.angle(from: anchor, to: disc) else { return nil }

        var change = (angle - previous).truncatingRemainder(dividingBy: 2 * .pi)
        if change > .pi { change -= 2 * .pi }
        if change < -.pi { change += 2 * .pi }
        winding += change
        lastAngle = angle

        let turned = winding - counted
        guard abs(turned) >= 2 * .pi else { return nil }
        counted += turned > 0 ? 2 * .pi : -2 * .pi

        let stayedOut = closest >= minimumRadius
        closest = .infinity
        guard stayedOut else { return nil }

        loopsThisThrow += 1
        // `y` grows downward, so an angle that grows is going round clockwise.
        return turned > 0 ? .clockwise : .counterClockwise
    }

    private static func angle(from anchor: CGPoint, to disc: CGPoint) -> Double? {
        let offset = disc - anchor
        return offset.length > 1e-9 ? atan2(offset.y, offset.x) : nil
    }
}

/// Tells a pull-cord tug from every other way of handling the disc.
///
/// A tug starts from a disc that is hanging, goes straight down past where the
/// cord is taut, and is let go there without a sideways fling.
public struct TugDetector {
    public struct Tuning {
        /// A tug starts within this angle of straight down, in radians.
        public var hangingAngle = 0.32
        /// ...and with the disc at least this far out along its cord.
        public var hangingExtension = 0.85
        /// How far past taut the hand must pull, as a fraction of the reach, and at least in points.
        public var depth = 0.06
        public var minimumDepth = 12.0
        /// Sideways wander, and lift above the starting point, that stop it being a tug.
        public var drift = 0.16
        public var lift = 0.10
        /// Sideways speed at release above which it was a throw.
        public var sideSpeed = 500.0

        public init() {}
    }

    public var tuning = Tuning()
    public private(set) var isCandidate = false
    public private(set) var isEngaged = false
    private var origin = CGPoint.zero

    public init() {}

    /// The disc has been taken hold of. `target` is where the hand wants its centre.
    public mutating func grab(target: CGPoint, anchor: CGPoint, disc: CGPoint, reach: Double) {
        let offset = disc - anchor
        let angle = abs(atan2(offset.x, offset.y))
        isCandidate = reach > 1e-9 && angle <= tuning.hangingAngle
            && offset.length >= reach * tuning.hangingExtension
        isEngaged = false
        origin = target
    }

    /// The hand moved. Returns whether the tug caught on this very movement.
    @discardableResult
    public mutating func drag(target: CGPoint, anchor: CGPoint, reach: Double) -> Bool {
        guard isCandidate else { return false }
        if abs(target.x - origin.x) > reach * tuning.drift || origin.y - target.y > reach * tuning.lift {
            isCandidate = false
            isEngaged = false
            return false
        }
        let pastTaut = (target - anchor).length - reach
        let descent = target.y - origin.y
        let needed = max(tuning.minimumDepth, reach * tuning.depth)
        if !isEngaged, min(pastTaut, descent) >= needed {
            isEngaged = true
            return true
        }
        return false
    }

    /// The hand let go. Returns whether that was a tug.
    public mutating func release(velocity: CGPoint) -> Bool {
        let wasTug = isCandidate && isEngaged && abs(velocity.x) <= tuning.sideSpeed
        isCandidate = false
        isEngaged = false
        return wasTug
    }
}

public enum PullCord {
    /// How far a downward pull past taut draws the cord out: it follows the
    /// hand at first and then less and less, never reaching `most`. The short
    /// travel and firm stop of a light's pull-cord.
    public static func give(target: CGPoint, anchor: CGPoint, reach: Double, most: Double) -> Double {
        let offset = target - anchor
        let distance = offset.length
        let past = distance - reach
        guard past > 0, distance > 1e-9, most > 0 else { return 0 }
        // Full straight down, fading to nothing forty-five degrees off it.
        let downward = ((offset.y / distance - 0.7) / 0.3).clamped(to: 0...1)
        return most * (1 - exp(-past / most)) * downward
    }
}
