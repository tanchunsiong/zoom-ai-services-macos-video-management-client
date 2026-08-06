import AVKit
import SwiftUI
import ZScribeCore

@MainActor
final class ReviewPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var cues: [TranscriptCue] = []
    @Published var summary = ""
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var activeCueID: Int?
    @Published var rate: Float = 1
    @Published private(set) var isPlaying = false
    @Published var isPreparingPlayback = false
    @Published var playbackError: String?
    private var observer: Any?
    private var playbackStatusObserver: NSKeyValueObservation?
    private var loadedJobID: UUID?
    private var loadTask: Task<Void, Never>?

    init() {
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.position = max(0, time.seconds.isFinite ? time.seconds : 0)
                self.activeCueID = self.cues.first {
                    $0.start <= self.position && self.position < $0.end
                }?.id
                let itemDuration = self.player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite { self.duration = max(0, itemDuration) }
            }
        }
        playbackStatusObserver = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    deinit {
        loadTask?.cancel()
        playbackStatusObserver?.invalidate()
        if let observer { player.removeTimeObserver(observer) }
    }

    func load(_ job: QueueJob?, settings: UserSettings, paths: AppPaths) {
        guard let job, job.id != loadedJobID else { return }
        loadedJobID = job.id
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        isPreparingPlayback = true
        playbackError = nil
        let captionPath = job.translatedVttPath ?? job.originalVttPath
        if let captionPath, let text = try? String(contentsOfFile: captionPath, encoding: .utf8) {
            cues = WebVTT.parse(text)
        } else {
            cues = []
        }
        summary = job.summaryPath.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }.map(ZoomAIClient.normalizeSummaryText)
            ?? "No summary was generated for this job."
        position = 0
        duration = max(0, job.durationSeconds ?? 0)
        loadTask = Task { [weak self] in
            do {
                let url = try await PlaybackResolver(paths: paths).resolve(
                    URL(fileURLWithPath: job.sourcePath),
                    settings: settings
                )
                try Task.checkCancellation()
                guard let self, self.loadedJobID == job.id else { return }
                self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
                self.isPreparingPlayback = false
            } catch is CancellationError {
            } catch {
                self?.playbackError = error.localizedDescription
                self?.isPreparingPlayback = false
            }
        }
    }

    func togglePlayback() {
        guard player.currentItem != nil, !isPreparingPlayback, playbackError == nil else { return }
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, position >= duration - 0.1 {
                seek(0)
            }
            player.playImmediately(atRate: rate)
        }
    }

    func seek(_ seconds: Double, play: Bool = false) {
        let upperBound = duration > 0 ? duration : max(0, seconds)
        let target = min(max(0, seconds), upperBound)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
        if play { player.playImmediately(atRate: rate) }
    }

    func changeRate(_ value: Float) {
        guard Self.playbackRates.contains(value) else { return }
        rate = value
        if isPlaying { player.rate = value }
    }

    static let playbackRates: [Float] = [1, 1.5, 2]
    var canControlPlayback: Bool {
        player.currentItem != nil && !isPreparingPlayback && playbackError == nil
    }
}

