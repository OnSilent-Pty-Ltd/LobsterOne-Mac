import AppKit
import SwiftUI

// MARK: - Checks

struct DiagnosticsView: View {
    @State private var checks: [DiagnosticCheck] = DiagnosticCheck.initial()
    @State private var lastRun: Date?
    @State private var isRunning = false
    @State private var isRescanning = false

    let onFix: (String) async -> String?
    let onForceRescan: (() async -> Void)?

    private let runChecks: () async -> [DiagnosticCheck]

    init(runChecks: @escaping () async -> [DiagnosticCheck],
         onFix: @escaping (String) async -> String?,
         onForceRescan: (() async -> Void)? = nil) {
        self.runChecks = runChecks
        self.onFix = onFix
        self.onForceRescan = onForceRescan
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                summary

                section("Checks") {
                    VStack(spacing: 0) {
                        ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                            if index > 0 { rowDivider }
                            checkRow(check)
                        }
                    }
                }

                if onForceRescan != nil {
                    section("Maintenance") { rescanRow }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
        .task { await runDiagnostics() }
    }

    /// One line that says how things stand, with the re-run button beside it.
    private var summary: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    if !isRunning {
                        Image(systemName: problems == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(problems == 0 ? PopoverPalette.successText : PopoverPalette.warningText)
                    }
                    Text(headline)
                        .font(BrandFonts.sans(17, weight: .semibold))
                }
                Text(subline)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
            }
            Spacer(minLength: 8)
            PillButton(disabled: isRunning) {
                Task { await runDiagnostics() }
            } label: {
                if isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    LineGlyph(data: HorizonGlyphs.refresh, size: 15)
                }
                Text(isRunning ? "Checking" : "Run again")
            }
        }
        .padding(.leading, 2)
    }

    private var problems: Int {
        checks.filter {
            switch $0.status {
            case .warning, .failed: return true
            default: return false
            }
        }.count
    }

    private var headline: String {
        if isRunning { return "Checking your setup\u{2026}" }
        if lastRun == nil { return "Not checked yet" }
        if problems == 0 { return "All \(checks.count) checks passed" }
        return problems == 1 ? "1 check needs attention" : "\(problems) checks need attention"
    }

    private var subline: String {
        guard let lastRun else { return "Looks at your shell, tool configs, keys and telemetry." }
        let time = lastRun.formatted(date: .omitted, time: .shortened)
        return problems == 0 ? "Last run at \(time)." : "Last run at \(time). Use Fix where it's offered."
    }

    private func checkRow(_ check: DiagnosticCheck) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                switch check.status {
                case .running, .fixing:
                    ProgressView().controlSize(.mini)
                default:
                    Image(systemName: check.sfSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colorForStatus(check.statusColor))
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                Text(check.detail)
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(detailColor(check))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if check.canFix {
                Button {
                    Task { await fix(checkId: check.id) }
                } label: {
                    Text("Fix")
                        .font(BrandFonts.sans(13, weight: .semibold))
                        .foregroundStyle(PopoverPalette.onBrand)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background(PopoverPalette.brand, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var rescanRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Re-import sessions")
                    .font(BrandFonts.sans(14.5, weight: .semibold))
                Text("Clears the session cache and imports every local session again. Use it if numbers look short.")
                    .font(BrandFonts.sans(12.5))
                    .foregroundStyle(PopoverPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PillButton(disabled: isRescanning) {
                Task {
                    isRescanning = true
                    await onForceRescan?()
                    isRescanning = false
                }
            } label: {
                if isRescanning { ProgressView().controlSize(.small) }
                Text(isRescanning ? "Rescanning" : "Rescan")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func runDiagnostics() async {
        isRunning = true
        for i in checks.indices { checks[i].status = .running }
        let results = await runChecks()
        checks = results
        lastRun = Date()
        isRunning = false
    }

    private func fix(checkId: String) async {
        guard let idx = checks.firstIndex(where: { $0.id == checkId }) else { return }
        checks[idx].status = .fixing
        if let error = await onFix(checkId) {
            checks[idx].status = .failed(error)
        } else {
            await runDiagnostics()
        }
    }

    /// Status rules: a pass is a tick in the success colour, warnings amber, failures red,
    /// everything else Stone.
    private func colorForStatus(_ name: String) -> Color {
        switch name {
        case "green": return PopoverPalette.successText
        case "yellow": return PopoverPalette.warningText
        case "red": return PopoverPalette.criticalText
        default: return PopoverPalette.secondary
        }
    }

    private func detailColor(_ check: DiagnosticCheck) -> Color {
        switch check.status {
        case .failed: return PopoverPalette.criticalText
        case .warning: return PopoverPalette.warningText
        default: return PopoverPalette.secondary
        }
    }
}

// MARK: - Debug log

/// The in-memory debug log as styled lines. Follows new lines while you're at the bottom,
/// and stays put when you've scrolled up to read.
struct DebugLogView: View {
    @ObservedObject private var log = DebugLog.shared
    @State private var atBottom = true
    @State private var copied = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent activity")
                        .font(BrandFonts.sans(17, weight: .semibold))
                    Text("The last \(DebugLog.capacity) lines. Errors show in red. Older lines are in the log file.")
                        .font(BrandFonts.sans(12.5))
                        .foregroundStyle(PopoverPalette.secondary)
                }
                Spacer(minLength: 8)
                if let url = log.fileURL {
                    PillButton {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Log file")
                    }
                }
                PillButton(disabled: log.entries.isEmpty) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.formatted, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                    Text(copied ? "Copied" : "Copy")
                }
            }
            .padding(.leading, 2)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if log.entries.isEmpty {
                            Text("Nothing logged yet.")
                                .font(BrandFonts.sans(12.5))
                                .foregroundStyle(PopoverPalette.secondary)
                        }
                        ForEach(log.entries) { entry in
                            line(entry)
                        }
                        Color.clear.frame(height: 1).id("end")
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .background(PopoverPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: log.entries.last?.id) { _, _ in
                    if atBottom { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
        }
    }

    private func line(_ entry: DebugLog.Entry) -> some View {
        let isError = Self.isError(entry.message)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Self.time.string(from: entry.timestamp))
                .foregroundStyle(PopoverPalette.tertiary)
            Text(entry.message)
                .foregroundStyle(isError ? PopoverPalette.criticalText : PopoverPalette.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(BrandFonts.mono(11.5))
    }

    /// Lines worth a second look: failures, errors and non-2xx HTTP statuses.
    static func isError(_ message: String) -> Bool {
        let lower = message.lowercased()
        if ["fail", "error", "denied", "invalid", "unauthorized", "expired", "timed out"].contains(where: lower.contains) { return true }
        return lower.range(of: #"http [45]\d\d"#, options: .regularExpression) != nil
    }
}

// MARK: - Shared pieces

/// A sentence-case label over a Sand card, as in Settings.
@MainActor private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title)
            .font(BrandFonts.sans(13, weight: .medium))
            .foregroundStyle(PopoverPalette.secondary)
            .padding(.leading, 2)
        content()
            .background(PopoverPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

@MainActor private var rowDivider: some View {
    Rectangle().fill(PopoverPalette.divider).frame(height: 1)
}

/// A secondary pill: page colour, Line strong border, Sand on hover.
private struct PillButton<Label: View>: View {
    var disabled = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .font(BrandFonts.sans(13.5, weight: .semibold))
                .foregroundStyle(PopoverPalette.text)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(hovering && !disabled ? PopoverPalette.hover : PopoverPalette.background, in: Capsule())
                .overlay(Capsule().strokeBorder(PopoverPalette.lineStrong))
                .contentShape(Capsule())
                .opacity(disabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}
