// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Phonogrify",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that can be reasoned about without a screen: the pendulum,
        // the gestures, the reel. Pure Swift, unit-tested.
        .target(name: "PhonogrifyCore"),
        // The app itself: the overlay window, Spotify, the menu panel.
        .executableTarget(name: "Phonogrify", dependencies: ["PhonogrifyCore"]),
        .testTarget(name: "PhonogrifyCoreTests", dependencies: ["PhonogrifyCore"])
    ]
)
