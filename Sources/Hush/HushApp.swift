import AppKit
import HushCore
import SwiftUI

@main
struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Panel(headphones: appDelegate.headphones)
        } label: {
            Image(systemName: appDelegate.headphones.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let headphones = Headphones()
    private var previewWindow: NSWindow?
    private var debugControl: DebugControl?

    func applicationDidFinishLaunching(_ notification: Notification) {
        headphones.start()
        if DebugControl.isEnabled {
            debugControl = DebugControl(headphones: headphones)
            debugControl?.start()
        }
        if CommandLine.arguments.contains("--window") {
            showPreviewWindow()
        } else {
            // Hush runs only when you start it (e.g. from Spotlight), so show
            // the panel right away instead of making you find the icon.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                openPanel()
            }
        }
    }

    /// Launching Hush again from Spotlight while it's running lands here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPanel()
        return false
    }

    /// Opens the menu bar panel as if the icon were clicked. SwiftUI's
    /// MenuBarExtra has no API for this, so press its status bar button.
    private func openPanel() {
        let panelIsOpen = NSApp.windows.contains { $0.isVisible && $0.className.contains("MenuBarExtraWindow") }
        guard !panelIsOpen else { return }
        let button = NSApp.windows
            .filter { $0.className.contains("StatusBarWindow") }
            .compactMap { $0.contentView.flatMap(Self.statusButton(in:)) }
            .first
        guard let button else {
            Log.info("app", "couldn't find the menu bar button to open the panel")
            return
        }
        button.performClick(nil)
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }

    /// Developer aid: `Hush --window` shows the panel in a normal window,
    /// so it can be inspected and screenshotted like any app.
    private func showPreviewWindow() {
        NSApp.setActivationPolicy(.regular)
        let host = NSHostingView(rootView: Panel(headphones: headphones))
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.addSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Hush"
        window.contentView = effect
        window.setContentSize(host.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        NSApp.activate()
    }
}

extension Headphones {
    var menuBarSymbol: String {
        switch status {
        case .searching, .unsupported, .unreachable:
            "headphones.slash"
        case .connecting, .connected, .resting:
            noise?.mode == .ambient ? "ear.and.waveform" : "headphones"
        }
    }
}
