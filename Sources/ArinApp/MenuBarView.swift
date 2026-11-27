import AppKit
import ArinCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DiskGauge(disk: model.disk, threshold: model.lowSpaceThreshold, compact: true)
            if model.isLowOnSpace {
                Label {
                    Text("Below your \(model.lowSpaceThresholdGB) GB alert threshold")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .font(.callout)
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
                if model.canStop {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Scan") {
                        openWindow(id: "main")
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
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.refreshDisk() }
    }
}

enum TankIcon {
    static func level(free: Int64, threshold: Int64, total: Int64) -> (fill: Double, alert: Double) {
        let window = Double(max(min(100_000_000_000, total), threshold * 4, 1))
        let fill = 1 - min(max(Double(free) / window, 0), 1)
        let alert = 1 - min(Double(threshold) / window, 1)
        return (fill, alert)
    }

    static func image(free: Int64, threshold: Int64, total: Int64) -> NSImage {
        let (fill, alert) = level(free: free, threshold: threshold, total: total)
        let image = NSImage(size: NSSize(width: 13, height: 16), flipped: false) { _ in
            let body = NSRect(x: 2, y: 0.75, width: 9, height: 14.5)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6)
            outline.lineWidth = 1.3
            NSColor.black.set()
            outline.stroke()
            let inner = body.insetBy(dx: 1.9, dy: 1.9)
            let water = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * fill)
            NSBezierPath(roundedRect: water, xRadius: 1, yRadius: 1).fill()
            let y = inner.minY + inner.height * alert
            NSBezierPath(rect: NSRect(x: 0, y: y - 0.5, width: 1.6, height: 1)).fill()
            NSBezierPath(rect: NSRect(x: 11.4, y: y - 0.5, width: 1.6, height: 1)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Disk"
        return image
    }
}
