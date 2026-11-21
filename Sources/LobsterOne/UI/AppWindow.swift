import AppKit

/// The size every full window of the app opens at: Preferences, the crew's hiring window, the
/// calendar, the digest and the change viewer. One size, so the app feels like one place.
/// The setup guide is a short wizard and keeps its own smaller size, `SetupWizard.size`.
enum AppWindow {
    static let size = CGSize(width: 870, height: 790)

    /// The standard size, shorter only when the screen is; the pages scroll then.
    @MainActor
    static var fitted: CGSize {
        let room = (NSScreen.main?.visibleFrame.height ?? size.height + 80) - 80
        return CGSize(width: size.width, height: min(size.height, max(480, room)))
    }
}
