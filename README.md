# Phonogrify

Phonogrify hangs the track Spotify is playing from the top of your screen, as a small record on a cord. You can grab the record and use it as a remote.

It runs in the menu bar and has no Dock icon or main window.

## What it does

The record shows the album cover of whatever is playing. When the track changes, the record turns over and the track's name shows under it for a few seconds. Click the record and the name shows again for a second.

You control Spotify by handling the record:

- Pull it straight down and let go to play or pause. The cord gives a little, like the pull-cord on a lamp.
- Throw it all the way round to the right for the next track, or to the left for the previous one. A throw skips once, even if the record goes round several times.

A thin ring turns slowly round the record while music plays and stops when you pause. When nothing is playing, the cord reels in and the record goes up out of sight. It comes back down when a track starts.

## The menu and settings

The menu bar icon opens a normal menu with the everyday switches: show or hide, cord length, transparency and options. Settings… in that menu opens a window with the rest: sliders for cord length, record size, where it hangs on the screen and how faded it is, plus buttons to play, pause and skip.

By default the cord hangs from the very top of the screen and nothing is drawn where it starts. You can hang it from under the menu bar instead, and you can show a small pin at the top of the cord. With the pin showing, you can drag it to move the cord. Otherwise use the Across and Down sliders in Settings.

## Requirements

- macOS 14 or later
- The Spotify desktop app

I have only run it on Apple Silicon.

The first time it runs, macOS asks whether Phonogrify may control Spotify. It needs that permission to read the album cover and to play, pause and skip.

## Building

```sh
./Scripts/build-app.sh      # → dist/Phonogrify.app
swift test                  # the physics and gesture tests
```

It is a Swift package with one build script. You don't need an Xcode project, and it has no dependencies.

## Why it uses so little CPU

- The physics is small. The record is two weights a diameter apart on a cord that cannot stretch, and the cord you see is a chain of twelve light links that follows it. All of it is stepped 240 times a second and costs a few hundred multiplications per step.
- Everything on screen is a Core Animation layer. Moving the record moves a layer, so the app itself redraws nothing.
- The ring, the track name, the turn-over and the glint that runs down the cord after a loop are animations that the system runs.
- While the record is still, the app runs no clock or timer and does not poll for anything. It asks for frames only while something is moving, and asks for fewer once the record has slowed down.

## Privacy

Phonogrify collects nothing. The only network request it makes is for the album cover, once per album, from Spotify's image servers at the address Spotify gives it. Covers are cached in `~/Library/Caches/Phonogrify`.

## Where things are

| Path | What |
|---|---|
| `Sources/PhonogrifyCore` | The pendulum, the gestures and the reel. Pure Swift, with unit tests. |
| `Sources/Phonogrify` | The overlay window, the Spotify bridge and the menu. |
| `Scripts` | The build script and the icon generator. |
| `Support` | `Info.plist` and the entitlements for the app bundle. |

## Acknowledgement

The idea of something hanging from the menu bar on a simulated cord comes from [Hangly](https://github.com/sharancreatedthis/Hangly-Windows), so make sure to check that out too. Phonogrify is a separate app and shares no code or artwork with it.

Phonogrify is not affiliated with or endorsed by Spotify.

## Licence

[MIT](LICENSE)
