import CoreGraphics
import Foundation

/// The cord, as a chain of light links between the anchor and the record's rim.
///
/// Its two ends are put where the anchor and the rim are; the links between
/// fall, swing and are pulled back to their length. So a slack cord sags and
/// sways, a cord snatched taut twangs straight, and a moving record drags a
/// curve behind it. It only ever follows: nothing it does reaches the record.
public struct CordChain {
    /// The points along the cord, anchor first and rim last.
    public private(set) var points: [CGPoint]
    private var before: [CGPoint]

    /// How quickly a link loses its own motion. A cord is light and the air is not.
    public var drag = 5.0
    public var passes = 6

    public init(from anchor: CGPoint, to rim: CGPoint, count: Int = 12) {
        let last = Double(max(2, count) - 1)
        points = (0..<max(2, count)).map { anchor + (rim - anchor) * (Double($0) / last) }
        before = points
    }

    /// Lays the cord in a straight line, at rest.
    public mutating func straighten(from anchor: CGPoint, to rim: CGPoint) {
        let last = Double(points.count - 1)
        for index in points.indices {
            points[index] = anchor + (rim - anchor) * (Double(index) / last)
        }
        before = points
    }

    /// Moves the cord on by one step.
    /// - Parameter length: How much cord there is, which may be more than the
    ///   distance it has to span. The spare is what sags.
    public mutating func step(from anchor: CGPoint, to rim: CGPoint, length: Double, gravity: Double, dt: Double) {
        let lastIndex = points.count - 1
        let keep = exp(-drag * dt)
        for index in 1..<lastIndex {
            var speed = (points[index] - before[index]) / dt
            speed.y += gravity * dt
            before[index] = points[index]
            points[index] = points[index] + speed * (keep * dt)
        }
        points[0] = anchor
        points[lastIndex] = rim
        before[0] = anchor
        before[lastIndex] = rim

        let link = length / Double(lastIndex)
        for _ in 0..<passes {
            for index in 0..<lastIndex {
                let across = points[index + 1] - points[index]
                let size = across.length
                guard size > 1e-9 else { continue }
                let fix = across * ((size - link) / size)
                // An end stays where it is put; a link between two free points shares the fix.
                if index == 0 {
                    points[1] = points[1] - fix
                } else if index + 1 == lastIndex {
                    points[index] = points[index] + fix
                } else {
                    points[index] = points[index] + fix * 0.5
                    points[index + 1] = points[index + 1] - fix * 0.5
                }
            }
        }
    }
}
