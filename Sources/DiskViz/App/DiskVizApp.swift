import AppKit
import SwiftUI

@main
struct DiskVizApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("DiskViz") {
            ContentView(initialScanPath: Self.initialScanPath)
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private extension DiskVizApp {
    static var initialScanPath: String {
        if let envPath = ProcessInfo.processInfo.environment["DISKVIZ_SCAN_PATH"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envPath
        }

        return CommandLine.arguments.dropFirst().first { argument in
            !argument.hasPrefix("-")
        } ?? "/"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
