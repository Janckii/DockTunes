<img src="docs/icon.png" width="110" align="right" alt="DockTunes icon">

# DockTunes

**A Spotify panel that sits next to the macOS Dock and follows it — as if it were part of it.**

![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-black)
![Swift](https://img.shields.io/badge/Swift-single%20file-orange)
![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue)

*[Deutsche Fassung](README.de.md) — the German version carries the full measurement notes.*

![DockTunes next to the Dock](docs/dock-and-panel.png)

---

## What it does

- **Looks like the Dock, not like a widget.** The fill is measured against the
  Dock, not guessed: it blends by the same straight rule, in light and dark
  mode, with the same one-point light rim top and bottom and no drop shadow.
  Largest remaining deviation: 4 of 255 steps.
- **Follows the Dock** — its height, its width when it magnifies, across
  displays, and it disappears with it in full screen.
- Cover, title, artist, transport buttons, repeat in three states.
- **Progress bar** with elapsed and total time, draggable to seek.
- **Audio meter** driven by Spotify's real output signal, not a canned loop.
- **Live lyrics** with the running line.
- **Add to a playlist** from a picker of your own playlists.
- Scroll over the panel for volume, in steps of 5.
- German or English, following the system language.
- ~1 % of one core at rest, 2 % while playing.

## Screenshots

**The wider you make it, the more it shows.** The steps are not round numbers
but tied to the content — each one brings something visible.

![Width steps](docs/widths.png)

**Lyrics.** Only the current line, wrapped across two when it does not fit.

![Lyrics](docs/lyrics.png)

**Hover** brings up the progress bar with elapsed and total time.

![Hover](docs/hover.png)

| Settings | Playlists |
|---|---|
| ![Menu](docs/menu.png) | ![Playlist picker](docs/playlists.png) |

## Requirements

- macOS 14.2 or newer — the exact Liquid Glass match needs macOS 26, below that
  a fallback material is used
- The Spotify **desktop app** (the web player will not do)
- Xcode Command Line Tools (`xcode-select --install`) — no Xcode project needed

## Install

```bash
git clone https://github.com/Janckii/DockTunes.git
cd DockTunes
bash build.sh
open -a ~/Applications/DockTunes.app
```

`build.sh` compiles the single source file, assembles the bundle in
`~/Applications` and signs it.

### Permissions

On first launch macOS asks for two things:

1. **Accessibility** — the only way to read where the Dock currently sits.
   Without it the panel stays invisible. Restart the app once afterwards.
2. **Control Spotify** — without it DockTunes knows neither the track nor the
   playback state.

The audio meter triggers a third prompt on first playback (recording audio).
It is only analysed; nothing is stored or sent. Turning the meter off avoids
the prompt entirely.

## Using it

| Action | Effect |
|---|---|
| Click the cover or the text | Bring Spotify to the front |
| Transport buttons | Previous, play/pause, next |
| Repeat button | Off → repeat all → repeat one → off |
| Plus button | Open the playlist picker |
| Pointer on the panel | Progress bar with elapsed and total time |
| Drag on the progress bar | Seek within the track |
| Scroll over the panel | Volume in steps of 5; the bar shows it briefly |
| Right-click | Menu with every setting |

Width is set from the right-click menu under **Width** — four steps, different
ones for normal and lyrics mode. If the title does not fit it scrolls: 20
points per second, 2.5 seconds of stillness before each pass.

## Playlists

The plus button opens the picker every time. There is deliberately no
remembered default: without a choice nobody knows where the track goes. Only
playlists you can actually write to are offered — `me/playlists` also returns
every playlist you merely follow, and Spotify answers a write there with 403.

This needs Spotify's web API and a one-time setup:

1. Create an app on [developer.spotify.com](https://developer.spotify.com/dashboard) (free)
2. Set the redirect URI to exactly `http://127.0.0.1:8888/callback`
3. **Settings → User Management → add yourself**, with your name and the
   e-mail of your Spotify account
4. Copy the client ID and paste it on the first click of the plus button

Sign-in uses PKCE, so no secret lives in the app. Credentials land in
`~/Library/Application Support/DockTunes/credentials.json` with mode 0600.

## What does not work

Honest list — things that were tried and did not pan out, or that the
platform does not allow.

**Karaoke with a travelling word.** Needs per-word timestamps. lrclib only has
them per line — checked across several tracks, not a single word mark.
Word-accurate data exists at Musixmatch, Apple Music and Spotify itself, all
three only behind paid or non-public interfaces. It could be guessed, but
singing is not evenly paced; on held notes the marker visibly runs beside the
voice. That would look like karaoke without being it.

**Dragging the width like a window.** The dragging itself worked (a real but
invisible window frame: `.titled` with `.resizable`, `canBecomeKey`, and an
overridden `constrainFrameRect` — macOS otherwise pushes framed windows 50
points out of the Dock area). But the pointer never changed to the resize
cursor, and without that nobody would know they can drag there. Eight attempts,
all without effect: `NSCursor.set()`, `push()`, re-applied ten times a second,
for the whole panel, via `.cursorUpdate`, via `.mouseMoved`, on `.floating`
instead of Dock level, and with the app activated. The cursor is granted by the
active application, and DockTunes never activates — clicks on the panel must
not steal focus. The four menu steps do the same with less fuss.

**Repeat one is not Spotify's.** Its AppleScript only has a yes/no `repeating`
property; there is no third state. Doing it over the web API would need another
permission, a new sign-in and Spotify Premium. So the panel does it itself:
0.6 seconds before the end it seeks back to the start. Two consequences —
Spotify's own interface does not show that state, and the last 0.6 seconds of
the track are cut. On a fade-out you can hear it.

**Lyrics can be wrong or missing.** They come from
[lrclib.net](https://lrclib.net), an open directory with no sign-up; title and
artist of the current track go there, nothing else. A version is only accepted
when the duration (within 4 seconds) **and** the artist match — both as
conditions, not as a ranking, or a same-named piece by another artist ends up
in the panel. If nothing matches, title and artist stay.

**Spotify only.** No Apple Music, no other players. The panel reads Spotify
over AppleScript.

**One private system key.** To match the Dock's fill, `PlayerView.tune` sets the
glass variant via `_variant`. The public steps of `NSGlassEffectView` do not
blend linearly and therefore fit only one single backdrop. The call is guarded
with `responds(to:)`: if the key disappears in a future macOS the app keeps
running, the colour just no longer sits exactly.

**Text over a bright window.** The panel is translucent like the Dock. Over a
very bright window right behind it the white text stays borderline even with
its shadow — a deliberate trade in favour of the Dock look.

### The path is `/items`, not `/tracks`

If adding a track fails with **403**, this is the likely reason, and it is not
your setup: Spotify now refuses the documented path
`/playlists/{id}/tracks`. Its successor `/items` answers normally — same token,
same playlist, same body:

| Call | |
|---|---|
| `GET /me`, `/me/playlists`, `/playlists/{id}` | 200 |
| `GET /search`, `/tracks`, `/albums` | 200 |
| `GET /playlists/{id}/tracks` | **403** |
| `POST /playlists/{id}/tracks` | **403** |
| `GET /playlists/{id}/items` | **200** |
| `POST /playlists/{id}/items` | **201** |

Because everything else answered normally the error looked like a missing
permission — but the permissions were granted correctly, the playlist was the
user's own, and even a completely fresh sign-in changed nothing. Removing needs
a different body too: `{"items": [{"uri": …}]}` instead of `{"tracks": […]}`.

## Configuration

Everything from the right-click menu. In addition, via `defaults`:

```bash
defaults write de.jancko.docktunes volumeStep -int 2          # volume per notch (default 5)
defaults write de.jancko.docktunes followRate -int 30         # dock polls per second
defaults write de.jancko.docktunes rimAlpha -float 0.30       # strength of the light rim
defaults write de.jancko.docktunes shadowStrength -float 0.6  # shadows, 0 = off
defaults write de.jancko.docktunes panelWidth -float 460      # width, normal (from 200)
defaults write de.jancko.docktunes lyricsWidth -float 580     # width in lyrics mode
```

If the panel stays invisible, `/tmp/docktunes-status.txt` says why — which
permission is missing, whether Spotify answers, where the Dock was found.

## Contributing

Everything sits in one file, `DockTunes.swift`. No Xcode project, no package
manager — `bash build.sh` is enough. **Source code and comments are in
German**; the user interface is bilingual.

The icon ships as `icon/DockTunes.icns` and is drawn by `icon/icon.swift` — a
small program, no graphics application needed.

Two things that matter when building on this:

- **Measured, not estimated.** Nearly every number in the source (spacings,
  brightnesses, rim strengths) is there because it was measured, and the
  comment beside it says against what. Anyone changing them should measure
  again — a screenshot and a few lines of pixel comparison are enough. The
  [German README](README.de.md) carries the full log.
- **Drawing inside the glass is expensive.** Every `draw(_:)` inside an
  `NSGlassEffectView` re-blends the whole surface — measured at 1.7 ms per
  pass. The audio meter and the progress bar are `CALayer`s for that reason;
  it was worth about five percentage points of CPU.

## Licence

MIT — see [LICENSE](LICENSE).
