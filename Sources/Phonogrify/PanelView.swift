import PhonogrifyCore
import ServiceManagement
import SwiftUI

enum Palette {
    static let green = Color(red: 0.114, green: 0.725, blue: 0.329)
    static let black = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let dim = Color.white.opacity(0.6)
}

enum LoginItem {
    static var isOn: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ wanted: Bool) {
        if wanted {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}

/// The Settings window: what is playing, and every setting in full.
struct PanelView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var spotify: SpotifyBridge
    @State private var launchesAtLogin = LoginItem.isOn

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            nowPlaying
            rule
            sliders
            rule
            switches
            rule
            footer
        }
        .padding(16)
        .frame(width: 290)
        .foregroundStyle(.white)
        .tint(Palette.green)
        .background(Palette.black)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.green, lineWidth: 1.5))
        // Room round the card, and above it for the window's close button.
        .padding(EdgeInsets(top: 30, leading: 10, bottom: 10, trailing: 10))
        .background(Palette.black)
        .environment(\.colorScheme, .dark)
    }

    private var rule: some View {
        Rectangle().fill(Palette.green.opacity(0.28)).frame(height: 1)
    }

    // MARK: - Playing

    @ViewBuilder private var nowPlaying: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PHONOGRIFY")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.6)
                    .foregroundStyle(Palette.green)
                Text(headline)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subline)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }

        if !spotify.isPermitted {
            Button("Open Automation Settings…") {
                let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.bordered)
        } else {
            HStack(spacing: 22) {
                Spacer()
                transport("backward.fill", .previous)
                Button { spotify.send(.playPause) } label: {
                    Image(systemName: spotify.nowPlaying.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Palette.green))
                }
                .buttonStyle(.plain)
                transport("forward.fill", .next)
                Spacer()
            }
            .disabled(!spotify.isRunning)
            .opacity(spotify.isRunning ? 1 : 0.4)
        }
    }

    private func transport(_ symbol: String, _ command: PlayerCommand) -> some View {
        Button { spotify.send(command) } label: {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
    }

    private var headline: String {
        if !spotify.isPermitted { return "Not allowed to control Spotify" }
        return spotify.nowPlaying.hanging?.title ?? (spotify.isRunning ? "Nothing playing" : "Spotify isn’t running")
    }

    private var subline: String {
        if !spotify.isPermitted { return "Turn Phonogrify on under Automation, then play something." }
        if let track = spotify.nowPlaying.hanging { return track.artist }
        return "The disc comes down when a track starts."
    }

    // MARK: - Settings

    private var sliders: some View {
        VStack(spacing: 8) {
            slider("Cord", $settings.ropeLength, Settings.Limits.ropeLength)
            slider("Disc", $settings.discSize, Settings.Limits.discSize)
            slider("Across", $settings.position, 0...1)
            slider("Down", $settings.drop, Settings.Limits.drop)
            slider("Fade", Binding(get: { 1 - settings.opacity }, set: { settings.opacity = 1 - $0 }), 0...0.75)
        }
    }

    private func slider(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.system(size: 12)).frame(width: 46, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small)
        }
    }

    private var switches: some View {
        VStack(spacing: 7) {
            toggle("Show on the desktop", $settings.showsOverlay)
            toggle("Stay behind windows", $settings.staysBehindWindows)
            toggle("Hide in full screen", $settings.hidesInFullScreen)
            toggle("Glint on a loop", $settings.glintsOnLoop)
            toggle("Show the pin at the top", $settings.showsPin)
            toggle("Hang below the menu bar", $settings.hangsBelowMenuBar)
            toggle("Open at login", Binding(get: { launchesAtLogin }, set: { setLogin($0) }))
        }
    }

    private func toggle(_ name: String, _ value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(name).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }

    private func setLogin(_ wanted: Bool) {
        LoginItem.set(wanted)
        // Whatever the system actually agreed to.
        launchesAtLogin = LoginItem.isOn
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Text("Pull down: play or pause\nLoop right: next · Loop left: previous\nWith the pin shown, drag it to move the cord.")
                .font(.system(size: 10))
                .foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("© 2026 Ahmet Kağan Göç")
                .font(.system(size: 8))
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
