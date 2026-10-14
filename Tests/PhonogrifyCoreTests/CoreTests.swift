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

    /// How far a cord strays from the straight line between its ends, held level
    /// a given fraction of its own length apart and left to settle.
    private func sag(spanning ratio: Double, of length: Double = 250) -> Double {
        let start = CGPoint.zero
        let end = CGPoint(x: length * ratio, y: 0)
        var cord = CordChain(from: start, to: end)
        for _ in 0..<720 {
            cord.step(from: start, to: end, length: length, gravity: 2000, dt: 1.0 / 240)
        }
        return Double(cord.points.map(\.y).max() ?? 0)
    }

    func testASlackCordHangsAsARealOneDoes() {
        // A shallow hanging cord bows by the square root of 3/8 of span times spare length.
        for ratio in [0.90, 0.95, 0.98, 0.99] {
            let span = 250 * ratio
            let real = (3 * span * (250 - span) / 8).squareRoot()
            XCTAssertEqual(sag(spanning: ratio), real, accuracy: real * 0.12, "at \(ratio) of its length")
        }
    }

    func testTheCordDrawsTightGraduallyAndEndsStraight() {
        // Less and less to spare, less and less bow, with no step anywhere.
        let ratios = [0.95, 0.98, 0.99, 0.995, 0.998, 0.999, 0.9995, 1.0]
        let sags = ratios.map { sag(spanning: $0) }
        for (looser, tighter) in zip(sags, sags.dropFirst()) {
            XCTAssertLessThan(tighter, looser)
            // Never more than halved between neighbouring steps: a curve, not a snap.
            XCTAssertGreaterThan(tighter, looser * 0.4)
        }
        // Pulled to its full length it is straight to the eye: under a hundredth of its length.
        XCTAssertLessThan(sag(spanning: 1.0), 2.5)
    }

    func testASwingingCordIsNearlyStraightButNotAStick() {
        var pendulum = make()
        pendulum.release(velocity: CGPoint(x: 1400, y: 0))
        var mostBowed = 0.0
        run(&pendulum, seconds: 2) { state in
            guard state.isTaut else { return }
            let along = (state.rim - self.anchor).unit
            for point in state.cord.points {
                let offset = point - self.anchor
                mostBowed = max(mostBowed, abs(offset.x * along.y - offset.y * along.x))
            }
        }
        // Half a point of spare cord is already a bow of several points, so this is
        // the cord at the edge of going slack, not a cord that sags under tension.
        XCTAssertLessThan(mostBowed, 8)
        XCTAssertGreaterThan(mostBowed, 0.2)
    }

    func testHeldOutAtFullStretchTheCordIsStraight() {
        var pendulum = make()
        // Carried far out to the left, well past what the cord can reach.
        pendulum.hold(at: CGPoint(x: -400, y: 60))
        run(&pendulum, seconds: 0.8)
        let along = (pendulum.rim - anchor).unit
        for point in pendulum.cord.points {
            let offset = point - anchor
            XCTAssertLessThan(abs(offset.x * along.y - offset.y * along.x), 3)
        }
    }

    func testProgressRunsOnWhilePlayingAndStopsWhenPaused() {
        let track = Track(id: "t", title: "T", artist: "A", duration: 200)
        let start = Date(timeIntervalSince1970: 1000)
        let playing = NowPlaying(state: .playing, track: track, position: 50, asOf: start)
        let later = playing.progress(at: start.addingTimeInterval(50))
        XCTAssertEqual(later?.fraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(later?.remaining ?? 0, 100, accuracy: 1e-9)

        let paused = NowPlaying(state: .paused, track: track, position: 50, asOf: start)
        XCTAssertEqual(paused.progress(at: start.addingTimeInterval(50))?.fraction ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertNil(NowPlaying(state: .playing, track: Track(id: "x", title: "", artist: "")).progress())
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
}

final class TrailTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 5000)

    /// Moves on by `seconds` and reports a change to `track`.
    private func change(
        _ trail: inout Trail,
        to track: String,
        after seconds: Double = 30,
        _ evidence: Trail.Evidence
    ) -> Trail.Step? {
        clock = clock.addingTimeInterval(seconds)
        return trail.move(to: track, evidence: evidence, at: clock)
    }

    private func wellIn(_ seconds: Double = 40) -> Trail.Evidence {
        Trail.Evidence(previousElapsed: seconds)
    }

    private var justStarted: Trail.Evidence {
        Trail.Evidence(previousElapsed: 1)
    }

    func testNextFromWellIntoASongIsOnwardEvenToASongAlreadyHeard() {
        var trail = Trail()
        // Heard q, picked p by hand, then pressed Next, which plays q again.
        _ = change(&trail, to: "q", wellIn())
        XCTAssertEqual(change(&trail, to: "p", wellIn()), .onward)
        XCTAssertEqual(change(&trail, to: "q", wellIn()), .onward)
    }

    func testTwoPressesOfPreviousGoBackEvenToASongNeverHeard() {
        var trail = Trail()
        _ = change(&trail, to: "c", wellIn())
        clock = clock.addingTimeInterval(50)
        trail.restarted(at: clock)
        XCTAssertEqual(change(&trail, to: "b", after: 1, justStarted), .back)
    }

    func testBackThenNextThenPreviousAgain() {
        var trail = Trail()
        _ = change(&trail, to: "b", wellIn())
        _ = change(&trail, to: "c", wellIn())
        // Previous twice from well into c.
        clock = clock.addingTimeInterval(20)
        trail.restarted(at: clock)
        XCTAssertEqual(change(&trail, to: "b", after: 1, justStarted), .back)
        // Next, some way into b.
        XCTAssertEqual(change(&trail, to: "c", after: 15, wellIn(15)), .onward)
        // Previous twice again.
        clock = clock.addingTimeInterval(25)
        trail.restarted(at: clock)
        XCTAssertEqual(change(&trail, to: "b", after: 1, justStarted), .back)
        // And Next straight away, from the first second of b: known to lead to c.
        XCTAssertEqual(change(&trail, to: "c", after: 1, justStarted), .onward)
    }

    func testSteppingBackThroughSeveralSongsStaysBack() {
        var trail = Trail()
        _ = change(&trail, to: "d", wellIn())
        clock = clock.addingTimeInterval(60)
        trail.restarted(at: clock)
        XCTAssertEqual(change(&trail, to: "c", after: 1, justStarted), .back)
        // Each further press comes within a second or two of the last.
        XCTAssertEqual(change(&trail, to: "b", after: 1.5, justStarted), .back)
        XCTAssertEqual(change(&trail, to: "a", after: 1.5, justStarted), .back)
    }

    func testSkippingOnThroughFourSongsAndBackThroughTheSameFour() {
        // Taken from a real run: Next four times, a second apart, then Previous
        // five times, each from the first second or two of a track.
        var trail = Trail()
        _ = change(&trail, to: "s", wellIn())
        XCTAssertEqual(change(&trail, to: "f", wellIn(112)), .onward)
        XCTAssertEqual(change(&trail, to: "y", after: 1.1, justStarted), .onward)
        XCTAssertEqual(change(&trail, to: "m", after: 1.1, justStarted), .onward)
        XCTAssertEqual(change(&trail, to: "n", after: 1.2, justStarted), .onward)
        XCTAssertEqual(change(&trail, to: "m", after: 2.3, Trail.Evidence(previousElapsed: 2.2)), .back)
        XCTAssertEqual(change(&trail, to: "y", after: 1.7, justStarted), .back)
        XCTAssertEqual(change(&trail, to: "f", after: 1.2, justStarted), .back)
        XCTAssertEqual(change(&trail, to: "s", after: 1.1, justStarted), .back)
        // One further back than anything heard here: still back.
        XCTAssertEqual(change(&trail, to: "i", after: 0.9, justStarted), .back)
        // And on again over the same ground is on.
        XCTAssertEqual(change(&trail, to: "s", after: 1, justStarted), .onward)
        XCTAssertEqual(change(&trail, to: "f", after: 1, justStarted), .onward)
    }

    func testPreviousOnceThenNextIsOnward() {
        var trail = Trail()
        _ = change(&trail, to: "a", wellIn())
        _ = change(&trail, to: "b", wellIn())
        // Previous twice from well into b: back to a.
        clock = clock.addingTimeInterval(30)
        trail.restarted(at: clock)
        XCTAssertEqual(change(&trail, to: "a", after: 0.5, justStarted), .back)
        // Well into a: Previous once restarts it, then Next two seconds later.
        clock = clock.addingTimeInterval(40)
        trail.restarted(at: clock)
        XCTAssertEqual(change(&trail, to: "b", after: 2, justStarted), .onward)
    }

    func testSkippingOnQuicklyStaysOnward() {
        var trail = Trail()
        _ = change(&trail, to: "a", wellIn())
        XCTAssertEqual(change(&trail, to: "b", wellIn()), .onward)
        XCTAssertEqual(change(&trail, to: "c", after: 1, justStarted), .onward)
        XCTAssertEqual(change(&trail, to: "d", after: 1, justStarted), .onward)
    }

    func testASongThatEndsIsFollowedByTheNext() {
        var trail = Trail()
        _ = change(&trail, to: "a", wellIn())
        XCTAssertEqual(change(&trail, to: "b", Trail.Evidence(previousEnded: true, previousElapsed: 200)), .onward)
        // So going from the start of b to a is a step back.
        XCTAssertEqual(change(&trail, to: "a", after: 60, justStarted), .back)
    }

    func testAnAlbumGoesByItsTrackNumbers() {
        var trail = Trail()
        _ = change(&trail, to: "three", wellIn())
        XCTAssertEqual(change(&trail, to: "one", Trail.Evidence(previousElapsed: 50, albumOrder: -2)), .back)
        XCTAssertEqual(change(&trail, to: "two", Trail.Evidence(previousElapsed: 1, albumOrder: 1)), .onward)
    }

    func testWhatThisAppAskedForSettlesIt() {
        var trail = Trail()
        _ = change(&trail, to: "a", wellIn())
        XCTAssertEqual(change(&trail, to: "z", Trail.Evidence(asked: .back, previousElapsed: 90)), .back)
        XCTAssertNil(change(&trail, to: "z", wellIn()))
    }
}
