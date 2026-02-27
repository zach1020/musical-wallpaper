# MusicalWallpaper
Live vaporwave desktop wallpaper for macOS with audio-reactive visuals, 3D model rendering, scrolling neon Greek ticker text, and menu-bar controls.

## What It Does
- Renders behind desktop icons on all monitors
- Reacts to system audio (or microphone fallback)
- Shows a 3D model with slow rotation and beat motion
- Draws waveform, grid warp, stars, neon clock, and click ripples
- Supports full background and desktop-overlay modes

## Requirements
- macOS 13+
- Xcode (recommended) or Command Line Tools with Swift

## Run (Dev)
```bash
cd /Users/zach/Desktop/musical-wallpaper
swift run
```

## Build Standalone Outputs
Builds both:
- `dist/MusicalWallpaper.app` (drag into `/Applications`)
- `dist/MusicalWallpaper-standalone/` (CLI-style executable + resources)

```bash
cd /Users/zach/Desktop/musical-wallpaper
./scripts/build_release.sh
```

Optional debug package:
```bash
./scripts/build_release.sh debug
```

## Permissions
On first launch, allow:
- `Screen Recording`
- `Microphone` (fallback mode)

Location:
- `System Settings -> Privacy & Security`

## Project Layout
- `Sources/MusicalWallpaper/main.swift` — app and renderer
- `Sources/MusicalWallpaper/Resources/` — packaged 3D model assets
- `scripts/build_release.sh` — packaging script for `.app` and binary

## Notes
- This is a live renderer, so CPU/GPU usage is higher than static wallpaper.
- Build artifacts are ignored via `.gitignore` (`.build/`, `dist/`, etc).
