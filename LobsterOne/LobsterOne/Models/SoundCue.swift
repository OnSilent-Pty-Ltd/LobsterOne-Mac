import Foundation

/// A moment in a Claude Code session that can play a sound, and the hook that marks it.
enum SoundCue: String, CaseIterable, Codable, Identifiable {
    case sessionStart, needsPermission, waiting, finished, planApproved

    var id: Self { self }

    var title: String {
        switch self {
        case .sessionStart: "Session starts"
        case .needsPermission: "Claude needs your permission"
        case .waiting: "Claude is waiting for you"
        case .finished: "Claude finished"
        case .planApproved: "Plan approved"
        }
    }

    /// The row title in the Sounds tab, where the tool is already named above.
    var shortTitle: String {
        switch self {
        case .sessionStart: "Session starts"
        case .needsPermission: "Needs your permission"
        case .waiting: "Waiting for you"
        case .finished: "Finished"
        case .planApproved: "Plan approved"
        }
    }

    var detail: String {
        switch self {
        case .sessionStart: "When you open a new Claude Code session."
        case .needsPermission: "When a tool call needs your yes before it runs."
        case .waiting: "When Claude has been idle on your reply for a minute."
        case .finished: "When Claude ends its turn and hands back to you."
        case .planApproved: "When you accept a plan and the work begins."
        }
    }

    /// Claude Code hook event and matcher (nil matches everything).
    var hookEvent: String {
        switch self {
        case .sessionStart: "SessionStart"
        case .needsPermission, .waiting: "Notification"
        case .finished: "Stop"
        case .planApproved: "PostToolUse"
        }
    }

    var hookMatcher: String? {
        switch self {
        case .sessionStart: "startup"
        case .needsPermission: "permission_prompt"
        case .waiting: "idle_prompt"
        case .finished: nil
        case .planApproved: "ExitPlanMode"
        }
    }

    /// What a new user hears for this moment.
    var defaultSound: SoundChoice {
        switch self {
        case .sessionStart: .garry("garry-hello-1")
        case .needsPermission: .garry("garry-knock")
        case .waiting: .garry("garry-nudge-1")
        case .finished: .garry("garry-done-1")
        case .planApproved: .garry("garry-go")
        }
    }

    /// On by default: the moments people most want to hear about.
    var enabledByDefault: Bool { self == .needsPermission || self == .waiting || self == .finished }
}

/// A coding tool the sounds can play in. Each gets its own hooks, written by its own installer.
enum SoundTool: String, CaseIterable, Codable, Identifiable {
    case claude, codex, vibe

    var id: Self { self }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .vibe: "Mistral Vibe"
        }
    }

    /// The moments this tool has a hook for. Codex has no idle event, so its "waiting" is a
    /// timer started when a turn ends; Vibe dropped plan mode in 3.0.
    var cues: Set<SoundCue> {
        switch self {
        case .claude, .codex: Set(SoundCue.allCases)
        case .vibe: [.sessionStart, .needsPermission, .waiting, .finished]
        }
    }
}

/// Where a cue's sound comes from.
enum SoundChoice: Codable, Hashable {
    /// A sound bundled with the app (any of the sets below), by file name without
    /// extension. Named for the first set; kept so saved choices still decode.
    case garry(String)
    /// A macOS system sound, by name (Glass, Ping, ...).
    case system(String)
    /// A file the person picked, copied into Application Support under this name.
    case custom(String)

    /// Garry's set, roughly in the order of the moments they suit.
    static let garrySounds: [(id: String, name: String)] = [
        ("garry-hello-1", "Hello 1"), ("garry-hello-2", "Hello 2"), ("garry-hello-3", "Hello 3"), ("garry-hello-4", "Hello 4"),
        ("garry-morning", "Morning"), ("garry-clock-in", "Clock in"),
        ("garry-knock", "Knock"), ("garry-doorbell", "Doorbell"), ("garry-beep-beep", "Beep beep"),
        ("garry-nudge-1", "Nudge 1"), ("garry-nudge-2", "Nudge 2"), ("garry-nudge-3", "Nudge 3"), ("garry-nudge-4", "Nudge 4"),
        ("garry-psst", "Psst"),
        ("garry-done-1", "Done 1"), ("garry-done-2", "Done 2"), ("garry-done-3", "Done 3"), ("garry-done-4", "Done 4"),
        ("garry-ta-da", "Ta-da"), ("garry-shell-drop", "Shell drop"),
        ("garry-go", "Off we go"), ("garry-charge", "Charge"),
    ]

    /// Sounds that became the first of a numbered set; saved choices follow them.
    static let renamed = ["garry-hello": "garry-hello-1", "garry-nudge": "garry-nudge-1", "garry-done": "garry-done-1"]

