import AppKit
import ArinCore
import SwiftUI

@main
struct ArinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Arin", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1040, height: 680)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan") { Task { await model.scan() } }
                    .keyboardShortcut("r")
                    .disabled(model.phase.isBusy)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Label(model.disk.freeBytes.compactBytes, systemImage: model.isLowOnSpace ? "externaldrive.fill.badge.exclamationmark" : "internaldrive")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        // `swift run` launches a bare executable; make it a regular app with a Dock icon and windows.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }
}

extension Int64 {
    /// "64 GB" for the menu bar.
    var compactBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: self)
    }
}
