import CoreGraphics
import XCTest
@testable import PhonogrifyCore

final class PendulumTests: XCTestCase {
    private let anchor = CGPoint(x: 300, y: 10)
    private let frame = 1.0 / 60.0

    private func make(cord: Double = 250) -> Pendulum {
        Pendulum(anchor: anchor, cordLength: cord, radius: 30)
    }

    private func run(_ pendulum: inout Pendulum, seconds: Double, each: (Pendulum) -> Void = { _ in }) {
        var time = 0.0
        while time < seconds {
            pendulum.advance(by: frame)
            each(pendulum)
            time += frame
        }
    }

    private func loops(speed: Double, seconds: Double = 12) -> (turns: [Turn], settledAfter: Double) {
        var pendulum = make()
        var counter = LoopCounter()
        pendulum.release(velocity: CGPoint(x: speed, y: 0))
        counter.begin(anchor: anchor, disc: pendulum.position)
        var found: [Turn] = []
        var time = 0.0
        while time < 60, !pendulum.isAsleep {
            pendulum.advance(by: frame)
            if let turn = counter.track(anchor: anchor, disc: pendulum.position, reach: pendulum.reach) {
                found.append(turn)
            }
            time += frame
        }
        return (found, time)
    }

    func testStartsAsleepAndHanging() {
        let pendulum = make()
        XCTAssertTrue(pendulum.isAsleep)
        XCTAssertEqual(pendulum.rim, CGPoint(x: 300, y: 260))
        XCTAssertEqual(pendulum.position, CGPoint(x: 300, y: 290))
        XCTAssertEqual(pendulum.heading, CGPoint(x: 0, y: 1))
    }

    func testTheCordNeverStretchesAndTheRecordKeepsItsWidth() {
        var pendulum = make()
        pendulum.release(velocity: CGPoint(x: 5000, y: -3000))
        run(&pendulum, seconds: 6) { state in
            XCTAssertLessThanOrEqual((state.rim - self.anchor).length, 250 + 1e-6)
            XCTAssertEqual((state.position - state.rim).length, 30, accuracy: 0.75)
        }
    }

    func testTheDrawnCordKeepsItsLengthAndItsEnds() {
        var pendulum = make()
        pendulum.release(velocity: CGPoint(x: 2500, y: -500))
        run(&pendulum, seconds: 4) { state in
            let points = state.cord.points
            XCTAssertEqual(points.first, self.anchor)
            XCTAssertEqual(points.last, state.rim)
            let drawn = zip(points, points.dropFirst()).reduce(0.0) { $0 + ($1.1 - $1.0).length }
            XCTAssertLessThan(drawn, 250 * 1.08)
        }
    }

    func testASwingComesToRestAndSleeps() {
        var pendulum = make()
        pendulum.release(velocity: CGPoint(x: 900, y: 0))
        run(&pendulum, seconds: 25)
        XCTAssertTrue(pendulum.isAsleep)
        XCTAssertEqual(pendulum.position.x, 300, accuracy: 0.001)
        XCTAssertEqual(pendulum.position.y, 290, accuracy: 0.001)
    }

    func testAHardThrowLoopsAndAGentleOneDoesNot() {
        XCTAssertTrue(loops(speed: 700).turns.isEmpty)
        // Thrown to the right it goes up the right-hand side: counter-clockwise on screen.
        let right = loops(speed: 3200).turns
        XCTAssertFalse(right.isEmpty)
        XCTAssertTrue(right.allSatisfy { $0 == .counterClockwise })
        let left = loops(speed: -3200).turns
        XCTAssertFalse(left.isEmpty)
        XCTAssertTrue(left.allSatisfy { $0 == .clockwise })
    }

    func testEveryThrowSettlesInGoodTime() {
        for speed in [600.0, 1200, 2000, 3200, 5000] {
            let result = loops(speed: speed)
            print("PROBE speed \(Int(speed)): settles in \(String(format: "%.1f", result.settledAfter)) s, loops \(result.turns.count)")
            XCTAssertLessThan(result.settledAfter, 20, "a throw at \(speed) pt/s was still moving")
        }
    }

    func testHeldItGoesWhereTheHandIsButNoFurtherThanTheCord() {
        var pendulum = make()
        pendulum.hold(at: CGPoint(x: 380, y: 200))
        run(&pendulum, seconds: 0.5)
        XCTAssertEqual(pendulum.position.x, 380, accuracy: 0.5)
        XCTAssertEqual(pendulum.position.y, 200, accuracy: 0.5)

        pendulum.hold(at: CGPoint(x: 300, y: 900))
        run(&pendulum, seconds: 0.5)
        XCTAssertEqual((pendulum.position - anchor).length, pendulum.reach, accuracy: 0.75)
        XCTAssertLessThanOrEqual((pendulum.rim - anchor).length, 250 + 1e-6)
    }

