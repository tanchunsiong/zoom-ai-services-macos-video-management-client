import SwiftUI
import UniformTypeIdentifiers
import ZScribeCore

struct QueueView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.jobs.isEmpty {
                emptyState
            } else {
                columnHeaders
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            QueueRow(job: job)
                            Divider().padding(.leading, 42)
                        }
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
                Text("Files process in order; segment uploads run concurrently.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.failedCount > 0 {
                Button("Retry Failed", systemImage: "arrow.clockwise") {
                    model.retryAllFailed()
                }
            }
            Button("Add Media", systemImage: "plus") { model.chooseFiles() }
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

    private var columnHeaders: some View {
        Grid(horizontalSpacing: 12) {
            GridRow {
                Text("MEDIA").gridColumnAlignment(.leading)
                Text("SPOKEN").frame(width: 112, alignment: .leading)
                Text("TRANSLATE").frame(width: 112, alignment: .leading)
                Text("SUMMARY").frame(width: 70)
                Text("STATUS").frame(width: 150, alignment: .leading)
                Text("").frame(width: 90)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Media", systemImage: "film.stack")
        } description: {
            Text("Drop video or audio files here.")
        } actions: {
            Button("Choose Media", systemImage: "plus") { model.chooseFiles() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct QueueRow: View {
    @EnvironmentObject private var model: AppModel
    let job: QueueJob

    var body: some View {
        Grid(horizontalSpacing: 12) {
            GridRow {
                media
                languagePicker
                translationPicker
                Toggle("", isOn: Binding(
                    get: { job.summarize },
                    set: { model.setSummarize($0, for: job.id) }
                ))
                .labelsHidden()
                .frame(width: 70)
                status
                actions.frame(width: 90, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .background(model.selectedJobID == job.id ? Color.accentColor.opacity(0.1) : .clear)
        .onTapGesture { model.selectedJobID = job.id }
        .contextMenu {
            if job.canReview {
                Button("Review", systemImage: "play.rectangle") { model.review(job.id) }
            }
            Button("Show in Finder", systemImage: "folder") { model.reveal(job.id) }
            if job.state == .failed {
                Button("Retry", systemImage: "arrow.clockwise") { model.retry(job.id) }
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
                HStack(spacing: 8) {
                    Text(job.durationLabel)
                    Text(CostEstimator.format(CostEstimator.estimate(job, settings: model.settings).total))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .gridColumnAlignment(.leading)
    }

    private var languagePicker: some View {
        Picker("", selection: Binding(
            get: { job.sourceLanguage },
            set: { model.setSourceLanguage($0, for: job.id) }
        )) {
            ForEach(LanguageCatalog.all) { Text($0.name).tag($0.locale) }
        }
        .labelsHidden()
        .frame(width: 112)
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
        .frame(width: 112)
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
        .frame(width: 150, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if job.canReview {
                Button { model.review(job.id) } label: { Image(systemName: "play.rectangle") }
                    .help("Review transcript")
                    .buttonStyle(.borderless)
            } else if job.state == .failed {
                Button { model.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Retry")
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