    /// Unit voice lines from Command & Conquer (Westwood/EA audio, not licensed to LobsterOne;
    /// included at the founder's decision). File names keep the old "classic-" prefix so saved
    /// choices still resolve.
    static let classicSounds: [(id: String, name: String)] = [
        ("classic-hello-1", "Hello 1"), ("classic-hello-2", "Hello 2"), ("classic-hello-3", "Hello 3"),
        ("classic-hello-4", "Hello 4"), ("classic-hello-5", "Hello 5"),
        ("classic-your-turn", "Awaiting orders"),
        ("classic-yes-1", "Commander? 1"), ("classic-yes-2", "Commander? 2"), ("classic-yes-3", "Commander? 3"),
        ("classic-ready-1", "Unit ready 1"), ("classic-ready-2", "Unit ready 2"), ("classic-ready-3", "Unit ready 3"),
        ("classic-done-1", "Mission accomplished 1"), ("classic-done-2", "Mission accomplished 2"),
        ("classic-done-3", "Mission accomplished 3"),
        ("classic-on-it-1", "On it 1"), ("classic-on-it-2", "On it 2"), ("classic-on-it-3", "On it 3"),
        ("classic-on-it-4", "On it 4"), ("classic-on-it-5", "On it 5"), ("classic-on-it-6", "On it 6"),
    ]

    /// Red Alert 1 and 2 unit and EVA lines (Westwood/EA audio, not licensed to LobsterOne;
    /// included at the founder's decision). See scripts/build-soldier-sounds.sh.
    static let redAlertSounds: [(id: String, name: String)] = [
        ("redalert-start-1", "Battle control 1"), ("redalert-start-2", "Battle control 2"),
        ("redalert-start-3", "Battle control 3"), ("redalert-kirov", "Kirov reporting"),
        ("redalert-orders-1", "Orders? 1"), ("redalert-orders-2", "Orders? 2"),
        ("redalert-orders-3", "Orders? 3"), ("redalert-orders-4", "Orders? 4"),
        ("redalert-ready-1", "Standing by 1"), ("redalert-ready-2", "Standing by 2"), ("redalert-ready-3", "Standing by 3"),
        ("redalert-done-1", "Construction complete 1"), ("redalert-done-2", "Construction complete 2"),
        ("redalert-done-3", "Construction complete 3"),
        ("redalert-plan-1", "Moving out 1"), ("redalert-plan-2", "Moving out 2"),
        ("redalert-plan-3", "Moving out 3"), ("redalert-plan-4", "Moving out 4"),
        ("redalert-funds", "Insufficient funds"),
    ]

    /// Mission audio: NASA air-to-ground and launch loops (US public domain), plus synthesised
    /// Quindar tones and master alarm. See scripts/build-mission-sounds.sh.
    static let missionSounds: [(id: String, name: String)] = [
        ("mission-quindar-in", "Quindar: on air"), ("mission-quindar-out", "Quindar: over"),
        ("mission-go-ahead", "Go ahead"), ("mission-houston-go-ahead", "Houston, go ahead"),
        ("mission-how-do-you-read", "How do you read?"), ("mission-problem", "Houston, we've had a problem"),
        ("mission-master-alarm", "Master alarm"),
        ("mission-cdr-go", "CDR is go"), ("mission-roger-roll", "Roger roll"),
        ("mission-throttle-up", "Go at throttle up"), ("mission-t-minus-15", "Fifteen seconds"),
        ("mission-computers", "Computers are in control"), ("mission-liftoff", "Liftoff"),
        ("mission-wheelstop", "Wheelstop"), ("mission-eagle-landed", "The Eagle has landed"),
    ]

    /// Recordings from beyond the desk: spacecraft instruments, Mars, a black-hole merger and
    /// NOAA's unexplained Bloop.
    static let spaceSounds: [(id: String, name: String)] = [
        ("space-sputnik", "Sputnik"), ("space-mars-laser", "Mars laser"), ("space-mars-wind", "Mars wind"),
        ("space-saturn", "Saturn radio"), ("space-juno-shock", "Jupiter bow shock"),
        ("space-ligo-chirp", "Black holes merging"), ("mission-bloop", "The Bloop"),
    ]

    /// Radio, phone and modem sounds: synthesised tones and public-domain or CC recordings.
    static let signalSounds: [(id: String, name: String)] = [
        ("signal-morse-ok", "Morse: OK"), ("signal-morse-sk", "Morse: signing off"),
        ("signal-time-pips", "Time pips"), ("signal-sonar", "Sonar ping"),
        ("signal-teletype", "Teletype"), ("signal-numbers-station", "Numbers station"),
        ("signal-modem", "Modem handshake"), ("mission-dial-up", "Dialing"),
        ("mission-sit", "Number not in service"),
    ]

