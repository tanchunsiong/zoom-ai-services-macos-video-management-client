import SwiftUI

@main
struct ZScribeMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Z Scribe") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .task { await model.initialize() }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Media...") { model.chooseFiles() }
                    .keyboardShortcut("o")
                Button(model.isRunning ? "Pause or Resume Queue" : "Start Queue") {
                    model.startQueue()
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}
