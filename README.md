# Z Scribe for macOS

A native macOS media queue and caption review client for Zoom AI Services
Scribe, Translator, and Summarizer. This is the macOS counterpart to
[Z Scribe Desktop for Windows](https://github.com/tanchunsiong/zoom-ai-services-desktop-video-management-client).

## Features

- Persistent drag-and-drop media queue with progress, cancellation, retry, and removal.
- Case-insensitive queue search across filenames, original and translated captions,
  transcript JSON, and summary sidecars, composed with media-status filters.
- Live microphone or Mac system-audio transcription over Zoom Scribe's authenticated
  WebSocket endpoint, with an input meter, auto gain, per-session vocabulary JSON,
  interim words, and completed speech turns.
- English, Simplified Chinese, Japanese, Spanish, and Italian transcription.
- Optional cue-preserving translation, including non-English routes bridged through English.
- Optional Zoom Summarizer output for each job.
- FFmpeg/FFprobe audio extraction with stream copy for compatible AAC, ALAC, and MP3 audio.
- 15-minute audio segmentation by default with two concurrent Scribe calls.
- Adaptive HTTP 413 and 503 recovery using progressively smaller uploads and segments.
- Existing sidecars are reused independently so interrupted jobs resume only missing work.
- Source-named VTT, translated VTT, transcript JSON, and summary Markdown sidecars.
- Native AVKit playback with cached FFmpeg compatibility conversion, caption seeking,
  playback speed control, and summary review.
- Per-job and queue estimated/actual costs and processing times; time estimates learn
  from completed jobs in the current queue.
- Summary normalization removes overlapping duplicate subsections, with explicit reruns.
- Recursive folder import, duplicate jobs, retry-all, and active-job auto-follow.
- Zoom credentials stored in a local, user-readable-only Application Support file.

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

For Live transcription, open Live, choose Microphone or System Audio, select the
language, and start the session. macOS requests Microphone permission for microphone
capture and Screen and System Audio Recording permission for the system mix. Live PCM
and transcripts remain in memory unless the transcript is explicitly copied.

The optional vocabulary editor accepts a vocabulary object, a top-level `vocabulary`
object, or a full ASR payload containing `config.vocabulary`. The app validates phrases,
pronunciations, and aliases locally, remembers the JSON between launches, and sends the
vocabulary object as `config.vocabulary` in the Live session update. A ready-to-use
example is provided on first launch. Stopping drains buffered frames and waits for Zoom
to finalize the last speech turn.

## Build an app bundle

```bash
scripts/package-app.sh
open ZScribeMac.app
```

The script creates an ad-hoc signed `ZScribeMac.app` with the fixed bundle identifier
`com.tanchunsiong.ZScribeMac` and a stable designated requirement so macOS permission
grants survive local rebuilds. Run the packaged app, rather than `swift run`, when testing
Microphone and Screen and System Audio Recording permissions. Distribution outside local
development still requires your Apple Developer signing identity and notarization.

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

Queue, settings, and `credentials.json` are stored under
`~/Library/Application Support/Z Scribe`. The credential file contains the API key and
secret as local JSON with POSIX mode `0600`; it is not stored in Keychain. Temporary audio
parts are deleted as soon as their Scribe requests complete, and the per-job work
directory is removed after success, failure, or cancellation.

## Architecture

The Swift package has two targets:

- `ZScribeCore`: models, local persistence, FFmpeg orchestration, WebVTT,
  JWT signing, Zoom HTTP and Live WebSocket clients, and the processing pipeline.
- `ZScribeMac`: the native SwiftUI, AVKit, AVAudioEngine, and ScreenCaptureKit shell.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for processing and security details.

## License

MIT. FFmpeg is invoked as an external executable and is not redistributed.