    /// Office and front-desk sounds: CC0 recordings and a synthesised register.
    static let deskSounds: [(id: String, name: String)] = [
        ("desk-typewriter-bell", "Typewriter bell"), ("desk-service-bell", "Service bell"),
        ("desk-boxing-bell", "Boxing bell"), ("desk-whistle", "Referee whistle"), ("desk-ka-ching", "Ka-ching"),
    ]

    /// Every file name the app bundles, so imported custom sounds never collide with them.
    static let bundledPrefixes = ["garry-", "classic-", "redalert-", "mission-", "space-", "signal-", "desk-"]

    /// Each bundled set, with the label it shows under in the picker.
    static let bundledSets: [(title: String, sounds: [(id: String, name: String)])] = [
        ("Garry", garrySounds), ("Soldier", classicSounds), ("Red Alert", redAlertSounds),
        ("Mission control", missionSounds), ("Deep space", spaceSounds),
        ("Signals", signalSounds), ("Desk", deskSounds),
    ]

    /// A name without its trailing version number ("hello-2" and "Hello 2" give "hello" and
    /// "Hello"), or nil when it doesn't end in one.
    static func familyStem(_ name: String) -> String? {
        guard let number = name.range(of: #"[-_ ]?\d+$"#, options: .regularExpression),
              number.lowerBound > name.startIndex else { return nil }
        return String(name[..<number.lowerBound])
    }

    /// The numbered versions of a sound (hello-1, hello-2, ...), itself included, in order.
    /// Just the sound itself when it has no siblings. `custom` is what the person has imported.
    static func variants(of choice: SoundChoice, custom: [SoundChoice]) -> [SoundChoice] {
        let pool: [SoundChoice]
        switch choice {
        case .garry: pool = bundledSets.flatMap(\.sounds).map { .garry($0.id) }
        case .custom: pool = custom
        case .system: return [choice]
        }
        guard let stem = choice.stem.flatMap(familyStem) else { return [choice] }
        let family = pool.filter { $0.stem.flatMap(familyStem) == stem }
            .sorted { ($0.stem ?? "").localizedStandardCompare($1.stem ?? "") == .orderedAscending }
        return family.count > 1 && family.contains(choice) ? family : [choice]
    }

    /// File name without extension, for sounds that are files of ours.
    private var stem: String? {
        switch self {
        case .garry(let id): id
        case .custom(let file): (file as NSString).deletingPathExtension
        case .system: nil
        }
    }

    /// What a set of numbered versions is called: the label without its number.
    var familyLabel: String { Self.familyStem(label) ?? label }

    var label: String {
        switch self {
        case .garry(let id):
            Self.bundledSets.lazy.compactMap { set in
                set.sounds.first { $0.id == id }.map { set.title == "Garry" ? "Garry: \($0.name)" : $0.name }
            }.first ?? id
        case .system(let name): name
        case .custom(let file): (file as NSString).deletingPathExtension
        }
    }
}

/// A themed set: one sound for each moment, applied together.
struct SoundPack: Identifiable {
    let id: String
    let name: String
    let detail: String
    /// Bundled sound ids, in the order of `SoundCue.allCases`: session start, needs
    /// permission, waiting, finished, plan approved.
    let ids: [String]

    func sound(for cue: SoundCue) -> SoundChoice {
        .garry(ids[SoundCue.allCases.firstIndex(of: cue) ?? 0])
    }

    static let all: [SoundPack] = [
        SoundPack(id: "garry", name: "Garry", detail: "All chiptune, no voices.",
                  ids: ["garry-hello-1", "garry-knock", "garry-nudge-1", "garry-done-1", "garry-go"]),
        SoundPack(id: "soldier", name: "Soldier", detail: "Unit voices from Command & Conquer.",
                  ids: ["classic-hello-1", "classic-your-turn", "classic-ready-1", "classic-done-1", "classic-on-it-1"]),
        SoundPack(id: "redalert", name: "Red Alert", detail: "EVA and unit voices from Red Alert 1 and 2.",
                  ids: ["redalert-start-1", "redalert-orders-1", "redalert-ready-1", "redalert-done-1", "redalert-plan-1"]),
        SoundPack(id: "mission", name: "Mission control", detail: "Shuttle launch loops, liftoff to wheelstop.",
                  ids: ["mission-liftoff", "mission-how-do-you-read", "mission-go-ahead", "mission-wheelstop", "mission-throttle-up"]),
        SoundPack(id: "apollo", name: "Apollo", detail: "Quindar beeps, a problem, and the Eagle landing.",
                  ids: ["mission-quindar-in", "mission-problem", "mission-master-alarm", "mission-eagle-landed", "mission-cdr-go"]),
        SoundPack(id: "space", name: "Deep space", detail: "Sputnik, Mars, Saturn and two black holes.",
                  ids: ["space-sputnik", "space-mars-laser", "space-saturn", "space-ligo-chirp", "space-juno-shock"]),
        SoundPack(id: "signals", name: "Signals", detail: "Modem, sonar, time pips and Morse.",
                  ids: ["signal-modem", "signal-sonar", "signal-time-pips", "signal-morse-sk", "signal-teletype"]),
        SoundPack(id: "desk", name: "Front desk", detail: "Bells, a whistle and a cash register.",
                  ids: ["desk-typewriter-bell", "desk-service-bell", "desk-whistle", "desk-ka-ching", "desk-boxing-bell"]),
    ]
}

/// A daily stretch when no sound plays. Minutes since midnight; an end before the start
/// runs past midnight (22:00 to 08:00).
struct QuietTime: Codable, Equatable, Identifiable {
    var id = UUID()
    var start = 22 * 60
    var end = 8 * 60

