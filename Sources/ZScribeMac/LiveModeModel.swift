import AppKit
import Foundation
import ZScribeCore

struct CaptionCadence: Identifiable, Hashable {
    let milliseconds: Int
    let label: String
    var id: Int { milliseconds }

    static let all = [
        CaptionCadence(milliseconds: 500, label: "500 ms"),
        CaptionCadence(milliseconds: 1_000, label: "1 second"),
        CaptionCadence(milliseconds: 2_000, label: "2 seconds"),
        CaptionCadence(milliseconds: 3_000, label: "3 seconds"),
        CaptionCadence(milliseconds: 5_000, label: "5 seconds"),
        CaptionCadence(milliseconds: 10_000, label: "10 seconds")
    ]
}

enum AudioMeterState {
    case normal, warning, clipping
}

@MainActor
final class LiveModeModel: ObservableObject {
    @Published private(set) var source: LiveAudioSource = .microphone
    @Published var language = "en-US"
    @Published var vocabularyJSON = UserDefaults.standard.string(
        forKey: "liveVocabularyJSON"
    ) ?? "" {
        didSet {
            UserDefaults.standard.set(vocabularyJSON, forKey: "liveVocabularyJSON")
        }
    }
    @Published var automaticGain = false
    @Published var forceCaptionCadence = false
    @Published var cadence = CaptionCadence.all.first {
        $0.milliseconds == 3_000
    }!
    @Published private(set) var status = "Ready to connect"
    @Published private(set) var isConnecting = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isStopping = false
    @Published private(set) var isSpeechActive = false
    @Published private(set) var inputLevel = 0.0
    @Published private(set) var inputLevelLabel = "-- dBFS"
    @Published private(set) var inputLevelState = AudioMeterState.normal
    @Published private(set) var interimTranscript = ""
    @Published private(set) var segments: [LiveTranscriptSegment] = []

    private let vault = KeychainCredentialStore()
    private let client = ZoomLiveScribeClient()
    private var capture: LiveAudioCapture?
    private var sessionTask: Task<Void, Never>?
    private var microphoneCadenceEnabled = false
    private var systemAudioCadenceEnabled = true
    private var clipHoldUntil = Date.distantPast

    var isSessionActive: Bool { isConnecting || isStreaming || isStopping }
    var canStart: Bool { !isSessionActive && vocabularyError == nil }
    var canStop: Bool { (isConnecting || isStreaming) && !isStopping }
    var transcriptText: String { segments.map(\.text).joined(separator: "\n") }
    var segmentCountLabel: String {
        "\(segments.count) completed segment\(segments.count == 1 ? "" : "s")"
    }
    var sourceDetail: String {
        source == .microphone
            ? "Default microphone"
            : "Mac system audio mix"
    }
    var interimCaptionText: String {
        interimTranscript.count <= 320
            ? interimTranscript
            : "..." + interimTranscript.suffix(320)
    }
    var vocabularyError: String? {
        do {
            _ = try ScribeVocabularyJSON.parse(vocabularyJSON)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    var hasVocabulary: Bool {
        !vocabularyJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setSource(_ newSource: LiveAudioSource) {
        guard !isSessionActive, source != newSource else { return }
        if source == .microphone {
            microphoneCadenceEnabled = forceCaptionCadence
        } else {
            systemAudioCadenceEnabled = forceCaptionCadence
        }
        source = newSource
        forceCaptionCadence = newSource == .microphone
            ? microphoneCadenceEnabled
            : systemAudioCadenceEnabled
        status = "Ready to connect"
    }

    func start() {
        guard canStart else { return }
        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    func stop() {
        guard canStop, !isStopping else { return }
        isStopping = true
        status = "Finishing the last speech turn..."
        Task { [weak self] in
            await self?.capture?.stop()
        }
    }

    func abort() {
        capture?.abort()
        sessionTask?.cancel()
        capture = nil
        sessionTask = nil
        isConnecting = false
        isStreaming = false
        isStopping = false
        isSpeechActive = false
        resetMeter()
    }

    func clearTranscript() {
        segments.removeAll()
        interimTranscript = ""
    }

    func copyTranscript() {
        guard !transcriptText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
        status = "Transcript copied"
    }

    private func runSession() async {
        do {
            guard let credentials = try vault.load(), credentials.isComplete else {
                throw liveError("Save Zoom Build credentials in Settings first.")
            }
            let options = LiveScribeOptions(
                language: language,
                vocabularyJSON: vocabularyJSON,
                forcedCaptionIntervalMilliseconds:
                    forceCaptionCadence ? cadence.milliseconds : 0
            )
            try options.validate()

            clearTranscript()
            isConnecting = true
            status = source == .microphone
                ? "Starting microphone..."
                : "Starting system audio..."
            resetMeter()

            let capture = LiveAudioCapture(
                source: source,
                automaticGain: automaticGain
            ) { [weak self] reading in
                Task { @MainActor in self?.updateMeter(reading) }
            }
            self.capture = capture
            try await capture.start()
            status = "Connecting to Zoom Live..."
            try await client.stream(
                frames: capture.frames,
                options: options,
                credentials: credentials
            ) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            status = segments.isEmpty
                ? "Session closed; no speech was transcribed"
                : "Session closed"
        } catch is CancellationError {
            status = "Live session canceled"
        } catch {
            status = "Live transcription failed: \(error.localizedDescription)"
        }

        capture?.abort()
        capture = nil
        sessionTask = nil
        isConnecting = false
        isStreaming = false
        isStopping = false
        isSpeechActive = false
        resetMeter()
    }

    private func handle(_ event: LiveScribeEvent) {
        switch event.type {
        case "session.created":
            status = "Connected; configuring Live mode..."
        case "session.updated":
            isConnecting = false
            isStreaming = true
            status = "Listening"
        case "speech_started":
            isSpeechActive = true
            status = "Speech detected"
        case "speech_stopped":
            isSpeechActive = false
            status = "Transcribing speech turn..."
        case "transcription.completed":
            if let text = event.transcript?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !text.isEmpty {
                segments.append(LiveTranscriptSegment(
                    number: segments.count + 1,
                    text: text
                ))
            }
            interimTranscript = ""
            status = "Listening"
        case "session.closed":
            isSpeechActive = false
            status = "Session closed"
        case "error":
            status = "Zoom Live error: \(event.error ?? "Unknown error")"
        default:
            if let text = event.transcript?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !text.isEmpty {
                interimTranscript = text
                status = "Receiving captions"
            }
        }
    }

    private func updateMeter(_ reading: PCM16LevelReading) {
        let now = Date()
        if reading.isClipping {
            clipHoldUntil = now.addingTimeInterval(1)
        }
        let clipping = now < clipHoldUntil
        inputLevel = clipping ? 1 : PCM16AudioProcessor.normalizedMeter(reading.peakDBFS)
        inputLevelLabel = clipping
            ? "CLIPPING"
            : reading.peakDBFS.isInfinite
                ? "-- dBFS"
                : String(format: "%.1f dBFS", reading.peakDBFS)
        inputLevelState = clipping
            ? .clipping
            : reading.peakDBFS >= -12 ? .warning : .normal
    }

    private func resetMeter() {
        clipHoldUntil = .distantPast
        inputLevel = 0
        inputLevelLabel = "-- dBFS"
        inputLevelState = .normal
    }

    private func liveError(_ message: String) -> NSError {
        NSError(
            domain: "ZScribe.Live",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
