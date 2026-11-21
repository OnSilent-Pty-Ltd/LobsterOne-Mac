import AppKit
import SwiftUI

/// The window for Aurelia's digest: the decisions as a checklist, then what she wrote.
@MainActor
final class CrewDigestWindow {
    static let shared = CrewDigestWindow()
    private var window: NSWindow?

    func show(monitor: TeamMonitor) {
        window?.close()
        let view = CrewDigestView(monitor: monitor, close: { [weak self] in self?.window?.close() })
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

struct CrewDigestView: View {
    @ObservedObject var monitor: TeamMonitor
    let close: () -> Void


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    CrewFace(face: CrewDigestWriter.face, name: CrewDigestWriter.displayName, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Aurelia's digest")
                            .font(BrandFonts.sans(20, weight: .bold))
                            .tracking(-0.03 * 20)
                        Text(monitor.digest.map { "Written \(TeamFormat.when($0.date, now: Date()))" } ?? "Not written yet")
                            .font(BrandFonts.sans(13))
                            .foregroundStyle(PopoverPalette.secondary)
                    }
                }
                if let digest = monitor.digest {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !digest.decisions.isEmpty { decisions(digest.decisions) }
                            DigestText(text: digest.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: .infinity)
                } else {
                    Text("There is no digest yet. Ask for one from the Agents page.")
                        .font(BrandFonts.sans(13.5))
                        .foregroundStyle(PopoverPalette.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle().fill(PopoverPalette.divider).frame(height: 1)
            HStack(spacing: 8) {
                if let digest = monitor.digest {
                    button("Open the file", filled: false) { NSWorkspace.shared.open(digest.url) }
                }
                Spacer()
                button("Done", filled: true, action: close)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: AppWindow.fitted.width, height: AppWindow.fitted.height)
        .background(PopoverPalette.background)
        .foregroundStyle(PopoverPalette.text)
        .font(BrandFonts.sans(14))
    }

    private func decisions(_ decisions: [CrewDigest.Decision]) -> some View {
        let open = decisions.filter { !$0.done }.count
        return VStack(alignment: .leading, spacing: 8) {
            Text(open == 0 ? "Decisions, all made" : open == 1 ? "1 decision for you" : "\(open) decisions for you")
                .font(BrandFonts.sans(14, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(decisions.enumerated()), id: \.element.id) { index, decision in
                    if index > 0 { Rectangle().fill(PopoverPalette.divider).frame(height: 1) }
                    Button { Task { await monitor.setDecision(decision.id, done: !decision.done) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            ZStack {
                                Circle().stroke(decision.done ? PopoverPalette.successText : PopoverPalette.lineStrong, lineWidth: 1.5)
                                if decision.done {
                                    LineGlyph(data: HorizonGlyphs.check, size: 11, lineWidth: 2.4)
                                        .foregroundStyle(PopoverPalette.successText)
                                }
                            }
                            .frame(width: 18, height: 18)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                            (Text(decision.member.map { "\($0): " } ?? "").fontWeight(.semibold) + DigestText.inline(decision.text))
                                .font(BrandFonts.sans(13))
                                .strikethrough(decision.done)
                                .foregroundStyle(decision.done ? PopoverPalette.secondary : PopoverPalette.text)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(decision.member.map { "\($0): " } ?? "")\(decision.text)")
                    .accessibilityValue(decision.done ? "Decided" : "Waiting")
                    .accessibilityHint(decision.done ? "Marks it as waiting again" : "Marks it as decided")
                }
            }
            .background(PopoverPalette.blush, in: RoundedRectangle(cornerRadius: 12))
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

/// The digest's own text: headings, bullets and paragraphs, with bold and code kept. Nothing fancier;
/// the digest is asked for in that shape.
struct DigestText: View {
    let text: String

    private struct Block: Identifiable {
        enum Kind { case heading, bullet(indent: Int), paragraph }
        let id: Int
        let kind: Kind
        let text: String
    }

    private var blocks: [Block] {
        var result: [Block] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("# ") else { continue } // the window has its own title
            let indent = line.prefix { $0 == " " }.count / 2
            if trimmed.hasPrefix("## ") {
                result.append(Block(id: result.count, kind: .heading, text: String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                result.append(Block(id: result.count, kind: .bullet(indent: indent), text: String(trimmed.dropFirst(2))))
            } else {
                result.append(Block(id: result.count, kind: .paragraph, text: trimmed))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading:
                    Text(block.text)
                        .font(BrandFonts.sans(14, weight: .semibold))
                        .padding(.top, block.id == 0 ? 0 : 10)
                case .bullet(let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\u{2022}").foregroundStyle(PopoverPalette.secondary)
                        Self.inline(block.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(BrandFonts.sans(13))
                    .padding(.leading, CGFloat(indent) * 16)
                case .paragraph:
                    Self.inline(block.text)
                        .font(BrandFonts.sans(13))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Bold, italics and `code` from the digest's Markdown; plain text if it will not parse.
    static func inline(_ markdown: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)).map(Text.init) ?? Text(markdown)
    }
}