    func testAShortCordTurnsAFlickAlongItIntoASwing() {
        var plain = make(cord: 90)
        let side = CGPoint(x: anchor.x + 120, y: anchor.y)
        plain.hold(at: side)
        run(&plain, seconds: 0.3)
        var helped = plain
        // Flung outward and a little down: mostly along the cord.
        plain.release(velocity: CGPoint(x: 1500, y: 600))
        helped.release(velocity: CGPoint(x: 1500, y: 600), assist: 1)
        plain.advance(by: frame)
        helped.advance(by: frame)
        XCTAssertGreaterThan(helped.velocity.length, plain.velocity.length + 400)
    }
}

final class GestureTests: XCTestCase {
    private let anchor = CGPoint(x: 300, y: 10)
    private let reach = 280.0
    private var rest: CGPoint { CGPoint(x: 300, y: 290) }

    func testRightIsNextAndLeftIsPrevious() {
        XCTAssertEqual(Remote.command(for: .counterClockwise), .next)
        XCTAssertEqual(Remote.command(for: .clockwise), .previous)
    }

    func testAHighSwingBothWaysIsNotALoop() {
        var counter = LoopCounter()
        counter.begin(anchor: anchor, disc: rest)
        var found = 0
        for step in 0..<2000 {
            // Back and forth to 170 degrees either side, never over the top.
            let angle = sin(Double(step) / 2000 * 6 * .pi) * (170 * .pi / 180)
            let disc = CGPoint(x: anchor.x + sin(angle) * reach, y: anchor.y + cos(angle) * reach)
            if counter.track(anchor: anchor, disc: disc, reach: reach) != nil { found += 1 }
        }
        XCTAssertEqual(found, 0)
    }

    func testAPullStraightDownIsATug() {
        var tug = TugDetector()
        tug.grab(target: rest, anchor: anchor, disc: rest, reach: reach)
        XCTAssertFalse(tug.drag(target: CGPoint(x: 300, y: 296), anchor: anchor, reach: reach))
        XCTAssertTrue(tug.drag(target: CGPoint(x: 301, y: 312), anchor: anchor, reach: reach))
        XCTAssertTrue(tug.release(velocity: CGPoint(x: 20, y: 300)))
    }

    func testOrdinaryHandlingIsNotATug() {
        var click = TugDetector()
        click.grab(target: rest, anchor: anchor, disc: rest, reach: reach)
        XCTAssertFalse(click.release(velocity: .zero))

        var carried = TugDetector()
        carried.grab(target: rest, anchor: anchor, disc: rest, reach: reach)
        carried.drag(target: CGPoint(x: 300, y: 312), anchor: anchor, reach: reach)
        carried.drag(target: CGPoint(x: 380, y: 300), anchor: anchor, reach: reach)
        XCTAssertFalse(carried.release(velocity: .zero))

        var flung = TugDetector()
        flung.grab(target: rest, anchor: anchor, disc: rest, reach: reach)
        flung.drag(target: CGPoint(x: 300, y: 312), anchor: anchor, reach: reach)
        XCTAssertFalse(flung.release(velocity: CGPoint(x: 900, y: 0)))

        var caught = TugDetector()
        let side = CGPoint(x: anchor.x + reach, y: anchor.y)
        caught.grab(target: side, anchor: anchor, disc: side, reach: reach)
        caught.drag(target: CGPoint(x: side.x, y: side.y + 30), anchor: anchor, reach: reach)
        XCTAssertFalse(caught.release(velocity: .zero))
    }

    func testTheCordGivesALittleAndOnlyDownward() {
        let down = PullCord.give(target: CGPoint(x: 300, y: 330), anchor: anchor, reach: reach, most: 13)
        XCTAssertGreaterThan(down, 8)
        XCTAssertLessThan(down, 13)
        let side = PullCord.give(target: CGPoint(x: 700, y: 10), anchor: anchor, reach: reach, most: 13)
        XCTAssertEqual(side, 0)
        XCTAssertEqual(PullCord.give(target: rest, anchor: anchor, reach: reach, most: 13), 0)
    }

    func testTheReelEasesAndFades() {
        var reel = Reel(isDown: false)
        XCTAssertTrue(reel.isAway)
        XCTAssertEqual(reel.presence, 0)
        var lengths: [Double] = []
        while reel.advance(by: 0.05, down: true) { lengths.append(reel.length) }
        XCTAssertTrue(reel.isDown)
        XCTAssertEqual(reel.length, 1, accuracy: 1e-9)
        XCTAssertEqual(lengths, lengths.sorted())
        // Not an even speed: the middle of the travel is quicker than its ends.
        let steps = zip(lengths.dropFirst(), lengths).map { $0 - $1 }
        XCTAssertGreaterThan(steps[steps.count / 2], steps[0] * 2)
    }
}