private final class PlayerSurfaceView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerSurfaceView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleNSView(_ view: PlayerSurfaceView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

struct ReviewView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var playback = ReviewPlayer()
    @State private var detailTab = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let job = model.selectedJob,
               FileManager.default.fileExists(atPath: job.sourcePath) {
                HSplitView {
                    playerPane(job)
                        .frame(minWidth: 480)
                    detailPane
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
                }
                .onAppear {
                    playback.load(job, settings: model.settings, paths: model.paths)
                }
                .onChange(of: job.id) { _, _ in
                    playback.load(job, settings: model.settings, paths: model.paths)
                }
            } else {
                ContentUnavailableView(
                    "Nothing to Review",
                    systemImage: "captions.bubble",
                    description: Text("Select a completed queue item.")
                )
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review").font(.title2.weight(.semibold))
                Text(model.selectedJob?.displayName ?? "No completed job selected")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Job", selection: Binding(
                get: { model.selectedJobID },
                set: { model.selectedJobID = $0 }
            )) {
                Text("Select a job").tag(UUID?.none)
                ForEach(model.jobs) {
                    Text($0.displayName).tag(Optional($0.id))
                }
            }
            .frame(width: 260)
        }
        .padding(16)
    }

    private func playerPane(_ job: QueueJob) -> some View {
        let active = playback.cues.first(where: { $0.id == playback.activeCueID })
        return GeometryReader { geometry in
            let captionHeight = active == nil ? 0.0 : 58.0
            VStack(spacing: 0) {
                NativeVideoPlayer(player: playback.player)
                    .frame(
                        width: geometry.size.width,
                        height: max(0, geometry.size.height - 48 - captionHeight)
                    )
                    .background(.black)
                    .overlay {
                        if playback.isPreparingPlayback {
                            ProgressView("Preparing playback...")
                                .padding(12)
                                .background(.black.opacity(0.75))
                                .foregroundStyle(.white)
                        } else if let error = playback.playbackError {
                            ContentUnavailableView(
                                "Playback Failed",
                                systemImage: "exclamationmark.triangle",
                                description: Text(error)
                            )
                            .foregroundStyle(.white)
                        }
                    }
                if let active {
                    Text(active.text)
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
                        .background(.black.opacity(0.88))
                        .foregroundStyle(.white)
                }
                controls
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.black)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying
                      ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!playback.canControlPlayback)
            .help("Play or pause")

            Text(clock(playback.position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { playback.position },
                set: { playback.seek($0) }
            ), in: 0...max(1, playback.duration))
            .disabled(!playback.canControlPlayback || playback.duration <= 0)
            .help("Playback timeline")
            Text(clock(playback.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Picker("Speed", selection: Binding(
                get: { playback.rate },
                set: { playback.changeRate($0) }
            )) {
                ForEach(ReviewPlayer.playbackRates, id: \.self) { rate in
                    Text(rate == 1 ? "1x" : String(format: "%gx", rate)).tag(rate)
                }
            }
            .labelsHidden()
            .frame(width: 68)
            .disabled(!playback.canControlPlayback)
            .help("Playback speed")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(.bar)
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $detailTab) {
                Text("Captions").tag(0)
                Text("Summary").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(12)
            Divider()
            if detailTab == 0 {
                ScrollViewReader { proxy in
                    List(playback.cues) { cue in
                        Button {
                            playback.seek(cue.start, play: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(clock(cue.start))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tint)
                                Text(cue.text)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .id(cue.id)
                        .listRowBackground(
                            cue.id == playback.activeCueID
                                ? Color.accentColor.opacity(0.12) : Color.clear
                        )
                    }
                    .listStyle(.plain)
                    .onChange(of: playback.activeCueID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            } else {
                ScrollView {
                    SummaryDocumentView(text: playback.summary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                }
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value >= 3600
            ? String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
}

private struct SummaryDocumentView: View {
    private enum BlockKind {
        case heading(Int)
        case paragraph
        case listItem(marker: String)
    }

    private struct Block: Identifiable {
        let id: Int
        let kind: BlockKind
        let text: String
    }

    let text: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level):
                    Text(inlineMarkdown(block.text))
                        .font(headingFont(level))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, level == 1 ? 2 : 6)
                case .paragraph:
                    Text(inlineMarkdown(block.text))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .listItem(let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(marker)
                            .frame(width: 18, alignment: .trailing)
                        Text(inlineMarkdown(block.text))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var blocks: [Block] {
        var result: [(BlockKind, String)] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            result.append((.paragraph, paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = parseHeading(line) {
                flushParagraph()
                result.append((.heading(heading.level), heading.text))
            } else if let item = parseListItem(line) {
                flushParagraph()
                result.append((.listItem(marker: item.marker), item.text))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return result.enumerated().map { Block(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    private func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private func parseListItem(_ line: String) -> (marker: String, text: String)? {
        for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
            return ("•", String(line.dropFirst(prefix.count)))
        }
        guard let separator = line.firstIndex(where: \Character.isWhitespace) else { return nil }
        let token = line[..<separator]
        guard let suffix = token.last,
              suffix == "." || suffix == ")",
              let number = Int(token.dropLast()) else { return nil }
        let text = line[separator...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return ("\(number).", text)
    }

    private func inlineMarkdown(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .headline.weight(.semibold)
        default: .subheadline.weight(.semibold)
        }
    }
}
