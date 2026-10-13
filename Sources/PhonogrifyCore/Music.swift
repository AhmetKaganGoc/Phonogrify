import Foundation

public struct Track: Equatable, Sendable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    public var artworkURL: URL?

    public init(id: String, title: String, artist: String, album: String = "", artworkURL: URL? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
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

    public init(state: PlayState = .stopped, track: Track? = nil) {
        self.state = state
        self.track = track
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
