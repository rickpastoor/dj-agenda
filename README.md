# DJ Agenda

A macOS menu bar app that turns Spotify into a radio station that knows your calendar.

In the run-up to your next meeting, a DJ talks over the end of each song: a quick back-announce,
a joke about the track or the meeting, and a countdown ("Nog vijf minuten tot de weekly!").
When the meeting starts, the DJ tells you it's time to go and pauses the music.

- **Spotify on your Mac** (via AppleScript) or **Spotify Connect on a Sonos** (local UPnP plus the
  Sonos audio-clip API, which ducks the music by itself). In "auto" mode the app picks whichever
  is playing.
- **Text** by Mistral Large (default), Claude, the on-device Apple model, or fixed phrases. Every
  generated line is checked against the calendar data, so the DJ can't invent times.
- **Voice** by Voxtral TTS through the Mistral API (default), Voxtral running locally with MLX,
  or the macOS system voice.
- **Dutch or English.** The interface is in Dutch.
- **Smart timing.** The DJ does not talk when nothing is playing. If the meeting starts within two
  minutes of the current song's end, no new song starts. Travel time from Calendar.app becomes a
  "time to leave" announcement.

## Requirements

- macOS 15 or later on Apple Silicon (macOS 26 for the Apple model), Xcode 27 (tested with 27.2)
- A [Mistral API key](https://console.mistral.ai/api-keys) for the default text and voice. Without
  a key the app falls back to the local voice and fixed phrases.

## Build

```sh
xcodebuild -downloadComponent MetalToolchain   # once, needed by MLX
xcodebuild -project DJAgenda.xcodeproj -scheme DJAgenda -derivedDataPath build build
open build/Build/Products/Debug/DJAgenda.app
```

- **Trust the plug-in.** The first time, open the project in Xcode and click **Trust & Enable** for
  the `CudaBuild` plug-in of mlx-swift.
- **Signing.** The app is signed ad hoc by default. To use your own team, create
  `Signing.local.xcconfig` with `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` (see
  `Signing.xcconfig`).

On first launch macOS asks for access to your calendars, permission to control Spotify, and
access to the local network (for Sonos). Paste your API key under **Instellingen → API-sleutels**.

Run the tests with:

```sh
xcodebuild -project DJAgenda.xcodeproj -scheme DJAgenda -derivedDataPath build test
```

Developer notes (in Dutch) are in [CLAUDE.md](CLAUDE.md).

## Privacy

With Mistral or Claude enabled, the title, description and attendee first names of your next
meeting are sent to that API to write the DJ's line. Choose **Lokaal model** or **Vaste zinnen**
to keep everything on your Mac.

## License

MIT, see [LICENSE](LICENSE). The voice reference clips in `DJAgenda/Resources` were made with
Voxtral and are CC BY-NC 4.0 (non-commercial).
