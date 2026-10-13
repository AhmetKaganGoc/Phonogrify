import Foundation

public struct Track: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURL: URL?
    /// The track's length in seconds, when the player says.
    public var duration: Double?
    /// Where it comes on its album, when the player says: disc, then track.
    public var discNumber: Int?
    public var trackNumber: Int?

    public init(
        id: String,
        title: String,
        artist: String,
        album: String = "",
        artworkURL: URL? = nil,
        duration: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
    }
}

public enum PlayState: String, Sendable {
    case stopped
    case paused
    case playing
}

public struct NowPlaying: Equatable, Sendable {
    public var state: PlayState
    public var track: Track?
    /// How many seconds into the track the player was, and when that was true.
    /// The player says so only when something changes; in between, a playing
    /// track is that much further on.
    public var position: Double?
    public var asOf: Date

    public init(state: PlayState = .stopped, track: Track? = nil, position: Double? = nil, asOf: Date = Date()) {
        self.state = state
        self.track = track
        self.position = position
        self.asOf = asOf
    }

    /// How far through the track it is at `now`, and how many seconds are left.
    /// `nil` when the player has not said where it is or how long the track is.
    public func progress(at now: Date = Date()) -> (fraction: Double, remaining: Double)? {
        guard let position, let duration = track?.duration, duration > 0 else { return nil }
        let elapsed = state == .playing ? max(0, now.timeIntervalSince(asOf)) : 0
        let reached = (position + elapsed).clamped(to: 0...duration)
        return (reached / duration, duration - reached)
    }

    /// The track that belongs on the cord: playing, or paused part-way.
    public var hanging: Track? {
        state == .stopped ? nil : track
    }
}

public enum PlayerCommand: Sendable {
    case playPause
    case next
    case previous
}

public enum Remote {
    /// The one place that says what a loop means. A disc thrown to the right
    /// goes round counter-clockwise on screen, and right is onward.
    public static func command(for loop: Turn) -> PlayerCommand {
        switch loop {
        case .counterClockwise: return .next
        case .clockwise: return .previous
        }
    }
}
