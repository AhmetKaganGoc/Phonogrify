import CoreGraphics
import Foundation

public extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, k: Double) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
    static func / (a: CGPoint, k: Double) -> CGPoint { CGPoint(x: a.x / k, y: a.y / k) }

    var length: Double { (x * x + y * y).squareRoot() }

    func dot(_ other: CGPoint) -> Double { x * other.x + y * other.y }

    /// The same direction, one long. Zero stays zero.
    var unit: CGPoint {
        let size = length
        return size > 1e-9 ? self / size : .zero
    }

    /// The same direction, no longer than `limit`.
    func capped(at limit: Double) -> CGPoint {
        let size = length
        return size > limit && size > 1e-9 ? self * (limit / size) : self
    }
}

public extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

public enum Ease {
    /// Slow at both ends, quick in the middle. Maps 0...1 onto 0...1.
    public static func inOut(_ value: Double) -> Double {
        let t = value.clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }
}
