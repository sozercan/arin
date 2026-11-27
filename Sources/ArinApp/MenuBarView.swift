import ArinCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(title: "Disk", symbol: "internaldrive")
                DiskGauge(disk: model.disk, threshold: model.lowSpaceThreshold, findings: model.findingsByCategory, compact: true)
                if model.isLowOnSpace {
                    Label("Below your \(model.lowSpaceThresholdGB) GB alert threshold", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .card(padding: 12)

            if model.phase.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.phase.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .card(padding: 12)
            } else if let report = model.report {
                Button(action: openMain) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            CardLabel(title: "Safe to clean", symbol: "checkmark.seal")
                            SizeText(bytes: model.safeBytes, size: 22)
                            Text("\(model.level.label) · scanned \(report.finishedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .card(padding: 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Arin to review")
            }

            if model.lifetimeFreedBytes > 0 {
                HStack(alignment: .firstTextBaseline) {
                    CardLabel(title: "Freed so far", symbol: "leaf")
                    Spacer()
                    SizeText(bytes: model.lifetimeFreedBytes, size: 16)
                }
                .card(padding: 12)
            }

            HStack {
                Button("Open Arin", action: openMain)
                if model.canStop {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Scan") {
                        openMain()
                        model.startScan()
                    }
                    .disabled(model.phase.isBusy)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Arin")
            }
            .padding(.horizontal, 2)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 310)
        .tint(Theme.signature)
        .onAppear { model.refreshDisk() }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
