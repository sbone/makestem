# Stemcraft

**Find the blend live. Finish it with Stemcraft.**

Real-time tools such as Serato Stems are invaluable for experimenting: try an idea immediately, discover an unexpected pairing, and find the blends worth finishing. When a real-time separation sounds artifact-heavy or gets part of a track wrong, Stemcraft takes the slower, higher-quality route.

Stemcraft creates pre-processed acapellas and instrumentals for recorded and shareable DJ blends. It runs a fine-tuned Demucs audio-separation model, mixes instrumental stems, encodes 320 kbps MP3s, preserves metadata, and keeps the results organized. After the model is downloaded, every operation runs locally on your computer and your tracks never leave it.

> Serato Stems helps you discover the blend. Stemcraft helps you finish it.

Stemcraft is an independent project and is not affiliated with or endorsed by Serato.

## What it does

- Creates an acapella, an instrumental, or both from a full mix.
- Uses the fine-tuned `htdemucs_ft` audio-separation model for separation quality.
- Combines the drums, bass, and other stems into one instrumental.
- Produces 320 kbps MP3 files in an `output/` directory beside the source.
- Copies source metadata and adds `(Quality Time Acapella)` or `(Quality Time Instrumental)` to the title.
- Shows each processing stage and turns noisy tool failures into concise, useful guidance.
- Downloads the model weights once, then processes everything locally; your audio is never uploaded.

## Install the CLI

Stemcraft is currently an early source release for macOS and Linux. Packaged binaries and a drag-to-Applications Mac app are planned.

### Requirements

- A current [Rust toolchain](https://rustup.rs/)
- [FFmpeg](https://ffmpeg.org/) and FFprobe
- The native [demucs-rs CLI](https://github.com/nikhilunni/demucs-rs)
- A Metal-capable GPU on macOS, or a Vulkan-capable GPU on Linux

On macOS, install FFmpeg with Homebrew:

```sh
brew install ffmpeg
```

Follow the demucs-rs native CLI build instructions, then ensure its `demucs` executable is available on your `PATH`. The fine-tuned audio model is approximately 333 MB and downloads automatically the first time it is used. Its model weights are cached on your computer, and separation runs locally on your GPU. Tracks are not sent to Demucs, Stemcraft, or another online service.

Install Stemcraft from this checkout:

```sh
cargo install --path . --locked
```

Confirm the command is available:

```sh
stemcraft --help
```

If your shell cannot find it, add Cargo's binary directory to your `PATH`:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
```

Add that line to `~/.zshrc` to keep it across new terminal sessions.

## Use it

Change into the folder containing a track, then run:

```sh
stemcraft -a "Track Title.flac"   # acapella only
stemcraft -i "Track Title.flac"   # instrumental only
stemcraft "Track Title.flac"      # both
```

Quotes are recommended for filenames containing spaces. Stemcraft passes paths directly to its tools, so punctuation and Unicode filenames are safe and are not interpreted as shell commands.

Results appear beside the source:

```text
output/
├── Track Title (Quality Time Acapella).mp3
└── Track Title (Quality Time Instrumental).mp3
```

## When something goes wrong

Audio from the wild can contain incomplete downloads, damaged containers, unusual codecs, malformed tags, or unexpected characters. Stemcraft checks the source before starting a long separation and keeps errors short. When possible, it distinguishes an application failure from a source-file, model, codec, permission, or disk-space problem and suggests what to try next.

## Development

```sh
cargo run -- --help
cargo test
cargo clippy -- -D warnings
cargo build --release
```

Build the local Apple Silicon Mac app with Apple Command Line Tools:

```sh
./scripts/build-mac-app.sh
open build/Stemcraft.app
```

This development build uses Demucs and FFmpeg from the local machine. A distributable release will bundle compatible tools and download only the audio-separation model on first use.

The processing pipeline is separate from its terminal presentation and emits structured status events. A future Mac app can present the same workflow with drag-and-drop, queue progress, notifications, and Finder actions without replacing the audio engine.

Longer term, Stemcraft may support multiple audio-separation models, since different models can perform better on different kinds of music. The goal is model choice without model complexity: strong defaults first, with other local models available when a difficult track benefits from another approach.
