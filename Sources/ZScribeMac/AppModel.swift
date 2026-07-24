import AppKit
import Foundation
import ZScribeCore

@MainActor
final class AppModel: ObservableObject {
    enum QueueMediaFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case unknownDuration = "Unknown"
        case withoutAudio = "Without Audio"
        var id: Self { self }
    }

    enum Section: String, CaseIterable, Identifiable {
        case queue = "Queue"
        case review = "Review"
        case settings = "Settings"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .queue: "list.bullet.rectangle"
            case .review: "play.rectangle"
            case .settings: "gearshape"
            }
        }
    }

    @Published var jobs: [QueueJob] = []
    @Published var settings = UserSettings()
    @Published var selectedSection: Section? = .queue
    @Published var selectedJobID: UUID?
    @Published var notice = "Ready"
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var apiKey = ""
    @Published var hasSavedSecret = false
    @Published var presentedError: String?
    @Published var queueSearchText = "" {
        didSet {
            if oldValue != queueSearchText { beginQueueSearch() }
        }
    }
    @Published var queueMediaFilter: QueueMediaFilter = .all
    @Published private(set) var isQueueSearchRunning = false
    @Published private(set) var queueSearchMatches: Set<UUID>?

    let paths: AppPaths
    private let store: JSONStore
    private let vault = KeychainCredentialStore()
    private let zoom = ZoomAIClient()
    private let pipeline: MediaPipeline
    private let queueSearchIndex = QueueSearchIndex()
    private var runTask: Task<Void, Never>?
    private var queueSearchTask: Task<Void, Never>?

    init() {
        do {
            paths = try AppPaths()
        } catch {
            fatalError("Could not create Application Support directory: \(error)")
        }
        store = JSONStore(paths: paths)
        pipeline = MediaPipeline(paths: paths)
    }

    var selectedJob: QueueJob? {
        guard let selectedJobID else { return jobs.first(where: \.canReview) }
        return jobs.first { $0.id == selectedJobID }
    }

    var queueEstimate: CostBreakdown {
        jobs.map { CostEstimator.estimate($0, settings: settings) }
            .reduce(CostBreakdown(scribe: 0, translate: 0, summarize: 0)) {
                CostBreakdown(scribe: $0.scribe + $1.scribe,
                              translate: $0.translate + $1.translate,
                              summarize: $0.summarize + $1.summarize)
            }
    }

    var readyCount: Int { jobs.filter { $0.state == .ready }.count }
    var failedCount: Int { jobs.filter { $0.state == .failed }.count }
    var unknownDurationCount: Int { jobs.filter { $0.durationSeconds == nil }.count }
    var withoutAudioCount: Int { jobs.filter { $0.hasAudio == false }.count }
    var hasQueueSearch: Bool {
        !queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var filteredJobs: [QueueJob] {
        jobs.filter { job in
            let matchesMedia = switch queueMediaFilter {
            case .all: true
            case .unknownDuration: job.durationSeconds == nil
            case .withoutAudio: job.hasAudio == false
            }
            return matchesMedia &&
                (queueSearchMatches == nil || queueSearchMatches?.contains(job.id) == true)
        }
    }
    var queueCountLabel: String {
        queueMediaFilter == .all && !hasQueueSearch
            ? "\(jobs.count) job\(jobs.count == 1 ? "" : "s") in queue"
            : "Showing \(filteredJobs.count) of \(jobs.count) jobs"
    }

    func initialize() async {
        do {
            settings = try store.loadSettings()
            jobs = try store.loadQueue().map(MediaPipeline.applyExistingOutputs)
            if let credentials = try vault.load() {
                apiKey = credentials.apiKey
                hasSavedSecret = !credentials.apiSecret.isEmpty
            }
            for job in jobs where job.durationSeconds == nil &&
                FileManager.default.fileExists(atPath: job.sourcePath) {
                replace(await pipeline.probe(job, settings: settings))
            }
            try persist()
            notice = jobs.isEmpty ? "Add media to begin" : "\(jobs.count) job\(jobs.count == 1 ? "" : "s") loaded"
        } catch {
            show(error)
        }
    }

    func add(_ urls: [URL]) {
        let existing = Set(jobs.map(\.sourcePath))
        let additions = urls
            .filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
            .filter { !existing.contains($0.standardizedFileURL.path) }
            .map {
                MediaPipeline.applyExistingOutputs(to: QueueJob(
                    sourcePath: $0.standardizedFileURL.path
                ))
            }
        guard !additions.isEmpty else { return }
        jobs.append(contentsOf: additions)
        refreshQueueSearchIfNeeded()
        selectedJobID = additions.first?.id
        notice = "Added \(additions.count) media file\(additions.count == 1 ? "" : "s")"
        tryPersist()
        Task {
            for job in additions {
                replace(await pipeline.probe(job, settings: settings))
            }
            tryPersist()
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav]
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func startQueue() {
        guard !isRunning else {
            isPaused.toggle()
            notice = isPaused ? "Queue paused after the current stage" : "Queue resumed"
            return
        }
        runTask = Task { [weak self] in
            await self?.run()
        }
    }

    func cancelCurrent() {
        runTask?.cancel()
        notice = "Canceling the current job"
    }

    func retry(_ id: UUID) {
        update(id) { job in
            job.error = nil
            job.completedAt = nil
            job.report(.queued, progress: 0, "Waiting to retry")
        }
        tryPersist()
    }

    func retryAllFailed() {
        for id in jobs.filter({ $0.state == .failed }).map(\.id) { retry(id) }
        notice = "Failed jobs returned to the queue"
    }

    func remove(_ id: UUID) {
        guard jobs.first(where: { $0.id == id })?.state.isProcessing != true else { return }
        jobs.removeAll { $0.id == id }
        refreshQueueSearchIfNeeded()
        if selectedJobID == id { selectedJobID = nil }
        tryPersist()
    }

    func setSourceLanguage(_ locale: String, for id: UUID) {
        update(id) { job in
            guard !job.state.isProcessing else { return }
            job.sourceLanguage = locale
            if job.translationLanguage == locale { job.translationLanguage = "" }
        }
        tryPersist()
    }

    func setTranslationLanguage(_ locale: String, for id: UUID) {
        update(id) { job in
            guard !job.state.isProcessing else { return }
            job.translationLanguage = locale == job.sourceLanguage ? "" : locale
            job.translatedVttPath = nil
            job.summaryPath = nil
            if job.state == .ready && !job.translationLanguage.isEmpty {
                job.report(.queued, progress: 0, "Translation queued")
            }
        }
        tryPersist()
    }

    func setSummarize(_ enabled: Bool, for id: UUID) {
        update(id) { job in
            guard !job.state.isProcessing else { return }
            job.summarize = enabled
            if enabled && job.state == .ready && job.summaryPath == nil {
                job.report(.queued, progress: 0, "Summary queued")
            }
        }
        tryPersist()
    }

    func setQueueMediaFilter(_ filter: QueueMediaFilter) {
        queueMediaFilter = filter
    }

    func clearQueueSearch() {
        queueSearchText = ""
    }

    func review(_ id: UUID) {
        selectedJobID = id
        selectedSection = .review
    }

    func reveal(_ id: UUID) {
        guard let path = jobs.first(where: { $0.id == id })?.sourcePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func saveSettings(secret: String) {
        do {
            settings.clamp()
            try store.saveSettings(settings)
            let existingSecret = try vault.load()?.apiSecret ?? ""
            let credentials = APICredentials(
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                apiSecret: secret.isEmpty ? existingSecret : secret
            )
            if !credentials.apiKey.isEmpty || !credentials.apiSecret.isEmpty {
                try zoom.validateLocally(credentials)
                try vault.save(credentials)
                hasSavedSecret = true
            }
            notice = "Settings and Keychain credentials saved"
        } catch {
            show(error)
        }
    }

    func clearCredentials() {
        do {
            try vault.clear()
            apiKey = ""
            hasSavedSecret = false
            notice = "Zoom credentials removed from Keychain"
        } catch {
            show(error)
        }
    }

    private func run() async {
        do {
            guard let credentials = try vault.load(), credentials.isComplete else {
                selectedSection = .settings
                throw NSError(domain: "ZScribe", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Save your Zoom Build API key and secret in Settings first."])
            }
            isRunning = true
            isPaused = false
            defer {
                isRunning = false
                isPaused = false
                runTask = nil
            }
            for id in jobs.filter({ [.queued, .canceled].contains($0.state) }).map(\.id) {
                while isPaused {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(200))
                }
                try Task.checkCancellation()
                guard let job = jobs.first(where: { $0.id == id }) else { continue }
                notice = "Processing \(job.displayName)"
                do {
                    let completed = try await pipeline.process(
                        job, settings: settings, credentials: credentials
                    ) { [weak self] updated in
                        await MainActor.run {
                            self?.replace(updated)
                            self?.tryPersist()
                        }
                    }
                    replace(completed)
                } catch is CancellationError {
                    update(id) { $0.report(.canceled, progress: 0, "Canceled") }
                    tryPersist()
                    throw CancellationError()
                } catch {
                    update(id) {
                        $0.error = error.localizedDescription
                        $0.completedAt = .now
                        $0.report(.failed, progress: 0, "Processing failed")
                    }
                    tryPersist()
                }
            }
            notice = "Queue finished"
        } catch is CancellationError {
            notice = "Queue stopped"
        } catch {
            show(error)
        }
    }

    private func update(_ id: UUID, _ body: (inout QueueJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    private func replace(_ job: QueueJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
        refreshQueueSearchIfNeeded()
    }

    private func persist() throws { try store.saveQueue(jobs) }
    private func tryPersist() {
        do { try persist() } catch { show(error) }
    }
    private func show(_ error: Error) {
        presentedError = error.localizedDescription
        notice = error.localizedDescription
    }

    private func refreshQueueSearchIfNeeded() {
        if hasQueueSearch { beginQueueSearch() }
    }

    private func beginQueueSearch() {
        queueSearchTask?.cancel()
        let query = queueSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            queueSearchMatches = nil
            isQueueSearchRunning = false
            return
        }

        let snapshot = jobs
        queueSearchMatches = Set(snapshot.filter {
            $0.displayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.map(\.id))
        isQueueSearchRunning = true
        queueSearchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                let matches = await self.queueSearchIndex.findMatches(in: snapshot, query: query)
                try Task.checkCancellation()
                self.queueSearchMatches = matches
                self.isQueueSearchRunning = false
            } catch is CancellationError {
            } catch {
                self?.isQueueSearchRunning = false
                self?.notice = "Search could not read all sidecar files: \(error.localizedDescription)"
            }
        }
    }
}
