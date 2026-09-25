import AppKit
import SwiftUI

private final class FloatingCaptionPanel: NSPanel {
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(clamped(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        super.setFrame(clamped(frameRect), display: flag, animate: animateFlag)
    }

    private func clamped(_ frameRect: NSRect) -> NSRect {
        guard minSize.width > 0, minSize.height > 0 else { return frameRect }
        var frame = frameRect
        let topEdge = frame.maxY
        frame.size.width = max(frame.width, minSize.width)
        frame.size.height = max(frame.height, minSize.height)
        frame.origin.y = topEdge - frame.height
        return frame
    }
}

@MainActor
final class FloatingCaptionWindowController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    func show(model: LiveModeModel) {
        if let panel {
            if panel.isMiniaturized { panel.deminiaturize(nil) }
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }

        let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let panel = FloatingCaptionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 150),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Live Captions"
        panel.contentMinSize = NSSize(width: 320, height: 90)
        panel.minSize = panel.frameRect(
            forContentRect: NSRect(x: 0, y: 0, width: 320, height: 90)
        ).size
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.backgroundColor = .black
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingCaptionView(model: model))
        position(panel, relativeTo: parentWindow)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSPanel === panel else { return }
        panel?.contentView = nil
        panel = nil
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        return NSSize(
            width: max(frameSize.width, sender.minSize.width),
            height: max(frameSize.height, sender.minSize.height)
        )
    }

    func windowDidResize(_ notification: Notification) {
        guard let sender = notification.object as? NSWindow,
              sender === panel,
              sender.frame.width < sender.minSize.width ||
                sender.frame.height < sender.minSize.height else { return }
        var frame = sender.frame
        let topEdge = frame.maxY
        frame.size.width = max(frame.width, sender.minSize.width)
        frame.size.height = max(frame.height, sender.minSize.height)
        frame.origin.y = topEdge - frame.height
        sender.setFrame(frame, display: true)
    }

    private func position(_ panel: NSPanel, relativeTo parent: NSWindow?) {
        guard let parent else {
            panel.center()
            return
        }
        let visibleFrame = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? parent.frame
        let idealOrigin = NSPoint(
            x: parent.frame.midX - panel.frame.width / 2,
            y: parent.frame.minY + 48
        )
        panel.setFrameOrigin(NSPoint(
            x: min(max(idealOrigin.x, visibleFrame.minX), visibleFrame.maxX - panel.frame.width),
            y: min(max(idealOrigin.y, visibleFrame.minY), visibleFrame.maxY - panel.frame.height)
        ))
    }
}

private struct FloatingCaptionView: View {
    @ObservedObject var model: LiveModeModel
    @AppStorage("floatingCaptionTextSize") private var textSize = 22.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "textformat.size.smaller")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $textSize, in: 14...48, step: 1)
                    .frame(width: 150)
                    .accessibilityLabel("Caption text size")
                    .help("Caption text size")
                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("\(Int(textSize))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
                    .accessibilityLabel("\(Int(textSize)) points")
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)

            Divider()

            ScrollView(.vertical) {
                VStack(spacing: max(4, textSize * 0.27)) {
                    Spacer(minLength: 0)
                    Text(model.floatingCaptionText.isEmpty
                         ? "Waiting for speech"
                         : model.floatingCaptionText)
                        .font(.system(size: textSize, weight: .semibold))
                        .foregroundStyle(
                            model.floatingCaptionText.isEmpty ? Color.secondary : Color.white
                        )
                        .multilineTextAlignment(.center)
                        .lineSpacing(max(2, textSize * 0.14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                    if !model.floatingTranslationText.isEmpty {
                        Text(model.floatingTranslationText)
                            .font(.system(size: max(12, textSize * 0.77)))
                            .foregroundStyle(Color(red: 0.75, green: 0.80, blue: 0.96))
                            .multilineTextAlignment(.center)
                            .lineSpacing(max(2, textSize * 0.1))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 66)
            }
        }
        .accessibilityLabel("Floating live captions")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
