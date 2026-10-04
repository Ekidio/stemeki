# STEMEKI – stems · loops · remix

🇬🇧 English · [🇭🇺 Magyar](README.hu.md)

**▶ Website:** [ekidio.github.io/stemeki](https://ekidio.github.io/stemeki/) · **⬇ Download:** [latest release (DMG)](https://github.com/Ekidio/stemeki/releases/latest)

![STEMEKI editor](screenshots/stemeki-editor.png)

**STEMEKI** splits any song into stems, locks it to a bar-exact beat grid, lets you rebuild its structure like a mini DAW, and exports **DAW-ready loops**: bar-exact, on a whole BPM, ready to drop into any session.

It's a native macOS app (Swift, Apple Silicon). Separation runs locally with Demucs 4 on the Apple GPU – your music never leaves your Mac.

STEMEKI is an **EKIDIO SOUND** app. See also: [PADEKI](https://github.com/Ekidio/padeki) · [DAWEKI V3](https://github.com/Ekidio/daweki_v3).

## Why it's different

Most stem splitters stop at "here are four files". STEMEKI goes on:

- **Beat grid from the drums.** The tempo and the downbeats come from the separated drum stem, every beat is pinned to its real hit (AUTO WARP), so the grid, the metronome and every cut sit on the audible start of the hits – even when the tempo drifts.
- **CUE = bar 1.** The CUE lands on the very first hit AUTO WARP pins, and AUTO WARP runs again from there. Press **C** at the playhead (also while playing) or drag the flag to make any beat the "one".
- **Rebuild the song.** In **EDIT** mode drag a selection, click to cut, **D** to duplicate, drag pieces around, trim their edges. Pieces overwrite what they cover, like in a DAW.
- **Export the structure, not only the song.** Draw **regions** on the lanes in **EXPORT** mode and save each one as its own loop.

## Features

### Load and prepare
- Drop WAV, AIFF, MP3, M4A or FLAC. The song plays at once while the AI separates it; an animated screen shows the progress.
- **MIX / 2 STEMS / 4 STEMS** views: the whole song as one waveform, vocals + instrumental, or vocals, drums, bass and instruments.
- Precise BPM and key (with Camelot code) detection.

### Beat grid
- **AUTO WARP** pins every beat to its hit; **RESET** goes back to the detection.
- **CUE HERE (C)**, draggable CUE flag, **NUDGE** the music against the grid by ½ beat, 1 beat, ½ bar or 1 bar.
- **CLICK** metronome with a tight tick (higher on the 1) and fine timing by ear (right-click).
- Export tempo: loops are stretched to exactly this BPM (pitch kept), or keep the song's own.

### Edit (EDIT mode)
- Drag = select, click inside = cut, **D** = duplicate (an uncut selection is cut first), ⌥-drag = copy, ⌫ = delete (silence), ⌘Z / ⇧⌘Z = undo / redo.
- Selection and edges snap to the grid by zoom: bars, beats, and closer in **1/8** and **1/16** lines. Trim pieces at their edges.
- **⌘C / ⌘V**: copy the selected pieces (or the audio under a selection), click where it should go (a ⌘V marker appears), paste. Pasting again lines up the next copy right after.
- **U**: the loop takes the start and end of the selected piece or region and follows it when you move or trim it.
- Drag pieces **past the end of the song**: the timeline grows with them, for a longer mix (FROM CUE exports it all).
- **Fades**: drag the small square on a piece's top corner inward for a fade-in / fade-out (double-click removes it). Playback, the loop and every export follow it.
- **RESET** on every lane brings back the freshly separated stem.

### Projects
- **File → Save Project (⌘S)** writes `Title.stemeki`: the stems, edits, fades, regions, grid, CUE, loop and lane levels. Reopen it with **Open Project (⇧⌘O)**, a double-click or by dropping it on the window: ready at once, no new separation.
- A dot in the song list marks unsaved changes; quitting asks before anything is lost.

### Export (EXPORT mode)
| Button | What it saves | Tempo | Edits |
|---|---|---|---|
| **FULL** | the marked lanes as they are, the whole file | original | no |
| **FROM CUE** | from bar 1 to the end – stack them in a DAW from bar 1 | export BPM | yes |
| **LOOP** | the loop range, bar-exact | export BPM | yes |
| **REGIONS** | every region on the marked lanes, one file each | export BPM | yes |

- **SEL. MIX** puts the marked lanes into one file (for example DRUMS+BASS), following the faders.
- Marking a lane off for export also mutes it: you hear what you export.
- Files keep the original format (WAV / AIFF / FLAC, bit depth, sample rate). WAV loops carry **ACID** and **smpl** data (tempo, beats, root, loop points) and a "Made with STEMEKI" note.
- Every export asks for a folder. Names: `Title_DRUMS_127bpm_REGION_17_20.wav`.

| Preparing | First-run intro |
|---|---|
| ![Preparing](screenshots/stemeki-preparing.png) | ![Intro](screenshots/stemeki-intro.png) |

## Keyboard
| Key | Action |
|---|---|
| Space | play / pause |
| Enter | to the start (the view follows with FOLLOW on) |
| L | loop on / off |
| K | metronome on / off |
| C | CUE to the playhead |
| E | EDIT / EXPORT |
| D | duplicate the selection |
| U | loop the selection (the loop follows it) |
| ⌘C / ⌘V | copy / paste at the clicked spot |
| ⌘S / ⇧⌘S | save project / save as |
| ⇧⌘O | open project |
| ⌫ | delete the selection |
| Esc | clear the selection |
| [ / ] | NUDGE the music earlier / later |
| ⌘Z / ⇧⌘Z | undo / redo |
| ⌘E / ⇧⌘E | export LOOP / REGIONS |

## Requirements
- A Mac with Apple Silicon, macOS 14 or later.
- Nothing else. At the first start STEMEKI offers **INSTALL ENGINE**: one click downloads its own AI engine (Python + Demucs 4 + the model, about 300 MB, 1 GB on disk) into `~/Library/Application Support/STEMEKI`. No Terminal, no Python knowledge needed.
- Already have Python 3.10+ with `demucs librosa soundfile`? STEMEKI finds and uses it (pyenv, Homebrew or the system Python), no setup needed.

## Install
1. Download the DMG from the [latest release](https://github.com/Ekidio/stemeki/releases/latest) and drag **STEMEKI** into Applications.
2. The first time, macOS may block it: click **Done**, then **System Settings → Privacy & Security → Open Anyway**.
3. Updates arrive by themselves (Sparkle); you can also use **STEMEKI → Check for Updates…**.

## Build from source
```bash
./build.sh --install     # builds dist/STEMEKI.app and copies it to ~/Applications
./make-dmg.sh            # dist/STEMEKI-<version>.dmg
./make-release.sh        # DMG + signed appcast for a GitHub release
```

---
© 2026 EKIDIO SOUND. Separation by [Demucs](https://github.com/facebookresearch/demucs) (MIT).
