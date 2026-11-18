# Using Clipper

## Open a video

Drop a local file into the window, choose Open Video, press Cmd-O, or use Finder's Open With. MP4, MOV, M4V, MKV, WebM and AVI are supported through the bundled media engine. One video and one selected clip are open at a time. The × beside the source returns to the empty state.

The window fits the source's aspect ratio within the current screen's usable area. The inspector and timeline share a window material and follow system appearance, with native glass on macOS 26 or newer and a material fallback on earlier versions.

Cmd-V in the main window accepts a URL, copied Finder video, local file URL or readable video path. Pasting into a text field keeps normal text-editing behavior.

## Mark the clip

Scrub the filmstrip or drag the amber selection edges. Left/Right steps one decoded frame; Space plays or pauses. I marks the first included frame and O marks the last included frame. Start and End accept seconds or `hh:mm:ss.sss` and snap to source frames, including variable-frame-rate video.

Zoom with the slider, Cmd-plus/Cmd-minus, or a trackpad pinch over the timeline. Cmd-0 fits the whole video. The scrollbar stays visible while there is something to scroll. The episode overview pans the detailed timeline without changing the clip.

Cmd-Z and Shift-Cmd-Z undo and redo trim, speed, crop, resolution, codec, quality, HDR conversion and audio edits. Each completed drag is one entry. Opening or closing a source clears history; text fields keep native text undo. Subtitle controls and timeline navigation are outside edit history. Undo waits for an active edit or frame seek to finish.

Speed in the Clip section slows or speeds up the selected clip, from 0.25× to 4×. It affects playback, encoded previews and exports, and keeps audio pitch unchanged. The section shows the resulting output duration. Start, End and the timeline still use source timestamps, and frame stepping still moves one source frame. Each new video starts at 1×.

## Listen around the cut

Enable Loop Selection with the repeat button or Cmd-L, then press Space. Original repeats the selection; Compare and Output repeat the available encoded sample. Original prepares the next pass in another decoder. A Rewind gap indicator appears when preparation cannot keep up.

The cut-audition button or Shift-Cmd-L plays the last output second before the out boundary once, then holds the last included frame. Shorter selections play in full. Audition uses Original if the encoded sample does not reach the cut. Markers stay unchanged.

Pausing, seeking, stepping, moving a marker or switching modes interrupts the run. Loop stays enabled until switched off or the source closes. Settings changes keep Original playing where possible; invalidating an encoded sample returns to paused Original.

The waveform button beside the zoom controls, or View → Show Audio Waveform, shows peaks for the selected source audio track. It starts off and is hidden without audio. Generation runs in the background while idle, pauses for playback/seeking/export, and reports progress. Switching tracks refreshes it; excluding export audio dims it. Peaks are about 5 ms apart, coarser beyond 83 minutes to bound memory. Two completed tracks are cached until the source closes.

## Frame and encode

Choose Original, 16:9, 9:16, 1:1, 4:5 or a custom width:height ratio. Drag the crop to reposition it or use its lower-right handle to resize it. Resolution presets limit the longest edge and never enlarge the crop.

SDR starts with H.264 at balanced quality. H.265 is also available. Explicit codec and quality choices are remembered between videos and launches. HDR temporarily selects HEVC Main10 without changing the preferred SDR codec; Convert to SDR restores that preference. Trim, speed, crop, resolution and audio reset for each video.

Both codecs use hardware encoding only. An unsupported size produces an error. All exports re-encode the video and preserve every selected frame, with source timing scaled by Speed. The quality slider does not promise a particular file size.

Exclude audio mutes the export. A track picker appears only when there is more than one source audio track; the whole audio section is hidden without audio. Included audio exports as stereo AAC.

Preview 5 s renders up to five output seconds from the playhead within the selected clip using the export settings. Original, Compare and Output become available after rendering. Compare's draggable wipe shows the original crop beside the encoded result. Frame steps align both sides. Editing invalidates the sample.

## Burn in subtitles

Enable Subtitles, then select a container text track or choose an external SRT, WebVTT, ASS or SSA file. Container/External tabs appear only when supported container tracks exist. A single container track needs no picker; multiple tracks do. Bitmap subtitles are unsupported.

The textformat button opens an anchored style popover. Unstyled subtitles start with white Helvetica Neue, a black outline and shadow, bottom placement and 5% margins. Font, size, colors, outline or background box, shadow, placement and margins are configurable.

