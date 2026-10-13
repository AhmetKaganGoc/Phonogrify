import Combine
import Foundation

/// Everything the user can change, kept in UserDefaults as plain keys.
@MainActor
final class Settings: ObservableObject {
    enum Limits {
        static let ropeLength = 0.4...1.7
        static let discSize = 0.7...1.4
        static let opacity = 0.25...1.0
        static let drop = 0.0...0.6
    }

    /// Called after a change has been stored.
    var onChange: (() -> Void)?

    @Published var showsOverlay: Bool { didSet { put(showsOverlay, "showsOverlay") } }
    /// The cord's length, as a multiple of the standard one.
    @Published var ropeLength: Double { didSet { put(ropeLength, "ropeLength") } }
    @Published var discSize: Double { didSet { put(discSize, "discSize") } }
    @Published var opacity: Double { didSet { put(opacity, "opacity") } }
    /// Where along the top of the screen the cord hangs: 0 far left, 1 far right.
    @Published var position: Double { didSet { put(position, "position") } }
    /// How far down the screen the cord starts, as a fraction of the screen's
    /// height: 0 at the very top.
    @Published var drop: Double { didSet { put(drop, "drop") } }
    @Published var staysBehindWindows: Bool { didSet { put(staysBehindWindows, "staysBehindWindows") } }
    @Published var hidesInFullScreen: Bool { didSet { put(hidesInFullScreen, "hidesInFullScreen") } }
    @Published var glintsOnLoop: Bool { didSet { put(glintsOnLoop, "glintsOnLoop") } }
    /// A small pin drawn where the cord starts, which can be dragged to move it.
    /// Off, the cord simply comes out of nothing.
    @Published var showsPin: Bool { didSet { put(showsPin, "showsPin") } }
    /// Off, the cord hangs from the very top of the screen, across the menu bar.
    @Published var hangsBelowMenuBar: Bool { didSet { put(hangsBelowMenuBar, "hangsBelowMenuBar") } }

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        func bool(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            ((store.object(forKey: key) as? Double) ?? fallback).clamped(to: range)
        }
        showsOverlay = bool("showsOverlay", true)
        // The defaults are how the author has it: a short cord and a slightly
        // small disc, pinned near the top right corner of the screen.
        ropeLength = number("ropeLength", 0.4, Limits.ropeLength)
        discSize = number("discSize", 0.86, Limits.discSize)
        opacity = number("opacity", 1, Limits.opacity)
        position = number("position", 0.91, 0...1)
        drop = number("drop", 0.033, Limits.drop)
        staysBehindWindows = bool("staysBehindWindows", false)
        hidesInFullScreen = bool("hidesInFullScreen", false)
        glintsOnLoop = bool("glintsOnLoop", true)
        showsPin = bool("showsPin", true)
        hangsBelowMenuBar = bool("hangsBelowMenuBar", false)
    }

    private func put(_ value: Any, _ key: String) {
        store.set(value, forKey: key)
        onChange?()
    }

    // MARK: - Counted quietly

    /// Loops and throws are counted and shown nowhere.
    func count(loops: Int = 0, throws thrown: Int = 0) {
        if loops != 0 { store.set(store.integer(forKey: "loopCount") + loops, forKey: "loopCount") }
        if thrown != 0 { store.set(store.integer(forKey: "throwCount") + thrown, forKey: "throwCount") }
    }
}
