import AppKit
import Foundation
import ZScribeCore

enum AudioMeterState {
    case normal, warning, clipping
}

@MainActor
final class LiveModeModel: ObservableObject {
    @Published private(set) var source: LiveAudioSource = .microphone
    @Published var language = "en-US" {
        didSet {
            if translationLanguage == language {
                translationLanguage = ""
            }
        }
    }
    @Published var translationLanguage = UserDefaults.standard.string(
        forKey: "liveTranslationLanguage"
    ) ?? "" {
        didSet {
            UserDefaults.standard.set(translationLanguage, forKey: "liveTranslationLanguage")
        }
    }
    @Published var vocabularyJSON: String = {
        let defaults = UserDefaults.standard
        let key = "liveVocabularyJSON"
        let sampleVersionKey = "liveVocabularySampleVersion"
        let saved = defaults.string(forKey: key)
        if defaults.integer(forKey: sampleVersionKey) < 2 {
            defaults.set(2, forKey: sampleVersionKey)
            if saved?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                defaults.set(ScribeVocabularyJSON.sample, forKey: key)
                return ScribeVocabularyJSON.sample
            }
        }
        guard defaults.object(forKey: key) != nil else {
            return ScribeVocabularyJSON.sample
        }
        return saved ?? ""
    }() {
        didSet {
            UserDefaults.standard.set(vocabularyJSON, forKey: "liveVocabularyJSON")
        }
    }
    @Published var automaticGain = false
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
    @Published private(set) var liveSummary = ""
    @Published private(set) var summaryError: String?
    @Published private(set) var isSummarizing = false
    @Published private(set) var summarySegmentCount = 0

    private let credentialStore: FileCredentialStore
    private let client = ZoomLiveScribeClient()
    private let translator = ZoomAIClient()
    private var capture: LiveAudioCapture?
    private var sessionTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var summaryRequestID: UUID?
    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private var clipHoldUntil = Date.distantPast

    init(credentialStore: FileCredentialStore) {
        self.credentialStore = credentialStore
        if translationLanguage == language ||
            !LanguageCatalog.all.contains(where: { $0.locale == translationLanguage }) {
            translationLanguage = ""
        }
    }

    var isSessionActive: Bool { isConnecting || isStreaming || isStopping }
    var canStart: Bool { !isSessionActive && vocabularyError == nil }
    var canStop: Bool { (isConnecting || isStreaming) && !isStopping }
    var transcriptText: String {
        segments.flatMap { segment in
            [segment.text, segment.translation].compactMap { value in
                guard let value,
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return value
            }
        }.joined(separator: "\n")
    }
    var summaryTranscriptText: String {
        segments.map(\.text).joined(separator: "\n")
    }
    var summaryCoverageLabel: String {
        let suffix = summarySegmentCount == 1 ? "" : "s"
        if summarySegmentCount == segments.count {
            return "\(summarySegmentCount) captured segment\(suffix)"
        }
        return "\(summarySegmentCount) of \(segments.count) captured segments"
    }
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
    var floatingCaptionText: String {
        interimTranscript.isEmpty
            ? segments.last?.text ?? ""
            : interimCaptionText
    }
    var floatingTranslationText: String {
        interimTranscript.isEmpty
            ? segments.last?.translation ?? ""
            : ""
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
        source = newSource
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
        summaryTask?.cancel()
        capture = nil
        sessionTask = nil
        summaryTask = nil
        summaryRequestID = nil
        isConnecting = false
        isStreaming = false
        isStopping = false
        isSpeechActive = false
        isSummarizing = false
        resetMeter()
    }

    func clearTranscript() {
        summaryTask?.cancel()
        summaryTask = nil
        summaryRequestID = nil
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll()
        segments.removeAll()
        interimTranscript = ""
        liveSummary = ""
        summaryError = nil
        summarySegmentCount = 0
        isSummarizing = false
    }

    func copyTranscript() {
        guard !transcriptText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText, forType: .string)
        status = "Transcript copied"
    }

    func summarizeTranscript() {
        guard !isSummarizing else { return }
        let transcript = summaryTranscriptText
        guard !transcript.isEmpty else { return }
        let segmentCount = segments.count
        let summaryLanguage = language
        let requestID = UUID()

        liveSummary = ""
        summaryError = nil
        summarySegmentCount = segmentCount
        isSummarizing = true
        summaryRequestID = requestID
        summaryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if summaryRequestID == requestID {
                    isSummarizing = false
                    summaryTask = nil
                    summaryRequestID = nil
                }
            }
            do {
                guard let credentials = try credentialStore.load(), credentials.isComplete else {
                    throw liveError("Save Zoom Build credentials in Settings first.")
                }
                let result = try await translator.summarize(
                    transcript,
                    language: summaryLanguage,
                    credentials: credentials
                )
                try Task.checkCancellation()
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw liveError("Zoom Summarizer returned an empty summary.")
                }
                guard summaryRequestID == requestID else { return }
                liveSummary = text
            } catch is CancellationError {
            } catch {
                guard summaryRequestID == requestID else { return }
                summaryError = error.localizedDescription
            }
        }
    }

    func copySummary() {
        guard !liveSummary.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(liveSummary, forType: .string)
    }

    private func runSession() async {
        do {
            guard let credentials = try credentialStore.load(), credentials.isComplete else {
                throw liveError("Save Zoom Build credentials in Settings first.")
            }
            let options = LiveScribeOptions(
                language: language,
                vocabularyJSON: vocabularyJSON
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
                Task { @MainActor in self?.handle(event, credentials: credentials) }
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

    private func handle(_ event: LiveScribeEvent, credentials: APICredentials) {
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
                let segment = LiveTranscriptSegment(
                    number: segments.count + 1,
                    text: text,
                    isTranslating: !translationLanguage.isEmpty
                )
                segments.append(segment)
                if !translationLanguage.isEmpty {
                    translate(
                        segment,
                        source: language,
                        target: translationLanguage,
                        credentials: credentials
                    )
                }
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

    private func translate(
        _ segment: LiveTranscriptSegment,
        source: String,
        target: String,
        credentials: APICredentials
    ) {
        let id = segment.id
        let task = Task { [weak self] in
            guard let self else { return }
            defer { translationTasks[id] = nil }
            do {
                let translation = try await translator.translate(
                    segment.text,
                    source: source,
                    target: target,
                    credentials: credentials
                )
                guard !Task.isCancelled,
                      let index = segments.firstIndex(where: { $0.id == id })
                else { return }
                segments[index].translation = translation
                segments[index].translationError = nil
                segments[index].isTranslating = false
            } catch is CancellationError {
            } catch {
                guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
                segments[index].translationError = error.localizedDescription
                segments[index].isTranslating = false
            }
        }
        translationTasks[id] = task
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
