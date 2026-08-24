# MakeStem

**Find the blend live. Finish it with MakeStem.**

Real-time tools such as Serato Stems are invaluable for experimenting: try an idea immediately, discover an unexpected pairing, and find the blends worth finishing. When a real-time separation sounds artifact-heavy or gets part of a track wrong, MakeStem takes the slower, higher-quality route.

MakeStem creates pre-processed acapellas and instrumentals for recorded and shareable DJ blends. It runs a fine-tuned Demucs audio-separation model, mixes instrumental stems, encodes 320 kbps MP3s, preserves metadata, and keeps the results organized. After the model is downloaded, every operation runs locally on your computer and your tracks never leave it.

> Serato Stems helps you discover the blend. MakeStem helps you finish it.

MakeStem is an independent project and is not affiliated with or endorsed by Serato.

## What it does

- Creates an acapella, an instrumental, or both from a full mix.
- Uses the fine-tuned `htdemucs_ft` audio-separation model for separation quality.
- Combines the drums, bass, and other stems into one instrumental.
- Produces 320 kbps MP3 files in an `output/` directory beside the source.
- Copies source metadata and adds `(Acapella)` or `(Instrumental)` to the title.
- Shows each processing stage and turns noisy tool failures into concise, useful guidance.
- Downloads the model weights once, then processes everything locally; your audio is never uploaded.

## Mac app

The initial Mac app supports Apple Silicon and macOS 14 or newer. A
downloadable, notarized DMG is planned. The app bundle includes Demucs,
FFmpeg, and FFprobe; friends will not need Homebrew, Rust, or Terminal.

### Build from source

Building the app itself currently requires:

- A current [Rust toolchain](https://rustup.rs/)
- Apple Command Line Tools (`xcode-select --install`)
- The native [demucs-rs CLI](https://github.com/nikhilunni/demucs-rs)
- A Metal-capable Apple Silicon Mac

Build MakeStem's pinned, self-contained FFmpeg tools:

```sh
./scripts/build-ffmpeg-macos.sh
```

Install the native Demucs CLI from its source checkout:

```sh
git clone https://github.com/nikhilunni/demucs-rs.git
cd demucs-rs
cargo install --path demucs-cli --locked
```

Return to the MakeStem checkout, then build and open the app:

```sh
./scripts/build-mac-app.sh
open build/MakeStem.app
```

This development build is ad-hoc signed for local testing. You can move it
into `/Applications` on the Mac that built it.

The app identifies a missing model on first run and offers to download the
336 MB `htdemucs_ft` model. MakeStem verifies the completed download and
caches it for later runs. After that, separation and encoding happen locally
and your tracks never leave your Mac.

### Use the app

1. Drop a track into the MakeStem window, or choose one from Finder.
2. Review the source check. Lossless FLAC, WAV, and AIFF files are recommended. Compressed files receive a warning but can still be processed.
3. Choose **Both**, **Acapella**, or **Instrumental**.
4. Select **Create Stems** and follow the live separation progress.
5. When processing finishes, reveal the results in Finder or process another track.

Model downloads and audio processing can be cancelled. MakeStem removes
incomplete downloads, temporary stems, and partial output from a cancelled
job so it is safe to retry.

MakeStem blocks files it cannot process reliably, such as unreadable files, unsupported containers, files with no audio stream, and multichannel audio. Errors include concise guidance when possible.

## CLI

Install the command from this checkout:

```sh
cargo install --path . --locked
```

Confirm it is available:

```sh
makestem --help
```

If your shell cannot find it, add Cargo's binary directory to your `PATH`:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
```

Add that line to `~/.zshrc` to keep it across new terminal sessions.

Change into the folder containing a track, then run:

```sh
makestem -a "Track Title.flac"   # acapella only
makestem -i "Track Title.flac"   # instrumental only
makestem "Track Title.flac"      # both
```

Quotes are recommended for filenames containing spaces. MakeStem passes paths directly to its tools, so punctuation and Unicode filenames are safe and are not interpreted as shell commands.

## Output

The app and CLI use the same output behavior. Results are placed in an `output/` directory beside the source track:

```text
output/
├── Track Title (Acapella).mp3
└── Track Title (Instrumental).mp3
```

Files are encoded as 320 kbps MP3s. Source metadata is copied and the appropriate output suffix is added to the track title.

## When something goes wrong

Audio from the wild can contain incomplete downloads, damaged containers, unusual codecs, malformed tags, or unexpected characters. MakeStem checks the source before starting a long separation and keeps errors short. When possible, it distinguishes an application failure from a source-file, model, codec, permission, or disk-space problem and suggests what to try next.

## Development

```sh
cargo run -- --help
cargo test
cargo clippy -- -D warnings
cargo build --release
```

The Mac build bundles compatible Demucs, FFmpeg, and FFprobe executables. A
release downloads only the audio-separation model on first use, verifies its
integrity, and then processes tracks locally.

Longer term, MakeStem may support multiple audio-separation models, since different models can perform better on different kinds of music. The goal is model choice without model complexity: strong defaults first, with other local models available when a difficult track benefits from another approach.
