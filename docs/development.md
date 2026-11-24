# Build, test and release

## Build the app

Use an Apple Silicon Mac, Xcode with first-run setup completed, Python 3, and the system C/C++ compiler and make. Scripts default to `/Applications/Xcode.app/Contents/Developer`; set `DEVELOPER_DIR` if Xcode is elsewhere.

```sh
bash scripts/build-app.sh
```

The first build downloads FFmpeg 8.0.1, dav1d 1.5.4, zimg 3.0.6, libass 0.17.3, FreeType 2.13.3, HarfBuzz 10.4.0 and FriBidi 1.0.16. Build-only pkgconf, Meson and Ninja stay under `.build/`; Meson and Ninja use a project-local Python environment. Network access is needed to fetch uncached sources and build tools.

`scripts/check-media.sh` rejects a stale dependency cache missing subtitle support, HTTPS/SecureTransport or the matching certificate-verification patch. `build-app.sh` rebuilds the engine when that check fails. If changing subtitle dependency recipes, rebuild them explicitly with `bash scripts/build-subtitles.sh`, then rebuild FFmpeg with `bash scripts/build-media.sh`.

The scripts compile with SwiftPM, assemble `dist/Clipper.app`, bundle the transitive private dylib graph, strip build-machine load paths, copy licenses and ad-hoc sign the app. A fresh staging bundle replaces the previous one; the previous bundle moves under `.build/`. Open the new app after quitting an older running copy. No Homebrew libraries or external executables are needed at runtime.

App builds and tests explicitly use SwiftPM's `native` build engine. With the installed Swift 6.4 toolchain, the newer `swiftbuild` engine produced binaries stamped with SDK 14.0 instead of the selected SDK 27.2, causing older AppKit control rendering. `check-app-sdk.py` verifies the linked SDK before packaging. Keep this check when changing build engines or toolchains. SDK version and the macOS 14 deployment target are separate; building against the current SDK does not raise the deployment target.

Old builds are unregistered from Launch Services and stored as `previous-app-<id>.app-backup` folders, with their contents intact. This keeps them out of Finder's Open With menu. Builds also retire older `.app` backups left by previous scripts. To clean those registrations without rebuilding, run `python3 scripts/retire-build-apps.py`. Rename a backup to end in `.app` if it needs to be run again.

Use private `.build/media` and `.build/vendor` directories when rebuilding dependencies in a worktree. The media builder rejects shared dependency symlinks.

## Run tests

Prepare all fixture families, then run the integrated suite:

```sh
bash scripts/build-app.sh
bash scripts/make-fixtures.sh
bash scripts/make-waveform-fixtures.sh
bash scripts/make-subtitle-fixtures.sh
bash scripts/test.sh
```

The baseline and waveform fixture generators need a separate test-only FFmpeg with software encoders. They default to `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`; set `FIXTURE_FFMPEG` to use another installation. This tool and its fixtures are never bundled. Subtitle fixtures use the app's hardware encoder.

Tests need access to WindowServer, IOSurface and VideoToolbox. A restricted filesystem/process sandbox can cause native tests to abort or report hardware encoder errors. Run with native media access. Test outputs and Swift scratch caches stay in `.build/`.

```sh
CLIPPER_SAMPLE=/absolute/path/to/a/4k-video.webm bash scripts/test.sh
bash scripts/test.sh --filter 'UndoRedoTests|SubtitleTests|LoopAuditionTests'
bash scripts/benchmark.sh /absolute/path/to/video.webm 493.5
```

`CLIPPER_SAMPLE` enables real-source decoding, transport, loop and hardware export checks. The benchmark measures exact seeking, frame stepping and decode throughput. Timing checks depend on machine load and measure renderer state rather than physical display/audio latency.

Network tests are opt-in:

| Variable | Coverage |
| --- | --- |
| `CLIPPER_LIVE_TOOLS=1` | Download and verify managed import tools |
| `CLIPPER_NETWORK_TEST=1` | Real managed-tool URL import |
| `CLIPPER_RANGE_NETWORK_TEST=1` | Real yt-dlp with loopback HTTP/range and TLS fixtures |
| `CLIPPER_RANGE_PUBLIC_TEST=1` | Public HTTPS ranged download |

The range downloader tests expect standalone yt-dlp and Deno at `.build/range-tests/Tools/yt-dlp` and `deno`. The loopback certificate-rejection test only needs Python 3, openssl and the bundled FFmpeg. It does not modify system trust. Public-site tests depend on upstream availability.

## Prepare a release

For substantive feature work, consult Claude on planning, questions and code review, and resolve disagreements before delivery. A task-specific user waiver takes precedence.

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `assets/Info.plist`. Record user-visible changes in `CHANGELOG.md`.
2. Run the integrated suite, check `docs/validation.md`, and complete any relevant manual checks. Check shell syntax, plist validity and `git diff --check`.
3. Commit the release changes. Packaging requires a clean working tree so its source archive matches the app.
4. Push a tag matching the app version, such as `v0.6.1`, on the release commit. The [Build macOS release workflow](../.github/workflows/release-macos.yml) packages Clipper on an Apple Silicon runner with Xcode 27.2 and publishes the verified files to GitHub Releases.

To build without publishing, run **Build macOS release** from the Actions tab and download the `Clipper-macOS` artifact, or run `bash scripts/package-release.sh` locally.

The packager reads the version from the plist and creates:

- `dist/Clipper.app`
- `dist/Clipper-<version>-macOS-arm64.zip`
- `dist/Clipper-<version>-Sources.zip`
- `dist/Clipper-<version>-SHA256.txt`

The source ZIP contains the exact Git source archive and commit, release metadata, dependency source tarballs, configure receipt, build recipes, TLS patch and hash, subtitle source checksums and notices. To rebuild elsewhere, extract `Clipper-source.tar`, copy the dependency tarballs into `.build/vendor/`, and follow the build steps above. Uncached build tools may still need network access.

Distribute the app and source ZIPs together with their checksum file. Verify signatures with `codesign --verify --deep --strict dist/Clipper.app`, test both ZIPs with `unzip -tq`, and verify the checksum file from inside `dist/` with `shasum -a 256 -c`. The dependency graph must resolve inside the bundle or to Apple system libraries.

Current builds are ad-hoc signed and target arm64/macOS 14+. Developer ID signing, notarization and runtime testing on macOS 14 are still release follow-ups. No publishing, pushing or tagging is part of the local packaging script.

## Historical feature work

The seven independent feature branches were merged for 0.5.0. Completed work orders, schedules, per-branch handoffs and review-only packagers were removed from main. Their last combined snapshot is available with `git show e9d2c5d:docs/feature-work/README.md`, and the rest of that directory at the same commit. Worktrees and branches are retained for review history. Prototype history and the current UI constraints are recorded in [architecture.md](architecture.md).
