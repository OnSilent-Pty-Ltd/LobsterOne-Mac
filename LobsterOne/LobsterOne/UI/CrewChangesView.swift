import AppKit
import SwiftUI

/// The window that shows what changed in a crew member's charter and notebook since the person last looked.
@MainActor
final class CrewChangesWindow {
    static let shared = CrewChangesWindow()
    private var window: NSWindow?

    func show(member: String, monitor: TeamMonitor) {
        window?.close()
        let note = monitor.report.notes[member]
        let view = CrewChangesView(
            name: note?.displayName ?? TeamScanner.title(member), face: note?.face,
            changes: monitor.changes(for: member),
            attention: monitor.report.attention.first { $0.member == member && $0.kind != .notebookFull }?.kind,
            keep: { [weak self] in
                Task { await monitor.acceptCharter(member); await monitor.markSeen(member) }
                self?.window?.close()
            },
            restore: { [weak self] in
                Task { await monitor.restoreCharter(member); await monitor.markSeen(member) }
                self?.window?.close()
            },
            done: { [weak self] in
                Task { await monitor.markSeen(member) }
                self?.window?.close()
            })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Crew"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = PopoverPalette.backgroundNS
        window.isReleasedWhenClosed = false
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct CrewChangesView: View {
    let name: String
    let face: String?
    let changes: [CrewKeeper.Change]
    /// Set when the charter was edited outside the app or has lost its guard.
    let attention: CrewAttention.Kind?
    let keep: () -> Void
    let restore: () -> Void
    let done: () -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    CrewFace(face: face, name: name, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("What changed for \(name)")
                            .font(BrandFonts.sans(20, weight: .bold))
                            .tracking(-0.03 * 20)
                        Text(subtitle)
                            .font(BrandFonts.sans(13))
                            .foregroundStyle(PopoverPalette.secondary)
                    }
                }
                if let attention { warning(attention) }
                if changes.isEmpty {
                    Text("Nothing has changed since you last looked.")
                        .font(BrandFonts.sans(13.5))
                        .foregroundStyle(PopoverPalette.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(changes, id: \.kind) { section($0) }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(PopoverPalette.divider).frame(height: 1)
            footer
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
        }
        .frame(width: AppWindow.fitted.width, height: AppWindow.fitted.height)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
        .font(BrandFonts.sans(14))
    }

    private var subtitle: String {
        guard let earliest = changes.map(\.since).min() else { return "Charter and notebook" }
        return "Since \(TeamFormat.when(earliest, now: Date()))"
    }

    private func warning(_ kind: CrewAttention.Kind) -> some View {
        let missing = kind == .guardMissing
        return Text(missing
                    ? "The rule that kept \(name) to the notebook is no longer in this charter. Until it is back, nothing stops writes elsewhere."
                    : "This charter was edited outside LobsterOne. Keep the edit, or put the old charter back.")
            .font(BrandFonts.sans(13))
            .foregroundStyle(missing ? PopoverPalette.criticalText : PopoverPalette.brandText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(missing ? PopoverPalette.criticalBackground : PopoverPalette.blush, in: RoundedRectangle(cornerRadius: 12))
    }

    private func section(_ change: CrewKeeper.Change) -> some View {
        let counts = LineDiff.counts(change.lines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(change.kind == .charter ? "Charter" : "Notebook")
                    .font(BrandFonts.sans(14, weight: .semibold))
                Spacer()
                if counts.added > 0 {
                    Text("+\(counts.added)").foregroundStyle(PopoverPalette.successText)
                }
                if counts.removed > 0 {
                    Text("\u{2212}\(counts.removed)").foregroundStyle(PopoverPalette.criticalText)
                }
            }
            .font(BrandFonts.sans(12.5, weight: .semibold))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(change.kind == .charter ? "Charter" : "Notebook"): \(counts.added) lines added, \(counts.removed) removed")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(LineDiff.collapsed(change.lines).enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(.vertical, 6)
            .background(PopoverPalette.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func row(_ line: LineDiff.Line) -> some View {
        switch line.kind {
        case .gap:
            Text("\u{22EF}")
                .font(BrandFonts.mono(11))
                .foregroundStyle(PopoverPalette.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
        case .same, .added, .removed:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.kind == .added ? "+" : line.kind == .removed ? "\u{2212}" : " ")
                    .frame(width: 10)
                    .accessibilityLabel(line.kind == .added ? "Added" : line.kind == .removed ? "Removed" : "")
                Text(line.text.isEmpty ? " " : line.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .font(BrandFonts.mono(11))
            .foregroundStyle(line.kind == .added ? PopoverPalette.successText
                             : line.kind == .removed ? PopoverPalette.criticalText : PopoverPalette.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(line.kind == .added ? PopoverPalette.successBackground
                        : line.kind == .removed ? PopoverPalette.criticalBackground : Color.clear)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if attention != nil {
                button("Put the old charter back", filled: false, action: restore)
            }
            Spacer()
            if attention == .charterEdited {
                button("Keep the edit", filled: true, action: keep)
            } else {
                button("Done", filled: true, action: done)
            }
        }
    }

    private func button(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFonts.sans(13, weight: .semibold))
                .foregroundStyle(filled ? PopoverPalette.onBrand : PopoverPalette.text)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(filled ? PopoverPalette.brand : PopoverPalette.card, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
