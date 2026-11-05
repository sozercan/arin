import ArinCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiskGauge(disk: model.disk, threshold: model.lowSpaceThreshold, compact: true)
            if model.isLowOnSpace {
                Label("Below your \(model.lowSpaceThresholdGB) GB alert threshold", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if model.phase.isBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.phase.label).font(.caption).lineLimit(2)
                }
            } else if let report = model.report {
                let safe = model.candidates.filter { $0.isDefaultSelected(at: model.level) }
                Text("\(safe.dedupedBytes.formattedBytes) safe to clean at \(model.level.label) · scanned \(report.finishedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Open Arin") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Button("Scan") {
                    openWindow(id: "main")
                    Task { await model.scan() }
                }
                .disabled(model.phase.isBusy)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Arin")
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refreshDisk() }
    }
}
