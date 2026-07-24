# Z Scribe for macOS

A native macOS media queue and caption review client for Zoom AI Services
Scribe, Translator, and Summarizer. This is the macOS counterpart to
[Z Scribe Desktop for Windows](https://github.com/tanchunsiong/zoom-ai-services-desktop-video-management-client).

## Features

- Persistent drag-and-drop media queue with progress, cancellation, retry, and removal.
- Case-insensitive queue search across filenames, original and translated captions,
  transcript JSON, and summary sidecars, composed with media-status filters.
- English, Simplified Chinese, Japanese, Spanish, and Italian transcription.
- Optional cue-preserving translation, including non-English routes bridged through English.
- Optional Zoom Summarizer output for each job.
- FFmpeg/FFprobe audio extraction with stream copy for compatible AAC, ALAC, and MP3 audio.
- 15-minute audio segmentation by default with two concurrent Scribe calls.
- Source-named VTT, translated VTT, transcript JSON, and summary Markdown sidecars.
- Native AVKit playback, caption timeline seeking, playback speed control, and summary review.
- Per-job and queue cost estimates for Scribe, Translator, and Summarizer.
- Zoom credentials stored in macOS Keychain. Secrets are never written to queue or settings files.

## Requirements

- macOS 14 or newer.
- Swift 6 for development.
- FFmpeg and FFprobe:

  ```bash
  brew install ffmpeg
  ```

- A Zoom Build API key and secret with AI Services access.

The app automatically checks `/opt/homebrew/bin` and `/usr/local/bin` for media
tools. Custom executable paths can be set in Settings.

## Run

```bash
swift run ZScribeMac
```

Open Settings and save the Zoom Build credentials before starting the queue.

## Build an app bundle

```bash
scripts/package-app.sh
open ZScribeMac.app
```

The script creates an ad-hoc signed `ZScribeMac.app`. Distribution outside local
development requires your Apple Developer signing identity and notarization.

## Verify

```bash
swift build
swift run ZScribeCoreChecks
```

## Output and state

Final files are written beside the source media:

- `meeting.vtt`
- `meeting.translated-zh-CN.vtt`
- `meeting.transcript.json`
- `meeting.summary.md`

Queue and non-secret settings are stored under
`~/Library/Application Support/Z Scribe`. Temporary audio parts are deleted as
soon as their Scribe requests complete, and the per-job work directory is
removed after success, failure, or cancellation.

## Architecture

The Swift package has two targets:

- `ZScribeCore`: models, persistence, Keychain, FFmpeg orchestration, WebVTT,
  JWT signing, Zoom HTTP clients, and the processing pipeline.
- `ZScribeMac`: the native SwiftUI and AVKit application shell.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for processing and security details.

## License

MIT. FFmpeg is invoked as an external executable and is not redistributed.
