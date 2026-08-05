import SwiftUI
import ZScribeCore

struct LiveView: View {
    @ObservedObject var model: LiveModeModel

    var body: some View {
        HSplitView {
            configuration
                .frame(minWidth: 310, idealWidth: 350, maxWidth: 400)
            transcript
                .frame(minWidth: 480, maxWidth: .infinity)
        }
        .navigationTitle("Live Transcription")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.copyTranscript()
                } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
                .disabled(model.segments.isEmpty)
                .help("Copy completed transcript")

                Button {
                    model.clearTranscript()
                } label: {
                    Label("Clear Transcript", systemImage: "trash")
                }
                .disabled(model.segments.isEmpty && model.interimTranscript.isEmpty)
                .help("Clear transcript")
            }
        }
    }

    private var configuration: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                status

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Audio Input")
                    Picker("Audio source", selection: Binding(
                        get: { model.source },
                        set: { model.setSource($0) }
                    )) {
                        ForEach(LiveAudioSource.allCases) { source in
                            Label(source.rawValue, systemImage: source.symbol).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.isSessionActive)
                    Label(model.sourceDetail, systemImage: model.source.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Language")
                    Picker("Transcription language", selection: binding(\.language)) {
                        ForEach(LanguageCatalog.all) { language in
                            Text(language.name).tag(language.locale)
                        }
                    }
                    .labelsHidden()
                    .disabled(model.isSessionActive)
                }

                vocabularyEditor

                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("Signal")
                    Toggle("Auto gain", isOn: binding(\.automaticGain))
                    Toggle("Force output cadence", isOn: binding(\.forceCaptionCadence))
                    if model.forceCaptionCadence {
                        Picker("Cadence", selection: binding(\.cadence)) {
                            ForEach(CaptionCadence.all) { cadence in
                                Text(cadence.label).tag(cadence)
                            }
                        }
                    }
                }
                .disabled(model.isSessionActive)

                Divider()

                Button {
                    model.canStop ? model.stop() : model.start()
                } label: {
                    Label(
                        model.canStop ? "Stop Live" : "Start Live",
                        systemImage: model.canStop ? "stop.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(model.canStop ? .red : .accentColor)
                .disabled(model.isStopping || (!model.canStop && !model.canStart))
            }
            .padding(20)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(model.status)
                    .fontWeight(.medium)
                    .lineLimit(2)
                Spacer()
            }
            HStack(spacing: 10) {
                ProgressView(value: model.inputLevel)
                    .progressViewStyle(.linear)
                    .tint(meterColor)
                Text(model.inputLevelLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.inputLevelState == .clipping ? .red : .secondary)
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("Detected Words", systemImage: "text.bubble")
                        .font(.headline)
                    Spacer()
                    Text("Not yet final")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(model.interimCaptionText.isEmpty
                         ? "Waiting for speech"
                         : model.interimCaptionText)
                        .foregroundStyle(model.interimCaptionText.isEmpty ? .tertiary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 72)
            }
            .padding(18)
            .background(.background.secondary)

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Text("Completed Segments")
                        .font(.headline)
                    Spacer()
                    Text(model.segmentCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

                if model.segments.isEmpty {
                    ContentUnavailableView(
                        "No Completed Segments",
                        systemImage: "waveform",
                        description: Text("Final speech turns appear here.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.segments) { segment in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(segment.number)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(segment.text)
                                    .textSelection(.enabled)
                                Text(segment.at, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<LiveModeModel, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { model[keyPath: keyPath] = $0 }
        )
    }

    private var vocabularyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Scribe Vocabulary JSON")
            ZStack(alignment: .topLeading) {
                if model.vocabularyJSON.isEmpty {
                    Text("{\n  \"phrases\": [\"AIAGW\"],\n  \"pronunciations\": [],\n  \"aliases\": []\n}")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: binding(\.vocabularyJSON))
                    .font(.system(.caption, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
            }
            .frame(height: 170)
            .background(.background)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        model.vocabularyError == nil
                            ? Color.secondary.opacity(0.35)
                            : Color.red,
                        lineWidth: 1
                    )
            }
            .disabled(model.isSessionActive)

            HStack {
                Image(systemName: model.vocabularyError == nil
                      ? (model.hasVocabulary ? "checkmark.circle" : "info.circle")
                      : "exclamationmark.triangle")
                Text(model.vocabularyError
                     ?? (model.hasVocabulary ? "Valid vocabulary JSON" : "Optional"))
                    .lineLimit(2)
            }
            .font(.caption)
            .foregroundStyle(model.vocabularyError == nil ? Color.secondary : Color.red)
        }
    }

    private var statusColor: Color {
        if model.isSpeechActive { return .orange }
        if model.isStreaming { return .green }
        if model.isConnecting || model.isStopping { return .yellow }
        return .secondary
    }

    private var meterColor: Color {
        switch model.inputLevelState {
        case .normal: .green
        case .warning: .orange
        case .clipping: .red
        }
    }
}
