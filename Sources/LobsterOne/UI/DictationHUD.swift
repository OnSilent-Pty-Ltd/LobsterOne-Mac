import AppKit
import Combine
import SwiftUI

/// The small pill near the bottom of the screen while dictating: a level meter and the words
/// so far, or a one-line notice. It floats over the app being dictated into and must never take
/// focus from it, or the paste would land in LobsterOne instead.
@MainActor
final class DictationHUD {
    /// The panel is a fixed size; the pill sits at its bottom centre and sizes to its text.
    /// The spare room is for the shadow and costs nothing, since the panel ignores the mouse.
    static let panelSize = NSSize(width: 460, height: 76)
    /// Distance from the bottom of the visible screen (above the Dock) to the pill.
    static let bottomInset: CGFloat = 44
    /// Room under the pill inside the panel, for its shadow.
    static let shadowRoom: CGFloat = 14
    /// How much of a long transcript is shown: the end, where the words are arriving.
    nonisolated static let tailLength = 80

    private let controller: DictationController
    private var panel: NSPanel?
    private var stateObserver: AnyCancellable?
    private var wantsVisible = false

    init(controller: DictationController) {
        self.controller = controller
        stateObserver = controller.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.update(state) }
    }

    private func update(_ state: DictationController.State) {
        if state == .idle { hide() } else { show() }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard !wantsVisible else { return }
        wantsVisible = true
        place(panel)
        panel.alphaValue = 0
        // orderFrontRegardless shows the panel without activating LobsterOne.
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard wantsVisible, let panel else { return }
        wantsVisible = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again while fading out: leave it up.
                guard let self, !self.wantsVisible else { return }
                panel.orderOut(nil)
            }
        })
    }

    /// Bottom centre of the screen the pointer is on, which is usually the one being typed on.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let size = Self.panelSize
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + Self.bottomInset - Self.shadowRoom))
    }

    private func makePanel() -> NSPanel {
        let panel = DictationHUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        // Always the dark ink pill, whatever the system look, so it reads the same over any app.
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: DictationHUDView(controller: controller))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        panel.contentView = host
        return panel
    }

    /// The end of the transcript, starting at a word where possible, with an ellipsis when
    /// the start was cut. The text field also truncates at the head to fit its width; this
    /// keeps a long dictation from laying out thousands of characters on every partial.
    nonisolated static func tail(of text: String, limit: Int = tailLength) -> String {
        guard text.count > limit, limit > 0 else { return text }
        var tail = Substring(text.suffix(limit))
        // Drop a word cut in half, unless that would throw away most of the line.
        if let space = tail.firstIndex(of: " "), tail.distance(from: tail.startIndex, to: space) < limit / 3 {
            tail = tail[tail.index(after: space)...]
        }
        return "\u{2026}" + tail
    }
}

/// Never key, never main: the panel can't take focus away from the app being dictated into.
private final class DictationHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct DictationHUDView: View {
    @ObservedObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            pill
                .frame(maxWidth: 400)
                .padding(.bottom, DictationHUD.shadowRoom)
        }
        .frame(width: DictationHUD.panelSize.width, height: DictationHUD.panelSize.height)
        .environment(\.colorScheme, .dark)
    }

    private var pill: some View {
        HStack(spacing: 11) {
            if showsMeter {
                DictationLevelMeter(level: controller.level, live: controller.state == .listening, reduceMotion: reduceMotion)
            }
            Text(line)
                .font(BrandFonts.sans(13.5, weight: .medium))
                .foregroundStyle(lineIsPlaceholder ? PopoverPalette.secondary : PopoverPalette.text)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.leading, showsMeter ? 14 : 18)
        .padding(.trailing, 18)
        .frame(height: 38)
        .background(PopoverPalette.background, in: Capsule())
        .overlay(Capsule().strokeBorder(PopoverPalette.border))
        .shadow(color: .black.opacity(0.3), radius: 9, y: 3)
    }

    private var showsMeter: Bool {
        controller.state == .listening || controller.state == .transcribing
    }

    private var line: String {
        switch controller.state {
        case .notice(let text): return text
        case .listening, .transcribing, .idle:
            // While typing as it goes, the words are already in the field.
            if controller.partial.isEmpty || controller.isStreaming {
                return controller.state == .transcribing ? "\u{2026}" : "Listening"
            }
            return DictationHUD.tail(of: controller.partial)
        }
    }

    private var lineIsPlaceholder: Bool {
        if case .notice = controller.state { return false }
        return controller.partial.isEmpty || controller.isStreaming
    }
}

/// Five Lobster bars that follow the voice. With Reduce Motion they hold still and brighten
/// with the level instead of growing.
private struct DictationLevelMeter: View {
    let level: Float
    /// False once the key is released and the last words are being read out.
    let live: Bool
    let reduceMotion: Bool

    /// The middle bar moves most, so the meter reads as one shape rather than five.
    private static let weights: [CGFloat] = [0.5, 0.8, 1, 0.75, 0.45]
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(PopoverPalette.brand)
                    .frame(width: 3, height: height(for: Self.weights[index]))
                    .opacity(opacity)
            }
        }
        .frame(height: Self.maxHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: level)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: live)
        .accessibilityHidden(true)
    }

    private func height(for weight: CGFloat) -> CGFloat {
        guard live, !reduceMotion else { return reduceMotion ? 8 : Self.minHeight }
        let value = min(max(CGFloat(level), 0), 1)
        return Self.minHeight + (Self.maxHeight - Self.minHeight) * value * weight
    }

    private var opacity: Double {
        guard live else { return 0.45 }
        return reduceMotion ? 0.35 + 0.65 * Double(min(max(level, 0), 1)) : 1
    }
}
