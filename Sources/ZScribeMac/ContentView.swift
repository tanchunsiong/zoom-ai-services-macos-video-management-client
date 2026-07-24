import SwiftUI
import ZScribeCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $model.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("Z Scribe")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 7) {
                    Label("\(model.jobs.count) queued", systemImage: "tray.full")
                    Label("\(model.readyCount) ready", systemImage: "checkmark.circle")
                    if model.failedCount > 0 {
                        Label("\(model.failedCount) failed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            Group {
                switch model.selectedSection ?? .queue {
                case .queue: QueueView()
                case .review: ReviewView()
                case .settings: SettingsView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                statusBar
            }
        }
        .alert("Z Scribe", isPresented: Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } }
        )) {
            Button("OK", role: .cancel) { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "")
        }
    }

    private var statusBar: some View {
        HStack {
            Text(model.notice).lineLimit(1)
            Spacer()
            let cost = model.queueEstimate
            Text("Estimate")
                .foregroundStyle(.secondary)
            Text("Scribe \(CostEstimator.format(cost.scribe))")
            Text("Translate \(CostEstimator.format(cost.translate))")
            Text("Summary \(CostEstimator.format(cost.summarize))")
            Text("Total \(CostEstimator.format(cost.total))")
                .fontWeight(.semibold)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