ASS/SSA keeps authored styles and layout by default. Override authored style uses the same common style as unstyled subtitles. It removes positioning, animation, karaoke and colors; bold, italic and underline remain. Drawings and hidden placeholders are omitted. Common styling uses output coordinates, while authored styling uses the source frame and may be cut off by cropping.

External files accept UTF-8 or UTF-16. Clipper keeps an imported snapshot until the video closes; selecting the file again reloads changes. WebVTT cue positioning and CSS are not retained. Fonts attached to media can be used; system fonts come from CoreText.

Burn-in is visible in the source viewer and encoded preview, and is permanent in the exported picture. HDR burn-in currently requires Convert to SDR. For a verified URL range import, external subtitle cues use original-video time; otherwise they use local section time.

## Save and share

Export Clip, or Cmd-E, writes a unique MP4 beside a local source. The folder segment or Shift-Cmd-E opens Save As. URL imports always open the save dialog. Save dialogs start in the last confirmed save folder, falling back to Downloads, then home if necessary. Cancelling a dialog leaves that preference unchanged.

Save As honors macOS's Replace confirmation for an existing output. The source video and its aliases are protected. Rendering writes a sibling temporary file and publishes only after success; cancellation or failure leaves the previous output intact. A destination created while rendering a new filename is not silently replaced.

After export, drag the file icon or filename into another app, or use Copy and paste the file. Finder drops copy it. Show in Finder reveals it. Moving or removing the output disables these actions until it returns or another export succeeds.

## Import from a URL

Choose Import URL or Shift-Cmd-O. Paste a URL and press Download for the default best video/audio selection. Cmd-Enter or the split button's format icon opens a table of format IDs, containers, resolutions, frame rates, sizes and codecs. Select video and audio, or No audio. A combined format keeps its included audio unless No audio is selected. Enter downloads the selections in the table.

Format lookup starts in the background and is reused by Download and the format table. Active progress appears in the button; its format icon becomes Cancel. Closing the importer cancels its work.

For part of a long video, enable Import a rough time range and enter original-video start/end times, such as `08:00` and `08:30`. Clipper asks for five seconds of padding on each side and may include an earlier keyframe. The editor displays original-video timestamps and exports using the verified local offset. A timestamp link may suggest a 30-second range, but full import stays the default. Range mode requires a finite end.

An unsupported or unverifiable range offers Import full video instead of silently downloading everything. Savings depend on the server, index and format. Ranged imports omit subtitles/data, round container timestamps to milliseconds, and disable yt-dlp fixups, including uncommon stretched-aspect corrections. Keyframe gaps longer than 60 seconds, live streams, DRM and some encrypted HLS formats are unsupported.

Downloaded sources are temporary. Closing or replacing the source, or quitting, removes them. On launch, Clipper also removes abandoned workspaces after a crash while preserving running instances' files. Exported clips survive cleanup. Save As rejects disposable import folders.

Clipper manages standalone yt-dlp and Deno in `~/Library/Application Support/Clipper/Tools`. It downloads them from official GitHub releases, checks SHA-256, architecture and version, and checks for stable updates once per day while importing. A failed lookup can refresh sooner, at most once per hour. Failed updates retain the installed tool and surface the update problem if import also fails. System yt-dlp, Python, Deno and FFmpeg are not used.

First use needs internet access to GitHub. Verification trusts HTTPS and GitHub's published checksums rather than independent upstream GPG signatures. Proxy environment variables pass through; macOS proxy settings are not automatically translated. Playlists, audio-only downloads and browser-cookie authentication are unsupported. Site support follows the installed [yt-dlp release](https://github.com/yt-dlp/yt-dlp).

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Cmd-O | Open video |
| Shift-Cmd-O | Import URL |
| Cmd-V | Paste URL or video into the main window |
| Shift-Cmd-W | Close video |
| Space | Play or pause |
| Left / Right | Previous / next frame |
| I / O | Mark first / last included frame |
| Cmd-L | Toggle selection loop |
| Shift-Cmd-L | Audition the cut |
| Cmd-Z / Shift-Cmd-Z | Undo / redo |
| Cmd-plus / Cmd-minus | Zoom timeline |
| Cmd-0 | Fit timeline |
| Cmd-E | Export clip |
| Shift-Cmd-E | Export clip as |
| Cmd-Enter | Open formats in the URL importer |
