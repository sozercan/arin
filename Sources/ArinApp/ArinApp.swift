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
        .defaultSize(width: 1180, height: 720)
        .defaultLaunchBehavior(.presented)
        .commands { ArinCommands(model: model) }

        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            // Same drive in both states; filled when below the alert threshold.
            Label(model.disk.freeBytes.compactBytes, systemImage: model.isLowOnSpace ? "internaldrive.fill" : "internaldrive")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// Menu items stay text-only, as macOS 27 menus do.
private struct ArinCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button(model.canStop ? "Stop" : "Scan") {
                model.canStop ? model.stop() : model.startScan()
            }
            .keyboardShortcut("r")
            .disabled(model.phase.isBusy && !model.canStop)
            Button("Review with Agent") { model.startReview() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canReview)
            Divider()
            Button("Clean…") { model.showingConfirm = true }
                .disabled(!model.canClean)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Select Safe Items") { model.selectSafe(in: model.visibleCandidates) }
                .disabled(model.report == nil || model.visibleCandidates.isEmpty)
            Button("Select None") { model.setAll(model.visibleCandidates, selected: false) }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(model.report == nil || model.visibleCandidates.isEmpty)
        }

        CommandGroup(before: .sidebar) {
            Button("All Items") { model.sidebar = .all }
                .keyboardShortcut("1")
            Button("Space Map") { model.sidebar = .map }
                .keyboardShortcut("2")
                .disabled(model.report == nil)
            Button("Insights") { model.sidebar = .insights }
                .keyboardShortcut("3")
                .disabled(model.report.map { $0.insights.isEmpty && $0.ruleErrors.isEmpty } ?? true)
            Button("History") { model.sidebar = .history }
                .keyboardShortcut("4")
            Divider()
            Button(model.showingInspector ? "Hide Inspector" : "Show Inspector") { model.showingInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
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