    func contains(minute: Int) -> Bool {
        start <= end ? (start..<end).contains(minute) : minute >= start || minute < end
    }

    /// A shell test that's true during this stretch, given `$t` as the time in HHMM.
    var shellTest: String {
        func hhmm(_ m: Int) -> String { String(format: "%02d%02d", (m / 60) % 24, m % 60) }
        return "{ [ \"$t\" -ge \(hhmm(start)) ] \(start <= end ? "&&" : "||") [ \"$t\" -lt \(hhmm(end)) ]; }"
    }
}

/// Everything the Sounds tab saves. Stored as one JSON blob in UserDefaults.
struct SoundCueSettings: Codable, Equatable {
    var enabled = false
    var volume: Double = 0.6
    var cues: [SoundCue: Entry] = Dictionary(uniqueKeysWithValues: SoundCue.allCases.map {
        ($0, Entry(on: $0.enabledByDefault, sound: $0.defaultSound))
    })

    /// Times of day when the hooks stay silent.
    var quietTimes: [QuietTime] = []

    /// The tools the sounds play in. Claude Code alone until the person adds another.
    var tools: Set<SoundTool> = [.claude]

    /// Whether sounds are on and set to play in this tool.
    func plays(in tool: SoundTool) -> Bool { enabled && tools.contains(tool) }

    struct Entry: Codable, Equatable {
        var on: Bool
        var sound: SoundChoice
        /// When the sound has numbered versions, play a different one each time.
        var random = true
        /// This moment's own level, as a share of the main volume.
        var level: Double = 1
    }

    /// What `afplay` gets for a moment: the main volume scaled by the moment's level.
    func volume(for cue: SoundCue) -> Double { volume * entry(cue).level }

    func entry(_ cue: SoundCue) -> Entry {
        cues[cue] ?? Entry(on: cue.enabledByDefault, sound: cue.defaultSound)
    }

    /// Switches every moment to the pack's sound. Which moments are on, and how loud each
    /// is, stay as they were.
    mutating func apply(_ pack: SoundPack) {
        for cue in SoundCue.allCases {
            var entry = entry(cue)
            entry.sound = pack.sound(for: cue)
            entry.random = true
            cues[cue] = entry
        }
    }

    /// The pack every moment currently matches, if any. A numbered sound matches any of its
    /// versions while random is on.
    var pack: SoundPack? {
        SoundPack.all.first { pack in
            SoundCue.allCases.allSatisfy { cue in
                let entry = entry(cue), wanted = pack.sound(for: cue)
                if entry.sound == wanted { return true }
                return entry.random && SoundChoice.variants(of: wanted, custom: []).contains(entry.sound)
            }
        }
    }

    static let defaultsKey = "soundCueSettings"

    static func load(_ defaults: UserDefaults = .standard) -> SoundCueSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(SoundCueSettings.self, from: data) else { return SoundCueSettings() }
        for (cue, entry) in settings.cues {
            if case .garry(let id) = entry.sound, let now = SoundChoice.renamed[id] { settings.cues[cue]?.sound = .garry(now) }
        }
        return settings
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

extension SoundCueSettings {
    // Settings saved before quiet times or tools existed have no such keys.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        volume = try values.decode(Double.self, forKey: .volume)
        cues = try values.decode([SoundCue: Entry].self, forKey: .cues)
        quietTimes = try values.decodeIfPresent([QuietTime].self, forKey: .quietTimes) ?? []
        tools = try values.decodeIfPresent(Set<SoundTool>.self, forKey: .tools) ?? [.claude]
    }
}

extension SoundCueSettings.Entry {
    // Settings saved before `random` and `level` existed lack those keys; they get the defaults.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        on = try values.decode(Bool.self, forKey: .on)
        sound = try values.decode(SoundChoice.self, forKey: .sound)
        random = try values.decodeIfPresent(Bool.self, forKey: .random) ?? true
        level = try values.decodeIfPresent(Double.self, forKey: .level) ?? 1
    }
}
