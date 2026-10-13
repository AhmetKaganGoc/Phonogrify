import Foundation

/// Works out whether a change of track was a step on or a step back.
///
/// Spotify says what is playing and never which button was pressed, nor what
/// is in its queue. So this is read from two things.
///
/// **How Spotify's buttons behave:**
/// - Previous only goes back from the first few seconds of a track. Any
///   further in, it restarts the track instead. So a change away from a track
///   that was well under way was *not* Previous: it was Next, or a song picked
///   by hand, which counts as on.
/// - A track that played to its end was followed by the next one.
/// - On one album, the track numbers say which way.
///
/// **The path already walked.** Spotify's own Previous and Next move along the
/// line of tracks it has played, like a browser's back and forward. This keeps
/// that same line, with a marker on the track playing now. When a track that
/// had barely started gives way to the one just behind the marker, that was
/// Previous; to the one just ahead, Next. Skipping on through four songs and
/// then back through the same four reads correctly at every step.
///
/// Only a change from a barely started track to one that is neither behind nor
/// ahead can be either, and then it is taken to carry on the way the listener
/// was already going.
public struct Trail {
    public enum Step: Equatable, Sendable {
        case onward
        case back
    }

    /// What is known about one change of track.
    public struct Evidence: Sendable {
        /// The way this app was asked to go, when it was this app that asked.
        public var asked: Step?
        /// Whether the track before played to its end.
        public var previousEnded = false
        /// How many seconds into the track before the change came.
        public var previousElapsed: Double?
        /// On the same album: positive when the new track comes later, negative when earlier.
        public var albumOrder: Int?

        public init(
            asked: Step? = nil,
            previousEnded: Bool = false,
            previousElapsed: Double? = nil,
            albumOrder: Int? = nil
        ) {
            self.asked = asked
            self.previousEnded = previousEnded
            self.previousElapsed = previousElapsed
            self.albumOrder = albumOrder
        }
    }

    /// How far into a track Previous still goes back instead of restarting it,
    /// with a little margin for when the news of it arrives.
    public var previousWindow = 3.5
    /// How long after a track restarts a change of track still counts as the
    /// second press of Previous.
    public var doublePress = 4.5
    /// How long a run of steps the same way is taken to be still going.
    public var momentum = 7.0

    /// The tracks played, in the order Spotify would step through them, and
    /// where in that line the playing track is.
    public private(set) var tracks: [String] = []
    public private(set) var place = -1

    private var lastStep: (step: Step, at: Date)?
    private var restartedAt: Date?
    private let limit = 80

    public init() {}

    public var current: String? {
        tracks.indices.contains(place) ? tracks[place] : nil
    }

    /// The playing track went back to its own start: one press of Previous.
    public mutating func restarted(at time: Date = Date()) {
        restartedAt = time
    }

    /// Notes that `track` is now playing and says which way that was.
    /// - Returns: `nil` when `track` is already the one playing.
    public mutating func move(to track: String, evidence: Evidence = Evidence(), at time: Date = Date()) -> Step? {
        guard track != current else { return nil }
        defer { restartedAt = nil }
        guard current != nil else {
            tracks = [track]
            place = 0
            lastStep = (.onward, time)
            return .onward
        }

        let isBehind = place > 0 && tracks[place - 1] == track
        let isAhead = place + 1 < tracks.count && tracks[place + 1] == track
        let isSecondPress = restartedAt.map { time.timeIntervalSince($0) <= doublePress } ?? false
        let recent = lastStep.flatMap { time.timeIntervalSince($0.at) <= momentum ? $0.step : nil }
        let wasWellIn = (evidence.previousElapsed ?? 0) > previousWindow

        let step: Step
        if let asked = evidence.asked {
            step = asked
        } else if evidence.previousEnded {
            step = .onward
        } else if let order = evidence.albumOrder, order != 0 {
            step = order > 0 ? .onward : .back
        } else if isSecondPress {
            // Restarted, then changed: Previous twice. Unless it changed to the
            // very track that lies ahead, which is Previous once and then Next.
            step = isAhead && !isBehind ? .onward : .back
        } else if wasWellIn {
            // Too far in for Previous to have changed the track.
            step = .onward
        } else if isBehind, !isAhead {
            step = .back
        } else if isAhead, !isBehind {
            step = .onward
        } else {
            // Barely started, and off the known path: carrying on as before.
            step = recent ?? .onward
        }

        // The line of tracks is kept true to the step taken.
        switch step {
        case .back:
            if isBehind {
                place -= 1
            } else {
                // Back to a track not on the path: it belongs just behind the
                // marker, so that stepping on returns to where this came from.
                tracks.insert(track, at: place)
            }
        case .onward:
            if isAhead {
                place += 1
            } else {
                // A new way on: whatever lay ahead is no longer ahead.
                tracks.removeSubrange((place + 1)...)
                tracks.append(track)
                place = tracks.count - 1
            }
        }
        if tracks.count > limit {
            let extra = tracks.count - limit
            tracks.removeFirst(extra)
            place -= extra
        }
        lastStep = (step, time)
        return step
    }
}
