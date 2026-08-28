<img src="docs/icon.png" width="96" align="right" alt="Icon">

# DockTunes

A Spotify panel that sits next to the Dock and follows it — as if it were part
of it.

*[Deutsche Fassung](README.de.md) — the German version carries the full
measurement notes.*

![DockTunes next to the Dock](docs/dock-and-panel.png)

It shows the cover, title and artist of the current track, has transport
buttons, a progress bar with elapsed and total time, an audio meter that
reacts to the real output signal, and can file the track into a playlist.
On request it shows the running lyrics instead of cover and title.

The interface follows the system language: German on a German Mac, English
everywhere else.

## Requirements

- macOS 14.2 or newer (Liquid Glass from macOS 26, a fallback below that)
- The Spotify desktop app
- Xcode Command Line Tools (`xcode-select --install`) — no Xcode project needed

## Build and run

```bash
git clone https://github.com/Janckii/DockTunes.git
cd DockTunes
bash build.sh
open -a ~/Applications/DockTunes.app
```

`build.sh` compiles the single source file, assembles the app bundle in
`~/Applications` and signs it.

## Permissions

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
| Scroll over the panel | Volume, in steps of 5; the bar shows it briefly |
| Right-click | Menu with every setting |

## Width

The width is **fixed** and does not follow the title. A width that tracked the
text would differ for every song and keep the panel in motion.

Set it from the right-click menu under **Width**, in four steps (normal
250 / 380 / 520 / 640, in lyrics mode 420 / 520 / 640 / 760). The steps are not
round numbers but tied to the content: each one brings something visible.
In-between values via `panelWidth` and `lyricsWidth`, see Settings; the panel
refuses anything below 200 points.

**The wider it gets, the more it shows:**

| from | added |
|---|---|
| 200 | cover, title, artist, play/pause, next |
| 240 | audio meter (if switched on in the menu) |
| 300 | previous |
| 360 | playlist button |
| 520 | album, plus the progress bar and times permanently instead of on hover |
| 700 | in lyrics mode: the next line as a preview |

The order follows usefulness: **next** matters more than previous, and both
more than the plus — so the narrowest panel carries the next button, not the
playlist one.

**If the title does not fit, it scrolls** — endlessly, at 20 points per second
with 40 points between passes. Each pass starts with 2.5 seconds of stillness
so the beginning can be read. Title only; the artist is still truncated, and in
lyrics mode the line wraps instead of scrolling.

## Lyrics

Switch it on from the right-click menu. Instead of cover and title the panel
then shows the running line of the song.

Only the **current** line is shown, wrapped across two lines when it does not
fit on one. A dimmed preview of the next line would cost the running line its
room; above 700 points of width it comes back, where it takes nothing away.
If two lines are not enough the text is visibly truncated rather than silently
cut.

A new line eases in and fades up over 260 ms — otherwise the text simply stands
there differently and the change goes unnoticed. Before the first line and
during instrumental passages the title and artist stand there instead of an
empty surface.

