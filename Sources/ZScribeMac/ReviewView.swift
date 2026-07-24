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
    private var observer: Any?
    private var loadedJobID: UUID?

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
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }

    func load(_ job: QueueJob?) {
        guard let job, job.id != loadedJobID else { return }
        loadedJobID = job.id
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: job.sourcePath)))
        let captionPath = job.translatedVttPath ?? job.originalVttPath
        if let captionPath, let text = try? String(contentsOfFile: captionPath, encoding: .utf8) {
            cues = WebVTT.parse(text)
        } else {
            cues = []
        }
        summary = job.summaryPath.flatMap {
            try? String(contentsOfFile: $0, encoding: .utf8)
        } ?? "No summary was generated for this job."
        position = 0
        duration = max(0, job.durationSeconds ?? 0)
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.playImmediately(atRate: rate)
        }
        objectWillChange.send()
    }

    func seek(_ seconds: Double, play: Bool = false) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
        if play { player.playImmediately(atRate: rate) }
    }

    func changeRate(_ value: Float) {
        rate = value
        if player.timeControlStatus == .playing { player.rate = value }
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
            if let job = model.selectedJob, job.canReview {
                HSplitView {
                    playerPane(job)
                        .frame(minWidth: 480)
                    detailPane
                        .frame(minWidth: 300, idealWidth: 380, maxWidth: 520)
                }
                .onAppear { playback.load(job) }
                .onChange(of: job.id) { _, _ in playback.load(job) }
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
                ForEach(model.jobs.filter(\.canReview)) {
                    Text($0.displayName).tag(Optional($0.id))
                }
            }
            .frame(width: 260)
        }
        .padding(16)
    }

    private func playerPane(_ job: QueueJob) -> some View {
        VStack(spacing: 0) {
            VideoPlayer(player: playback.player)
                .background(.black)
            if let active = playback.cues.first(where: { $0.id == playback.activeCueID }) {
                Text(active.text)
                    .font(.body.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(.black.opacity(0.88))
                    .foregroundStyle(.white)
            }
            controls
        }
        .background(.black)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.player.timeControlStatus == .playing
                      ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Play or pause")

            Text(clock(playback.position))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { playback.position },
                set: { playback.seek($0) }
            ), in: 0...max(1, playback.duration))
            Text(clock(playback.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Picker("Speed", selection: Binding(
                get: { playback.rate },
                set: { playback.changeRate($0) }
            )) {
                Text("1x").tag(Float(1))
                Text("1.5x").tag(Float(1.5))
                Text("2x").tag(Float(2))
                Text("4x").tag(Float(4))
            }
            .labelsHidden()
            .frame(width: 68)
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
                    Text(markdown(playback.summary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
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
