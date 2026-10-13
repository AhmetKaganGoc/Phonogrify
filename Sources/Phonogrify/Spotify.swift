import AppKit
import Combine
import PhonogrifyCore

/// Runs AppleScript away from the main thread, one script at a time.
struct ScriptRunner {
    enum Failure: Error {
        case notPermitted
        case notRunning
        case other(Int)
    }

    private let queue = DispatchQueue(label: "phonogrify.scripts", qos: .userInitiated)

    func run(_ source: String) async -> Result<[String], Failure> {
        await withCheckedContinuation { continuation in
            queue.async {
                // Made, run and dropped on this one queue: a script object is not for sharing.
                var info: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: .failure(.other(0)))
                    return
                }
                let reply = script.executeAndReturnError(&info)
                if let info {
                    let code = info[NSAppleScript.errorNumber] as? Int ?? 0
                    switch code {
                    case -1743, -1744: continuation.resume(returning: .failure(.notPermitted))
                    case -600, -609, -10810: continuation.resume(returning: .failure(.notRunning))
                    default: continuation.resume(returning: .failure(.other(code)))
                    }
                    return
                }
                continuation.resume(returning: .success(Self.strings(in: reply)))
            }
        }
    }

    private static func strings(in reply: NSAppleEventDescriptor) -> [String] {
        let count = reply.numberOfItems
        guard reply.descriptorType == typeAEList, count > 0 else {
            return reply.stringValue.map { [$0] } ?? []
        }
        return (1...count).map { reply.atIndex($0)?.stringValue ?? "" }
    }
}

/// What Spotify is playing, and a way to tell it what to do.
///
/// Spotify announces every change of track and state itself, so nothing here
/// polls. Those announcements carry everything but the cover's address, which
/// is asked for once per track. Spotify is never launched by any of this.
@MainActor
final class SpotifyBridge: NSObject, ObservableObject {
    static let bundleID = "com.spotify.client"

    @Published private(set) var nowPlaying = NowPlaying()
    /// False once macOS has refused to let Phonogrify control Spotify.
    @Published private(set) var isPermitted = true

    private let scripts = ScriptRunner()
    private var sending: Task<Void, Never>?
    private var isStarted = false

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Delivered at once even though a menu bar app is never "active".
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playbackChanged(_:)),
            name: Notification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil
        )
        workspace.addObserver(
            self, selector: #selector(appQuit(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
        refresh()
    }

    // MARK: - Hearing from Spotify

    @objc private func playbackChanged(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let state: PlayState
        switch (info["Player State"] as? String ?? "").lowercased() {
        case "playing": state = .playing
        case "paused": state = .paused
        default: state = .stopped
        }
        guard state != .stopped, let id = info["Track ID"] as? String else {
            nowPlaying = NowPlaying()
            return
        }

        var track = Track(
            id: id,
            title: info["Name"] as? String ?? "",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? ""
        )
        let isSameTrack = nowPlaying.track?.id == id
        if isSameTrack {
            track.artworkURL = nowPlaying.track?.artworkURL
        }
        nowPlaying = NowPlaying(state: state, track: track)
        if !isSameTrack || track.artworkURL == nil {
            refresh()
        }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard Self.isSpotify(note) else { return }
        // It says what it is playing when it starts; this is only a second look.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.refresh()
        }
    }

    @objc private func appQuit(_ note: Notification) {
        guard Self.isSpotify(note) else { return }
        nowPlaying = NowPlaying()
    }

    private static func isSpotify(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == bundleID
    }

    /// Asks Spotify outright: at launch, and once per track for its cover.
    func refresh() {
        guard isRunning else {
            nowPlaying = NowPlaying()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.scripts.run(Self.stateScript) {
            case .success(let fields):
                self.isPermitted = true
                self.take(fields)
            case .failure(.notPermitted):
                self.isPermitted = false
            case .failure(.notRunning):
                self.nowPlaying = NowPlaying()
            case .failure(.other):
                break
            }
        }
    }

    private func take(_ fields: [String]) {
        guard fields.count >= 6, let state = PlayState(rawValue: fields[0]), state != .stopped else {
            if fields.first == "stopped" || fields.first == "off" {
                nowPlaying = NowPlaying()
            }
            return
        }
        let track = Track(
            id: fields[1],
            title: fields[2],
            artist: fields[3],
            album: fields[4],
            artworkURL: URL(string: fields[5])
        )
        // A stale answer about a track that has since changed is dropped.
        if let current = nowPlaying.track, current.id != track.id, nowPlaying.state != .stopped {
            return
        }
        nowPlaying = NowPlaying(state: state, track: track)
    }

    // MARK: - Telling Spotify

    /// Commands go one after another, in the order they were asked for.
    func send(_ command: PlayerCommand) {
        guard isRunning else { return }
        if command == .playPause, nowPlaying.track != nil {
            // Shown at once; Spotify's own announcement confirms it a moment later.
            nowPlaying.state = nowPlaying.state == .playing ? .paused : .playing
        }
        let source = Self.script(for: command)
        sending = Task { @MainActor [weak self, previous = sending] in
            await previous?.value
            guard let self else { return }
            if case .failure(.notPermitted) = await self.scripts.run(source) {
                self.isPermitted = false
            } else {
                self.isPermitted = true
            }
        }
    }

    // MARK: - Scripts

    private static func guarded(_ body: String) -> String {
        """
        if application id "\(bundleID)" is running then
            tell application id "\(bundleID)"
        \(body)
            end tell
        end if
        return {"off"}
        """
    }

    private static let stateScript = guarded("""
            set theState to player state as text
            if theState is "stopped" then return {theState}
            set theTrack to current track
            set theCover to ""
            try
                set theCover to (artwork url of theTrack) as text
            end try
            return {theState, id of theTrack, name of theTrack, artist of theTrack, album of theTrack, theCover}
    """)

    private static func script(for command: PlayerCommand) -> String {
        switch command {
        case .playPause: return guarded("        playpause\n        return {\"ok\"}")
        case .next: return guarded("        next track\n        return {\"ok\"}")
        // From the start of a track "previous" goes to the one before; from
        // further in it only restarts this one, which is not what was asked.
        case .previous: return guarded("        set player position to 0\n        previous track\n        return {\"ok\"}")
        }
    }
}
