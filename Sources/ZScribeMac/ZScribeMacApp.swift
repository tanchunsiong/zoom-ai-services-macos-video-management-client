import SwiftUI
import AppKit

@main
struct ZScribeMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Z Scribe") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .task { await model.initialize() }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    model.live.abort()
                }
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
            CommandMenu("Live") {
                Button("Show Live Transcription") {
                    model.selectedSection = .live
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
