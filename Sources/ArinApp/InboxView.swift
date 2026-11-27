import AppKit
import ArinCore
import SwiftUI

struct InboxView: View {
    @Environment(AppModel.self) private var model
    var box: AppModel.Mailbox
    @State private var current: Candidate.ID?

    var body: some View {
        let items = model.candidates(in: box)
        let item = items.first { $0.id == current }
        HStack(spacing: 0) {
            MessageList(box: box, items: items, current: $current, advance: { advance(from: $0, in: items) })
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 400)
            Divider()
            Group {
                if let item {
                    Reader(candidate: item, advance: { advance(from: item, in: items) })
                        .id(item.id)
                } else {
                    EmptyMailbox(box: box)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(box.title)
        .navigationSubtitle(items.isEmpty ? "Empty" : "\(items.count) \(items.count == 1 ? "item" : "items"), \(items.dedupedBytes.formattedBytes)")
        .onAppear { pickFirst(items) }
        .onChange(of: box) { pickFirst(model.candidates(in: box)) }
        .onChange(of: items.map(\.id)) { pickFirst(model.candidates(in: box)) }
        .onChange(of: current) { _, id in
            if let id { model.openedIDs.insert(id) }
        }
        .onChange(of: model.report?.finishedAt) {
            if let current { model.openedIDs.insert(current) }
        }
    }

    private func pickFirst(_ items: [Candidate]) {
        if current == nil || !items.contains(where: { $0.id == current }) {
            current = items.first { !model.openedIDs.contains($0.id) }?.id ?? items.first?.id
        }
    }

    private func advance(from item: Candidate, in items: [Candidate]) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let rest = items[(index + 1)...] + items[..<index]
        current = (rest.first { !model.openedIDs.contains($0.id) } ?? rest.first)?.id ?? item.id
    }
}

private struct MessageList: View {
    @Environment(AppModel.self) private var model
    var box: AppModel.Mailbox
    var items: [Candidate]
    @Binding var current: Candidate.ID?
    var advance: (Candidate) -> Void

    var body: some View {
        List(selection: $current) {
            if box == .safe, !items.isEmpty {
                Section {
                    Button {
                        model.confirmClean(items)
                    } label: {
                        Label("Clean All \(items.dedupedBytes.formattedBytes)…", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.phase.isBusy)
                    .padding(.vertical, 4)
                    .selectionDisabled()
                }
            }
            ForEach(items) { item in
                MessageRow(candidate: item, unread: box == .review && !model.openedIDs.contains(item.id))
                    .tag(item.id)
            }
        }
        .listStyle(.inset)
        .onKeyPress(.delete) { act { model.confirmClean([$0]) } }
        .onKeyPress(characters: ["k"]) { _ in
            act { item in
                guard item.kept || item.isActionable else { return }
                model.setKept(item.id, title: item.title, paths: item.paths, !item.kept)
            }
        }
        .onKeyPress(characters: ["n"]) { _ in act(advance) }
    }

    private func act(_ action: (Candidate) -> Void) -> KeyPress.Result {
        guard let item = items.first(where: { $0.id == current }) else { return .ignored }
        action(item)
        return .handled
    }
}

private struct MessageRow: View {
    var candidate: Candidate
    var unread: Bool

    var body: some View {
        let sender = Sender(candidate)
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(unread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(candidate.bytes > 0 ? candidate.bytes.formattedBytes : "Unknown")
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Image(systemName: candidate.category.symbol)
                        .foregroundStyle(candidate.category.color)
                        .imageScale(.small)
                    Text(candidate.title).lineLimit(1)
                }
                Group {
                    if candidate.agentVerdict == nil, candidate.blockers.isEmpty {
                        Text(ruleText: candidate.detail)
                    } else {
                        Text(candidate.summaryLine)
                    }
                }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(unread ? "Unread. " : "")From \(sender.name). \(candidate.title), \(candidate.bytes.formattedBytes). \(candidate.summaryLine)")
    }
}

private struct Reader: View {
    @Environment(AppModel.self) private var model
    var candidate: Candidate
    var advance: () -> Void