Lyrics come from [lrclib.net](https://lrclib.net), an open directory with no
sign-up. Title and artist of the current track go there — nothing else.

A version is only accepted when the **duration** (within 4 seconds) **and** the
artist match. Both as conditions, not merely as a ranking — otherwise a
same-named piece by a different artist ends up in the panel. If nothing
matches, title and artist stay.

The timestamps are **per line, not per word** — a karaoke mode with a
travelling word could only be guessed from them. See "What does not work".

## Playlists

The plus button opens the picker — always, not just the first time. There is
deliberately no remembered default: without a choice nobody knows where the
track goes, and the last one used is rarely the one wanted. After adding, the
name of the list stands in the subtitle for a moment.

Only playlists you can actually write to are offered. `me/playlists` also
returns every playlist you merely follow, and Spotify answers a write there
with 403. (Measured on a real account: 12 of 23 entries were other people's.)

This does not work over AppleScript — Spotify has no command for it — but over
Spotify's web API. That needs a one-time setup:

1. Create an app on [developer.spotify.com](https://developer.spotify.com/dashboard) (free)
2. Set the redirect URI to exactly `http://127.0.0.1:8888/callback`
3. **Settings → User Management → add yourself**, with your name and the
   e-mail of your Spotify account
4. Copy the client ID and paste it on the first click of the plus button

Step 3 is easy to miss and one possible cause of "Could not add track – error
403".

### The path is `/items`, not `/tracks`

A 403 when adding has a second, far less obvious cause, and it cost hours here:
**Spotify now refuses the documented path `/playlists/{id}/tracks` with 403.**
Its successor `/items` answers normally — same token, same playlist, same body:

| Call | |
|---|---|
| `GET /me` | 200 |
| `GET /me/playlists` | 200 |
| `GET /playlists/{id}` | 200 |
| `GET /search`, `/tracks`, `/albums` | 200 |
| `GET /playlists/{id}/tracks` | **403** |
| `POST /playlists/{id}/tracks` | **403** |
| `GET /playlists/{id}/items` | **200** |
| `POST /playlists/{id}/items` | **201** |

Because everything else answered normally the error looked like a missing
permission — but the permissions were granted correctly (Spotify itself names
them when the token is refreshed), the playlist was the user's own, and even a
completely fresh sign-in changed nothing.

Removing has a different body too: `{"items": [{"uri": …}]}` instead of
`{"tracks": […]}`.

Sign-in uses PKCE, so no secret lives in the app. The credentials land in
`~/Library/Application Support/DockTunes/credentials.json` with mode 0600.

The file is deliberately written **without** `.completeFileProtection`. That
protection class comes from the iOS world and makes the file unreadable on
macOS — measured, it was then refused with "Operation not permitted" even for
the app itself and for the owner, although the mode was 0600. The protection
here is the file permissions.

## Settings

Everything from the right-click menu. In addition, via `defaults`:

```bash
defaults write de.jancko.docktunes volumeStep -int 2      # volume per notch (default 5)
defaults write de.jancko.docktunes followRate -int 30     # dock polls per second
defaults write de.jancko.docktunes rimAlpha -float 0.30   # strength of the light rim
defaults write de.jancko.docktunes shadowStrength -float 0.6  # shadows, 0 = off
defaults write de.jancko.docktunes panelWidth -float 460  # width, normal (from 200)
defaults write de.jancko.docktunes lyricsWidth -float 580 # width in lyrics mode
```

## What does not work

**Karaoke with a travelling word.** That needs per-word timestamps. lrclib only
delivers them per line — checked across several tracks, not a single word mark.
Word-accurate data exists at Musixmatch, Apple Music and Spotify itself, all
three only behind paid or non-public interfaces.

It could be guessed (spread the line duration across the words, weighted by
length), but singing is not evenly paced: on held notes and pauses inside a
line the marker visibly runs beside the voice. That would look like karaoke
without being it.

What would be honest: a bar that travels once from left to right through the
line over its duration. It is exact at both ends and claims nothing about
individual words in between.

**Dragging the width with the mouse, like a window.** Tried and removed again.
The dragging itself worked (a real but invisible window frame: `.titled` with
`.resizable`, plus `canBecomeKey` and an overridden `constrainFrameRect` —
macOS otherwise pushes framed windows 50 points out of the Dock area). But the
pointer never changed to the resize cursor at the edge, and without that the
hint that you can drag there is missing.

Eight attempts at the cursor, all without effect: `NSCursor.set()`, `push()`,
re-applied ten times a second, for the whole panel surface, via a
`.cursorUpdate` zone, via a `.mouseMoved` zone, on `.floating` instead of Dock
level, and with the app activated. The cursor is granted by the active
application, and DockTunes never activates — clicks on the panel must not steal
focus. `mouseEntered` still reaches a window without focus, `mouseMoved` and
`cursorUpdate` no longer do.

The four steps in the menu do the same with less fuss.

## Contributing

Everything sits in one file, `DockTunes.swift`. No Xcode project, no package
manager — `bash build.sh` is enough. **Source code and comments are in
German**; the user interface is bilingual.

The icon ships as `icon/DockTunes.icns` and is drawn by `icon/icon.swift` — a
small program, no graphics application needed:
`swiftc -O -o icongen icon/icon.swift && ./icongen icon.png`, then `iconutil`
for the `.icns`.

Two things that matter when building on this:

- **Measured, not estimated.** Nearly every number in the source (spacings,
  brightnesses, rim strengths) is there because it was measured, and the
  comment beside it says against what. Anyone changing them should measure
  again — a screenshot and a few lines of pixel comparison are enough.
- **One private system key.** To match the Dock's fill, `PlayerView.tune` sets
  the glass variant via `_variant`. The public steps of `NSGlassEffectView` do
  not blend linearly and therefore only fit one single backdrop. The call is
  guarded with `responds(to:)`: if the key disappears in a future macOS the app
  keeps running, the colour just no longer sits exactly.

## Licence

See [LICENSE](LICENSE).
