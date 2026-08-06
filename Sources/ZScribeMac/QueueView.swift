import SwiftUI
import UniformTypeIdentifiers
import ZScribeCore

private enum QueueColumns {
    static let spacing: CGFloat = 12
    static let spoken: CGFloat = 112
    static let translation: CGFloat = 112
    static let summary: CGFloat = 76
    static let price: CGFloat = 72
    static let time: CGFloat = 72
    static let status: CGFloat = 138
    static let actions: CGFloat = 58
    static let minimumTableWidth: CGFloat = 1_040
}

struct QueueView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchAndFilters
            Divider()
            if model.jobs.isEmpty {
                emptyState
            } else if model.filteredJobs.isEmpty {
                noMatchesState
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            columnHeaders
                            Divider()
                            ScrollViewReader { proxy in
                                ScrollView(.vertical) {
                                    LazyVStack(spacing: 0) {
                                        ForEach(model.filteredJobs) { job in
                                            QueueRow(job: job)
                                                .id(job.id)
                                            Divider().padding(.leading, 42)
                                        }
                                    }
                                }
                                .onChange(of: model.activeJobID) { _, id in
                                    if let id {
                                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                                    }
                                }
                            }
                        }
                        .frame(
                            width: max(geometry.size.width, QueueColumns.minimumTableWidth),
                            height: geometry.size.height,
                            alignment: .topLeading
                        )
                    }
                }
            }
        }
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Media Queue").font(.title2.weight(.semibold))
                Text(model.queueCountLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.failedCount > 0 {
                Button("Retry Failed", systemImage: "arrow.clockwise") {
                    model.retryAllFailed()
                }
            }
            Menu {
                Button("Add Files", systemImage: "doc.badge.plus") { model.chooseFiles() }
                Button("Add Folder", systemImage: "folder.badge.plus") { model.chooseFolder() }
            } label: {
                Label("Add Media", systemImage: "plus")
            }
            if model.isRunning {
                Button(model.isPaused ? "Resume" : "Pause",
                       systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                    model.startQueue()
                }
                Button("Cancel", systemImage: "stop.fill", role: .destructive) {
                    model.cancelCurrent()
                }
            } else {
                Button("Start Queue", systemImage: "play.fill") { model.startQueue() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.jobs.contains { [.queued, .canceled].contains($0.state) })
            }
        }
        .padding(16)
    }

    private var searchAndFilters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    "Search filename, transcript, or summary",
                    text: $model.queueSearchText
                )
                .textFieldStyle(.plain)
                .onExitCommand { model.clearQueueSearch() }
                if model.isQueueSearchRunning {
                    ProgressView().controlSize(.small)
                        .help("Searching sidecar text")
                } else if model.hasQueueSearch {
                    Button {
                        model.clearQueueSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 330, height: 30)
            .background(.background)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.35))
            }

            Picker("Queue filter", selection: Binding(
                get: { model.queueMediaFilter },
                set: { model.setQueueMediaFilter($0) }
            )) {
                Text("All \(model.jobs.count)").tag(AppModel.QueueMediaFilter.all)
                Text("Unknown \(model.unknownDurationCount)")
                    .tag(AppModel.QueueMediaFilter.unknownDuration)
                Text("Without Audio \(model.withoutAudioCount)")
                    .tag(AppModel.QueueMediaFilter.withoutAudio)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 430)

            Spacer()
            if model.hasQueueSearch || model.queueMediaFilter != .all {
                Text(model.queueCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
    }

    private var columnHeaders: some View {
        HStack(alignment: .top, spacing: QueueColumns.spacing) {
            Text("MEDIA").frame(maxWidth: .infinity, alignment: .leading)
            Text("SPOKEN").frame(width: QueueColumns.spoken, alignment: .leading)
            Text("TRANSLATE").frame(width: QueueColumns.translation, alignment: .leading)
            Text("SUMMARY").frame(width: QueueColumns.summary, alignment: .leading)
            Text("PRICE").frame(width: QueueColumns.price, alignment: .leading)
            Text("TIME").frame(width: QueueColumns.time, alignment: .leading)
            Text("STATUS").frame(width: QueueColumns.status, alignment: .leading)
            Text("").frame(width: QueueColumns.actions, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No Media", systemImage: "film.stack")
                .font(.title3.weight(.semibold))
            Text("Drop video or audio files here.")
                .foregroundStyle(.secondary)
            Button("Choose Media", systemImage: "plus") { model.chooseFiles() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var noMatchesState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.hasQueueSearch ? "No Search Results" : "No Matching Media",
                systemImage: model.hasQueueSearch
                    ? "magnifyingglass" : "line.3.horizontal.decrease.circle"
            )
            .font(.title3.weight(.semibold))
            Text(model.hasQueueSearch
                 ? "No queue items match \"\(model.queueSearchText)\"."
                 : "No queue items match this media filter.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var model: AppModel
    let job: QueueJob

    var body: some View {
        HStack(alignment: .top, spacing: QueueColumns.spacing) {
            media
                .frame(maxWidth: .infinity, alignment: .topLeading)
            languagePicker
            translationPicker
            Toggle("", isOn: Binding(
                get: { job.summarize },
                set: { model.setSummarize($0, for: job.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: QueueColumns.summary, alignment: .leading)
            .help(job.summarize ? "Summary enabled" : "Summary disabled")
            Text(model.estimatedCostLabel(for: job))
                .frame(width: QueueColumns.price, alignment: .leading)
            Text(model.estimatedTimeLabel(for: job))
                .frame(width: QueueColumns.time, alignment: .leading)
            status
            actions.frame(width: QueueColumns.actions, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(model.selectedJobID == job.id ? Color.accentColor.opacity(0.1) : .clear)
        .onTapGesture { model.selectedJobID = job.id }
        .contextMenu {
            Button("Preview Media", systemImage: "play.rectangle") {
                model.preview(job.id)
            }
            if job.canReview {
                Button("Review", systemImage: "play.rectangle") { model.review(job.id) }
            }
            Button("Show in Finder", systemImage: "folder") { model.reveal(job.id) }
            if job.state == .failed {
                Button("Retry", systemImage: "arrow.clockwise") {
                    model.retryAndStart(job.id)
                }
            }
            if job.canReview && job.summarize {
                Button("Rerun Summary", systemImage: "text.badge.star") {
                    model.rerunSummary(job.id)
                }
            }
            Divider()
            Button("Remove", systemImage: "trash", role: .destructive) { model.remove(job.id) }
                .disabled(job.state.isProcessing)
        }
    }

    private var media: some View {
        HStack(spacing: 10) {
            Image(systemName: mediaSymbol)
                .font(.title3)
                .foregroundStyle(job.hasAudio == false ? .red : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName).lineLimit(1).fontWeight(.medium)
                Text(job.durationLabel)
                    .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var languagePicker: some View {
        Picker("", selection: Binding(
            get: { job.sourceLanguage },
            set: { model.setSourceLanguage($0, for: job.id) }
        )) {
            ForEach(LanguageCatalog.all) { Text($0.name).tag($0.locale) }
        }
        .labelsHidden()
        .frame(width: QueueColumns.spoken, alignment: .leading)
        .disabled(job.state.isProcessing || [.ready].contains(job.state))
    }

    private var translationPicker: some View {
        Picker("", selection: Binding(
            get: { job.translationLanguage },
            set: { model.setTranslationLanguage($0, for: job.id) }
        )) {
            Text("None").tag("")
            ForEach(LanguageCatalog.all.filter { $0.locale != job.sourceLanguage }) {
                Text($0.name).tag($0.locale)
            }
        }
        .labelsHidden()
        .frame(width: QueueColumns.translation, alignment: .leading)
        .disabled(job.state.isProcessing)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(job.state.label, systemImage: job.state.symbol)
                .foregroundStyle(statusColor)
                .font(.caption.weight(.semibold))
            if job.state.isProcessing {
                ProgressView(value: job.progress).controlSize(.small)
            } else {
                Text(job.error ?? job.statusMessage)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(width: QueueColumns.status, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if job.canReview {
                Button { model.review(job.id) } label: { Image(systemName: "play.rectangle") }
                    .help("Review transcript")
                    .buttonStyle(.borderless)
            } else if job.state == .failed {
                Button { model.retryAndStart(job.id) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                    .help("Retry")
                    .buttonStyle(.borderless)
            } else if !job.state.isProcessing {
                Button { model.preview(job.id) } label: { Image(systemName: "play.rectangle") }
                    .help("Preview media")
                    .buttonStyle(.borderless)
            }
            Menu {
                Button("Show in Finder", systemImage: "folder") { model.reveal(job.id) }
                Button("Remove", systemImage: "trash", role: .destructive) { model.remove(job.id) }
                    .disabled(job.state.isProcessing)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 26)
        }
    }

    private var mediaSymbol: String {
        ["wav", "m4a", "mp3", "aac", "flac", "ogg", "opus", "aiff"]
            .contains(URL(fileURLWithPath: job.sourcePath).pathExtension.lowercased())
            ? "waveform" : "film"
    }
    private var statusColor: Color {
        switch job.state {
        case .ready: .green
        case .failed: .red
        case .canceled: .secondary
        default: .accentColor
        }
    }
}