    var body: some View {
        let sender = Sender(candidate)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    SenderAvatar(sender: sender, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sender.name).font(.headline)
                        Text(sender.detail(reviewed: model.lastReview?.date))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    RiskBadge(risk: candidate.effectiveRisk, fromAgent: candidate.agentVerdict != nil)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title)
                        .font(.title.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(facts)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let verdict = candidate.agentVerdict {
                    Text(verdict.reason)
                        .font(.title3)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(ruleText: candidate.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(ruleText: candidate.detail)
                        .font(.title3)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if !candidate.blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(candidate.blockers, id: \.self) { blocker in
                            Label {
                                Text(blocker).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                }

                if candidate.isActionable {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Cleaning runs")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(candidate.action.summary)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if !candidate.paths.isEmpty {
                    locations
                }
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaBar(edge: .bottom) { actions }
    }

    private var facts: String {
        var parts = [candidate.bytes > 0 ? candidate.bytes.formattedBytes : "Size unknown", candidate.category.label, "\(candidate.level.label) level"]
        if let modified = candidate.lastModified {
            parts.append("modified \(modified.formatted(.relative(presentation: .named)))")
        }
        if model.target.isRemote { parts.append("on \(model.target.displayName)") }
        return parts.joined(separator: ", ")
    }

    private var locations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(candidate.paths.count == 1 ? "Location" : "\(candidate.paths.count) locations")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(candidate.paths.prefix(6), id: \.self) { path in
                HStack(spacing: 6) {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                    if !model.target.isRemote {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Image(systemName: "arrow.forward.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                        .accessibilityLabel("Reveal \(path) in Finder")
                    }
                }
            }
            if candidate.paths.count > 6 {
                Text("and \(candidate.paths.count - 6) more")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            if candidate.kept {
                Text("On your keep list. Arin won't select, review, or clean it.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop Keeping") { model.setKept(candidate.id, title: candidate.title, paths: candidate.paths, false) }
                    .help("Remove it from your keep list (K)")
            } else if !candidate.isActionable {
                Text("Arin reports this but has no command to clean it.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if candidate.effectiveRisk == .keep {
                Text("\(Sender(candidate).name) says to keep this, so Arin won't select it.")
                    .foregroundStyle(.secondary)
                Spacer()
                cleanButton(prominent: false)
            } else {
                cleanButton(prominent: true)
                if model.mailbox(of: candidate) == .review {
                    Button("Not Now", action: advance)
                        .help("Leave it and go to the next item (N)")
                }
                Spacer()
                Button("Always Keep") { model.setKept(candidate.id, title: candidate.title, paths: candidate.paths, true) }
                    .help("Add it to your keep list so Arin never cleans it (K)")
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func cleanButton(prominent: Bool) -> some View {
        let button = Button {
            model.confirmClean([candidate])
        } label: {
            Text(candidate.bytes > 0 ? "Clean \(candidate.bytes.formattedBytes)…" : "Clean…").monospacedDigit()
        }
        .disabled(model.phase.isBusy)
        .help("Review and confirm cleaning this item (Delete)")
        if prominent { button.buttonStyle(.borderedProminent) } else { button }
    }
}

private struct EmptyMailbox: View {
    @Environment(AppModel.self) private var model
    var box: AppModel.Mailbox

    var body: some View {
        switch box {
        case .review:
            let safe = model.candidates(in: .safe)
            ContentUnavailableView {
                Label("Nothing Needs a Look", systemImage: "checkmark.seal")
            } description: {
                Text(safe.isEmpty ? "Every item is either safe to clean or kept." : "\(safe.dedupedBytes.formattedBytes) is safe to clean whenever you're ready.")
            } actions: {
                if !safe.isEmpty {
                    Button("Show Safe to Clean") { model.sidebar = .inbox(.safe) }
                }
            }
        case .safe:
            ContentUnavailableView("Nothing Safe to Clean", systemImage: "tray", description: Text("Try a deeper level, or ask your agent to review the items that need a look."))
        case .kept:
            ContentUnavailableView("Nothing Kept", systemImage: "lock.open", description: Text("Items you always keep, and items your agent says to keep, show up here."))
        }
    }
}

struct Sender {
    enum Kind { case rules, agent, you }

    var kind: Kind
    var name: String
    var ruleName: String?

    init(_ candidate: Candidate) {
        if candidate.kept {
            kind = .you
            name = "You"
        } else if let verdict = candidate.agentVerdict {
            kind = .agent
            name = verdict.agent
        } else {
            kind = .rules
            name = "Arin"
            ruleName = Self.ruleNames[candidate.ruleID]
        }
    }

    func detail(reviewed: Date?) -> String {
        switch kind {
        case .you: "On your keep list"
        case .agent: reviewed.map { "Reviewed read-only \($0.formatted(.relative(presentation: .named)))" } ?? "Reviewed read-only"
        case .rules: ruleName.map { "Found by the \($0) rule" } ?? "Found by a cleanup rule"
        }
    }

    var color: Color {
        switch kind {
        case .you: .gray
        case .rules: .teal
        case .agent:
            if name.localizedStandardContains("claude") { .orange }
            else if name.localizedStandardContains("codex") { .blue }
            else if name.localizedStandardContains("copilot") { .purple }
            else { .indigo }
        }
    }

    var initials: String? {
        guard kind == .agent else { return nil }
        let words = name.split(separator: " ").filter { $0.first?.isUppercase == true }
        return String(words.prefix(2).compactMap(\.first))
    }

    var symbol: String {
        switch kind {
        case .you: "person.fill"
        case .rules: "checklist"
        case .agent: "sparkles"
        }
    }

    private static let ruleNames = Catalog.ruleNames
}

struct SenderAvatar: View {
    var sender: Sender
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(sender.color.gradient)
            if let initials = sender.initials, !initials.isEmpty {
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            } else {
                Image(systemName: sender.symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Candidate {
    var summaryLine: String {
        agentVerdict?.reason ?? blockers.first ?? detail
    }
}

extension Text {
    init(ruleText: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        self.init((try? AttributedString(markdown: ruleText, options: options)) ?? AttributedString(ruleText))
    }
}
