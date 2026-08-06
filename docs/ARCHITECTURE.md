# Architecture

```text
SwiftUI shell
  |-- local credential file (0600)
  |-- AVKit playback and cue timeline
  |-- Live transcription
  |    |-- AVAudioEngine default microphone capture
  |    |-- ScreenCaptureKit system-audio capture
  |    `-- Zoom Scribe Live WebSocket
  `-- MediaPipeline
       |-- JSON queue and settings stores
       |-- ffprobe metadata
       |-- FFmpeg audio extraction
       |-- bounded Zoom Scribe calls
       |-- timeline merge and WebVTT
       |-- Zoom Translator
       `-- Zoom Summarizer
```

## Processing lifecycle

1. Probe the source and reject media without audio.
2. Stream-copy AAC, ALAC, or MP3 when channel count and bitrate are compatible.
3. Decode other formats to 128 kbps MP3 and downmix to at most two channels.
4. Bound each part below an 80,000,000-byte target and the configured duration.
5. Transcribe up to the configured number of parts concurrently.
   HTTP 413 halves the byte target to a 10 MB floor; persistent HTTP 503 halves
   segment duration to a one-minute floor before failing the job.
6. Restore original-timeline timestamps, sort, and renumber all cues.
7. Write the original VTT and transcript JSON atomically.
8. Optionally translate cues while preserving their timestamp markers.
9. Optionally summarize the transcript, reducing oversized input in chunks.
10. Write optional translated VTT and summary sidecars and remove temporary audio.

## Security

The Zoom API key and secret are stored in
`~/Library/Application Support/Z Scribe/credentials.json`, separately from queue and
settings JSON. The file is restricted to the signed-in user with POSIX mode `0600` and
is not read from or written to macOS Keychain. The app validates credentials locally by
signing a one-hour HS256 Zoom Build JWT; the first service request is the authoritative
server-side validation.

HTTP errors include only a bounded response excerpt. Authentication headers and
credentials are never included in application status or persisted events.

Live input is converted in memory to little-endian 16 kHz mono PCM16 and assembled
into approximately 100 ms frames. The client authenticates directly to
`wss://api.zoom.us/v2/aiservices/scribe/live` with the `live-asr` subprotocol, waits
for `session.updated`, then streams binary audio frames. Stop drains the frame stream,
sends `session.close`, and waits for final events. Live audio and transcript events
are not written to disk. ScreenCaptureKit excludes this app's own audio from system
capture. The Live session update contains `config.language`, `audio.format`, and, when
supplied, a validated `config.vocabulary` object. The editor also accepts a complete ASR
request envelope, but extracts only `config.vocabulary`; batch-only config fields and
top-level `reference_id` are not forwarded to the Live session. Until the deployed Live
endpoint completes its schema transition, the client mirrors language, PCM format, and
vocabulary in the accepted top-level fields. Neither form includes VAD configuration.

## Failure and recovery

HTTP 429, 502, 503, and 504 responses, plus transient network errors, receive two
bounded retries. An app session interrupted during a processing state recovers
that job to queued on the next launch. Successful final sidecars are detected
when media is added or the queue is restored, and each completed artifact is
reused independently. Playback sources unsupported by AVKit are normalized into
a content-addressed MOV cache under the work directory.
