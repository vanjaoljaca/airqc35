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

    func show() {
        if panel == nil { createPanel() }
        guard let panel else { return }
        place(panel)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !model.loading { model.refresh() }
    }

    private func createPanel() {
        let window = QC35GlassPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "QC35"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.delegate = self
        window.contentView = makeBackdrop()
        panel = window
    }

    private func makeBackdrop() -> NSVisualEffectView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 26
        backdrop.layer?.masksToBounds = true
        embed(makeGlass(), in: backdrop)
        return backdrop
    }

    private func embed(_ glass: NSView, in backdrop: NSView) {
        glass.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            glass.topAnchor.constraint(equalTo: backdrop.topAnchor),
            glass.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])
    }

    private func makeGlass() -> NSGlassEffectView {
        let hosting = NSHostingView(rootView: QC35View(model: model))
        let glass = NSGlassEffectView()
        glass.style = .clear
        glass.cornerRadius = 26
        glass.effectIsInteractive = true
        glass.contentView = hosting
        recordMaterial(hosting)
        return glass
    }

    private func recordMaterial(_ hosting: NSView) {
        let values: [String: Any] = ["event": "glass_configured", "style": "clear", "container": "NSGlassEffectView", "backdrop": "NSVisualEffectView.behindWindow",
            "hostingOpaque": hosting.isOpaque, "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "increaseContrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast]
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QC35InputGuard/ControlCenter/material.json")
        do { try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]).write(to: path, options: .atomic) }
        catch { NSLog("{\"event\":\"glass_configuration_log_failed\",\"error\":\"%@\"}", error.localizedDescription) }
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
    override func cancelOperation(_ sender: Any?) { close() }
}

import SwiftUI
import AppKit
