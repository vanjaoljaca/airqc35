@main
struct QC35ControlApp: App {
    @NSApplicationDelegateAdaptor(QC35ApplicationDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class QC35ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        QC35Panel.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        QC35Panel.shared.show()
        return false
    }
}

@MainActor
final class QC35Panel: NSObject, NSWindowDelegate {
    static let shared = QC35Panel()
    private let model = QC35Model()
    private var panel: NSPanel?
    private let logger = Logger(subsystem: "com.vanja.qc35.control", category: "presentation")

    func show() {
        if panel == nil { createPanel() }
        guard let panel else { return }
        place(panel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !model.loading { model.refresh() }
    }

    private func createPanel() {
        let window = QC35GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 284),
            styleMask: [.borderless], backing: .buffered, defer: false)
        configure(window)
        window.contentView = makeGlass()
        panel = window
    }

    private func configure(_ window: NSPanel) {
        window.title = "QC35"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // The glass owns its rounded edge; a window shadow can outline the rectangular host.
        window.hasShadow = false
        window.level = .floating
        window.delegate = self
    }

    private func makeGlass() -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 26
        glass.effectIsInteractive = true
        glass.contentView = NSHostingView(rootView: QC35View(model: model))
        logger.info("{\"event\":\"glass_configured\",\"container\":\"NSGlassEffectView\",\"style\":\"regular\",\"legacyBackdrop\":false}")
        return glass
    }

    private func place(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 12,
            y: screen.visibleFrame.maxY - 8))
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }
}

final class QC35GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

import SwiftUI
import AppKit
import OSLog
