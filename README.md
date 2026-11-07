<img src="assets/icon.svg" width="64" height="64" alt="">

# Clipper

A native Mac app for cutting a precise clip. Drop a video, mark its start and end, adjust the framing, and export an MP4.

Clipper opens MP4, MOV, MKV, WebM and AVI without preparing a proxy. The zoomable filmstrip, frame stepping and editable timestamps use actual decoded frames. Crop presets, downscaling, a quality slider and hardware H.264/H.265 encoding cover the export settings.

## Run

Open `Clipper.app`, or move it to Applications. The app includes its media engine and needs no Homebrew or terminal. It runs on Apple Silicon Macs with macOS 14 or newer. Local editing works offline; URL imports download their tools on first use.

Builds are currently ad-hoc signed. A shared copy may need approval in System Settings → Privacy & Security on first launch. Developer ID signing and notarization are not configured yet.

1. Drop a video, use Open Video, or paste a video URL with Cmd-V.
2. Use Space to play, Left/Right to step frames, and I/O to mark the first and last included frames.
3. Adjust crop, resolution, quality or audio. Preview 5 s renders an actual sample for Original/Compare/Output inspection.
4. Export Clip saves beside a local source. The folder segment opens Save As. URL imports always ask where to save.

The editor also supports undo/redo, selection looping, cut audition, an optional audio waveform, copy/drag of exported files, remembered export preferences, rough URL range imports and burned-in subtitles.

- [Usage and shortcuts](docs/guide.md)
- [Build, test and release](docs/development.md)
- [Architecture and UI decisions](docs/architecture.md)
- [Release notes](CHANGELOG.md)
- [Validation and known limits](docs/validation.md)
- [Third-party notices](docs/third-party-notices.txt)

## Build

With Xcode's first-run setup completed, run:

```sh
bash scripts/build-app.sh
```

The first build downloads and compiles the media dependencies. The result is `dist/Clipper.app`. See the development guide for prerequisites and tests.

From a clean commit, `bash scripts/package-release.sh` creates versioned app and source ZIPs plus SHA-256 checksums in `dist/`. Share both ZIPs together so recipients have the matching dependency sources and build recipes.
