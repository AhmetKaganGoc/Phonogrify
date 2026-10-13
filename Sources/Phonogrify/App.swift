import AppKit
import SwiftUI

/// Builds the pieces once and keeps them for the life of the app.
@MainActor
final class AppModel {
    let settings = Settings()
    let spotify = SpotifyBridge()
    private let covers = CoverStore()
    private lazy var overlay = Overlay(settings: settings, spotify: spotify, covers: covers)
    private var settingsWindow: NSWindow?

    func start() {
        overlay.start()
        spotify.start()
    }

    /// Opens the Settings window, or brings it forward.
    func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingView(rootView: PanelView(settings: settings, spotify: spotify))
            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Phonogrify"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = host
            window.setContentSize(host.fittingSize)
            window.center()
            settingsWindow = window
        }
        // A menu bar app is never in front by itself; its window has to be brought there.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
        model.start()
    }
}

@main
struct PhonogrifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(settings: delegate.model.settings, spotify: delegate.model.spotify) {
                delegate.model.showSettings()
            }
        } label: {
            Image(nsImage: StatusIcon.image)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// The menu under the menu bar icon: the switches someone reaches for, as an
/// ordinary menu. Everything in full is one item away, in Settings.
struct MenuView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var spotify: SpotifyBridge
    let openSettings: () -> Void

    private struct Choice: Identifiable {
        let name: String
        let value: Double
        var id: Double { value }
    }

    private let lengths = [
        Choice(name: "Very Short", value: 0.4), Choice(name: "Short", value: 0.6),
        Choice(name: "Normal", value: 1.0), Choice(name: "Long", value: 1.35),
        Choice(name: "Very Long", value: 1.7)
    ]
    private let transparencies = [
        Choice(name: "None", value: 1.0), Choice(name: "25%", value: 0.75),
        Choice(name: "50%", value: 0.5), Choice(name: "75%", value: 0.25)
    ]

    var body: some View {
        if let track = spotify.nowPlaying.hanging {
            Text("\(track.title) — \(track.artist)")
            Divider()
        }

        Toggle("Show on Desktop", isOn: $settings.showsOverlay)

        Menu("Cord Length") {
            Picker("Cord Length", selection: $settings.ropeLength) {
                ForEach(lengths) { Text($0.name).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Menu("Transparency") {
            Picker("Transparency", selection: $settings.opacity) {
                ForEach(transparencies) { Text($0.name).tag($0.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Menu("Options") {
            Toggle("Stay Behind Windows", isOn: $settings.staysBehindWindows)
            Toggle("Hide in Full Screen", isOn: $settings.hidesInFullScreen)
            Toggle("Glint on a Loop", isOn: $settings.glintsOnLoop)
            Divider()
            Toggle("Show the Pin at the Top", isOn: $settings.showsPin)
            Toggle("Hang Below the Menu Bar", isOn: $settings.hangsBelowMenuBar)
            Divider()
            Toggle("Open at Login", isOn: Binding(get: { LoginItem.isOn }, set: { LoginItem.set($0) }))
        }

        Divider()
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit Phonogrify") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

enum StatusIcon {
    /// A disc on a cord, drawn as a template so the menu bar colours it.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let cord = NSBezierPath()
            cord.move(to: NSPoint(x: 9, y: 18))
            cord.line(to: NSPoint(x: 9, y: 11.5))
            cord.lineWidth = 1.3
            cord.stroke()
            let disc = NSBezierPath(ovalIn: NSRect(x: 3.75, y: 1, width: 10.5, height: 10.5))
            disc.lineWidth = 1.5
            disc.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 7.6, y: 4.85, width: 2.8, height: 2.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
