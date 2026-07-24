import SwiftUI
import ZScribeCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiSecret = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Settings").font(.title2.weight(.semibold))
                    Text("Credentials are stored in your login Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()

            Form {
                Section("Zoom Build Credentials") {
                    TextField("API key", text: $model.apiKey)
                        .textContentType(.username)
                    SecureField(
                        model.hasSavedSecret ? "API secret (saved)" : "API secret",
                        text: $apiSecret
                    )
                    HStack {
                        Label(model.hasSavedSecret ? "Credential saved" : "No credential saved",
                              systemImage: model.hasSavedSecret ? "key.fill" : "key")
                            .foregroundStyle(model.hasSavedSecret ? .green : .secondary)
                        Spacer()
                        if model.hasSavedSecret {
                            Button("Remove", role: .destructive) { model.clearCredentials() }
                        }
                    }
                }

                Section("Media Tools") {
                    TextField("FFmpeg executable", text: $model.settings.ffmpegPath)
                    TextField("FFprobe executable", text: $model.settings.ffprobePath)
                    Stepper(
                        "Parallel Scribe requests: \(model.settings.scribeConcurrency)",
                        value: $model.settings.scribeConcurrency, in: 1...4
                    )
                    Stepper(
                        "Segment length: \(model.settings.segmentMinutes) minutes",
                        value: $model.settings.segmentMinutes, in: 1...30
                    )
                }

                Section("Cost Rates (USD)") {
                    LabeledContent("Scribe Fast per audio minute") {
                        TextField("", value: $model.settings.scribeUSDPerMinute,
                                  format: .number.precision(.fractionLength(4)))
                            .frame(width: 110)
                    }
                    LabeledContent("Translator per million characters") {
                        TextField("", value: $model.settings.translatorUSDPerMillionCharacters,
                                  format: .number.precision(.fractionLength(2)))
                            .frame(width: 110)
                    }
                    LabeledContent("Summarizer per million characters") {
                        TextField("", value: $model.settings.summarizerUSDPerMillionCharacters,
                                  format: .number.precision(.fractionLength(2)))
                            .frame(width: 110)
                    }
                    LabeledContent("Characters per minute override") {
                        TextField("", value: $model.settings.estimatedCharactersPerMinute,
                                  format: .number)
                            .frame(width: 110)
                    }
                }

                Section {
                    Button("Save Settings", systemImage: "square.and.arrow.down") {
                        model.saveSettings(secret: apiSecret)
                        apiSecret = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}
