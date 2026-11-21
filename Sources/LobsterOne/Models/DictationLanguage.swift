import Foundation
#if compiler(>=6.2)
import Speech
#endif

/// Which language dictation listens for. Apple's model transcribes one language at a time and
/// doesn't detect it, so a French speaker on an English Mac has to say so here.
nonisolated enum DictationLanguage {
    struct Option: Equatable, Identifiable {
        /// BCP-47, as the speech framework spells it, e.g. "fr-FR".
        let identifier: String
        let name: String
        var id: String { identifier }
    }

    static let selectedKey = "dictationLanguage"

    /// The chosen language's identifier; nil follows the system language.
    static var selectedIdentifier: String? {
        get { UserDefaults.standard.string(forKey: selectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectedKey) }
    }

    /// The language to ask the model for: the chosen one, else the system's.
    static var preferredLocale: Locale {
        selectedIdentifier.map { Locale(identifier: $0) } ?? .current
    }

    /// "French (France)", in the person's own language.
    static func name(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Every language the on-device model can transcribe, by name. Empty before macOS 26.
    static func supported() async -> [Option] {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let locales = await SpeechTranscriber.supportedLocales
            return locales
                .map { Option(identifier: $0.identifier(.bcp47), name: name(for: $0.identifier)) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        #endif
        return []
    }
}
