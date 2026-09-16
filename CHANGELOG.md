# Changelog

## 0.1.3 — 2026-09-16

- Keep the track drop area visible during first-time model setup, with track
  selection disabled until the model is ready.
- Smooth transitions between setup, inspection, processing, and completion.
- Add real-audio regression coverage for every supported format, metadata,
  embedded artwork, channel layouts, VBR output, and stem mixing.

## 0.1.1 — 2026-09-16

- Added MP3 input with output quality matched to the source, including VBR.
- Improved handling of embedded artwork and unusual audio metadata.
- Added clearer errors for damaged files, missing audio, and tool failures.
- Made cancellation and output replacement safer, with automatic cleanup and
  rollback when processing fails.
- Require the audio model to be ready before a track can be selected.
- Simplified model-download status and show artist alongside the track title.
- Added the Makestem app icon and standardized the Makestem name throughout.
- Expanded automated checks for the CLI, Mac app, and distributable bundle.

## 0.1.0

- Initial testing release for Apple Silicon Macs running macOS 14 or newer.
- Create an acapella, instrumental, or both from a dropped audio track.
- Process audio locally with the `htdemucs_ft` model after its first download.
- Show live separation progress and allow downloads or processing to be
  cancelled without leaving partial files.
- Preserve track metadata and save finished MP3s in a nearby `output` folder.
- Confirm before replacing existing stems and preserve them if processing
  fails.
- Include a command-line interface for Terminal users.
- Package Demucs, FFmpeg, and FFprobe in a signed, notarizable Mac app.
