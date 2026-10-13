import Foundation

/// How much of the cord is let out.
///
/// With nothing playing the disc is hauled up to the top and gone; when
/// something plays it is let back down. Progress runs evenly and the length is
/// eased from it, so the cord starts gently, runs, and stops gently.
public struct Reel: Equatable {
    public static let lowering = 1.0
    public static let raising = 0.8
    /// The least cord ever out, as a fraction of its length.
    public static let shortest = 0.04
    /// The part of the travel, nearest the top, over which the disc fades.
    public static let fadeSpan = 0.3

    /// Zero away, one all the way down.
    public private(set) var progress: Double

    public init(isDown: Bool = true) {
        progress = isDown ? 1 : 0
    }

    public var isAway: Bool { progress <= 0 }
    public var isDown: Bool { progress >= 1 }

    /// Fraction of the cord that is out.
    public var length: Double {
        Self.shortest + (1 - Self.shortest) * Ease.inOut(progress)
    }

    /// How much of the disc there is to see, zero to one.
    public var presence: Double {
        Ease.inOut(progress / Self.fadeSpan)
    }

    public mutating func jump(down: Bool) {
        progress = down ? 1 : 0
    }

    /// Moves toward down or away. Returns whether it moved.
    @discardableResult
    public mutating func advance(by seconds: Double, down: Bool) -> Bool {
        let target = down ? 1.0 : 0.0
        guard progress != target, seconds > 0 else { return false }
        let step = seconds / (down ? Self.lowering : Self.raising)
        progress = down ? min(1, progress + step) : max(0, progress - step)
        return true
    }
}
