@main
struct QC35ControlApp: App {
    @NSApplicationDelegateAdaptor(QC35ApplicationDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class QC35ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        ControlCenter.shared.reloadControls(ofKind: "com.vanja.qc35.control.open")
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
        window.contentView = makeSurface(frame: window.contentLayoutRect)
        panel = window
    }

    private func makeSurface(frame: NSRect) -> NSView {
        let surface = QC35PanelSurface(frame: frame)
        surface.wantsLayer = true
        let glass = makeGlass()
        glass.frame = surface.bounds
        glass.autoresizingMask = [.width, .height]
        surface.addSubview(glass)
        return surface
    }

    private func configure(_ window: NSPanel) {
        window.title = "AirQc35"
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
        glass.cornerRadius = QC35PanelSurface.cornerRadius
        glass.effectIsInteractive = true
        glass.contentView = NSHostingView(rootView: QC35View(model: model, heightChanged: { [weak self] height in
            self?.resize(to: height)
        }))
        logger.info("{\"event\":\"glass_configured\",\"container\":\"NSGlassEffectView\",\"style\":\"regular\",\"cornerRadius\":26,\"surfaceClipped\":true}")
        return glass
    }

    private func place(_ window: NSWindow) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - window.frame.width - 12,
            y: screen.visibleFrame.maxY - 8))
    }

    private func resize(to height: CGFloat) {
        guard let panel, height.isFinite, height > 0 else { return }
        let maximum = (panel.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let target = min(ceil(height), maximum - 24)
        guard abs(panel.frame.height - target) > 0.5 else { return }
        panel.setContentSize(NSSize(width: 320, height: target))
        place(panel)
    }

    func windowWillClose(_ notification: Notification) { model.cancel() }
    func windowDidBecomeKey(_ notification: Notification) { model.resumeHeadsetObservation() }
    func windowDidResignKey(_ notification: Notification) { model.pauseHeadsetObservation() }
}

final class QC35PanelSurface: NSView {
    static let cornerRadius: CGFloat = 26
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { false }

    override func updateLayer() {
        // Glass curvature alone does not clip every backing layer at the window perimeter.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}

final class QC35GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

import SwiftUI
import AppKit
import OSLog
import WidgetKit
import QuartzCore
