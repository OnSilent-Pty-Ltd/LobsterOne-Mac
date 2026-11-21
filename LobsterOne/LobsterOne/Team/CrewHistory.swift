import CryptoKit
import Foundation

/// Dated copies of each crew member's charter and notebook, kept in the app's support folder
/// so a change can be seen and undone. Plain files; nothing here is uploaded.
nonisolated struct CrewHistory: Sendable {
    enum Kind: String, Sendable, CaseIterable {
        case charter, notebook
    }

    struct Version: Equatable, Sendable {
        /// The file name without its extension: a UTC timestamp, so versions sort by name.
        let id: String
        let date: Date
        let url: URL
    }

    /// Versions kept per file; older ones are deleted.
    static let keep = 50

    /// `…/LobsterOne/Crew/History`
    let directory: URL

    init(supportDirectory: URL) {
        directory = supportDirectory.appendingPathComponent("History")
    }

    private func folder(_ agent: String, _ kind: Kind) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !agent.isEmpty, let safe = agent.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return directory.appendingPathComponent(safe).appendingPathComponent(kind.rawValue)
    }

    /// Oldest first.
    func versions(_ agent: String, _ kind: Kind) -> [Version] {
        guard let folder = folder(agent, kind),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "md" }.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            // The timestamp is the first 20 characters; a suffix only breaks a tie.
            return Self.stamp.date(from: String(id.prefix(20))).map { Version(id: id, date: $0, url: url) }
        }.sorted { $0.id < $1.id }
    }

    func text(_ version: Version) -> String {
        (try? String(contentsOf: version.url, encoding: .utf8)) ?? ""
    }

    /// Saves `content` as a new version unless it matches the latest one. True when a version was added.
    @discardableResult
    func record(_ agent: String, _ kind: Kind, content: Data, at date: Date) -> Bool {
        guard let folder = folder(agent, kind) else { return false }
        let existing = versions(agent, kind)
        if let latest = existing.last, (try? Data(contentsOf: latest.url)) == content { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var id = Self.stamp.string(from: date)
            // Two saves in the same millisecond, or a clock set back: stay after the latest.
            if let latest = existing.last, id <= latest.id { id = latest.id + "a" }
            try content.write(to: folder.appendingPathComponent(id + ".md"), options: .atomic)
        } catch {
            return false
        }
        for old in existing.dropLast(max(0, Self.keep - 1)) { try? fm.removeItem(at: old.url) }
        return true
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        formatter.isLenient = false
        return formatter
    }()

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Lines added and removed between two versions of a file.
nonisolated enum LineDiff {
    struct Line: Equatable, Sendable {
        enum Kind: Sendable { case same, added, removed, gap }
        let kind: Kind
        let text: String
    }

    static func lines(old: String, new: String) -> [Line] {
        let before = split(old), after = split(new)
        let difference = after.difference(from: before)
        var removed = Set<Int>(), added = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                result.append(Line(kind: .removed, text: before[i])); i += 1
            } else if j < after.count, added.contains(j) {
                result.append(Line(kind: .added, text: after[j])); j += 1
            } else if i < before.count, j < after.count {
                result.append(Line(kind: .same, text: after[j])); i += 1; j += 1
            } else {
                break
            }
        }
        return result
    }

    /// The changed lines with `context` unchanged lines around each run; the rest folds into gaps.
    static func collapsed(_ lines: [Line], context: Int = 2) -> [Line] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed {
            for near in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(near) }
        }
        var result: [Line] = []
        var last: Int?
        for index in lines.indices where keep.contains(index) {
            if let last, index > last + 1 { result.append(Line(kind: .gap, text: "")) }
            if last == nil, index > 0 { result.append(Line(kind: .gap, text: "")) }
            result.append(lines[index])
            last = index
        }
        if let last, last < lines.count - 1 { result.append(Line(kind: .gap, text: "")) }
        return result
    }

    static func counts(_ lines: [Line]) -> (added: Int, removed: Int) {
        (lines.filter { $0.kind == .added }.count, lines.filter { $0.kind == .removed }.count)
    }

    private static func split(_ text: String) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

/// Something about a crew member that needs the person's eye.
nonisolated struct CrewAttention: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        /// The rule that keeps a hired member to its notebook is no longer in its charter.
        case guardMissing
        /// A hired member's charter differs from the one the app wrote or the person accepted.
        case charterEdited
        /// A reviewer has findings the owner has not marked kept or dismissed.
        case findings
        /// The latest digest has decisions waiting.
        case decisions
        case notebookFull
    }

    let kind: Kind
    /// The agent's working name.
    let member: String
    let displayName: String
    let face: String?
    /// Changes when the cause does, so a second edit is announced again.
    let id: String
    /// How many findings or decisions are waiting.
    var count = 0
    /// The first finding or decision, for the notification.
    var detail = ""

    /// Most serious first.
    var rank: Int {
        switch kind {
        case .guardMissing: 0
        case .charterEdited: 1
        case .findings: 2
        case .decisions: 3
        case .notebookFull: 4
        }
    }

    var title: String {
        switch kind {
        case .guardMissing: "\(displayName)'s guard is gone"
        case .charterEdited: "\(displayName)'s charter was edited"
        case .findings: "\(displayName) has \(count == 1 ? "1 finding" : "\(count) findings") for you"
        case .decisions: "\(displayName) has \(count == 1 ? "1 decision" : "\(count) decisions") for you"
        case .notebookFull: "\(displayName)'s notebook is nearly full"
        }
    }

    var body: String {
        switch kind {
        case .guardMissing: "The rule that kept \(displayName) to the notebook is no longer in the charter. Nothing stops writes elsewhere."
        case .charterEdited: "It was changed outside LobsterOne. Have a look, then keep the edit or put the old charter back."
        case .findings, .decisions: detail
        case .notebookFull: "Claude Code reads only the first \(TeamMember.Notebook.lineLimit) lines. Trim it so nothing is forgotten."
        }
    }
}

/// What the keeper knows about one member beyond the files themselves.
nonisolated struct CrewNote: Equatable, Sendable {
    var displayName = ""
    var face: String?
    /// Notebook lines gained or lost over the past week; nil when there is nothing to compare.
    var notebookGrowth: Int?
    /// True when the charter or notebook has a version the person has not looked at.
    var hasUnseenChanges = false
    /// True when there is more than one version to compare.
    var hasHistory = false
    /// The member's findings log, oldest first.
    var findings: [CrewFinding] = []

    var openFindings: [CrewFinding] { findings.filter { $0.status == .open } }
    /// Findings the owner has ruled on, and how many of those were kept.
    var decidedFindings: (kept: Int, total: Int) {
        (findings.filter { $0.status == .kept }.count, findings.filter { $0.status != .open }.count)
    }
}

nonisolated struct CrewReport: Equatable, Sendable {
    /// Most serious first.
    var attention: [CrewAttention] = []
    var notes: [String: CrewNote] = [:]
}

/// Keeps the crew consistent: saves a copy of each charter and notebook when it changes, and
/// says when a hired member's charter no longer matches the one the app wrote.
nonisolated struct CrewKeeper: Sendable {
    let installer: CrewInstaller
    let history: CrewHistory

    init(installer: CrewInstaller = CrewInstaller()) {
        self.installer = installer
        self.history = CrewHistory(supportDirectory: installer.supportDirectory)
    }

    // MARK: - State

    /// Which version of each file the person last looked at, and which alerts they have been told about.
    struct State: Codable, Equatable {
        /// "agent/kind" to version id.
        var seen: [String: String] = [:]
        /// Attention ids already sent as a notification.
        var announced: Set<String> = []
        /// Attention ids whose menu bar dot has been cleared.
        var noticed: Set<String> = []
    }

    private var stateURL: URL { history.directory.appendingPathComponent("state.json") }

    func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    func saveState(_ state: State) {
        try? FileManager.default.createDirectory(at: history.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL, options: .atomic) }
    }

    // MARK: - Check

    /// Records any changed charter or notebook, then reports what needs attention.
    func check(_ members: [TeamMember], now: Date = Date()) -> CrewReport {
        // A guard fixed in a newer version of the app must reach the crew hired by an older one.
        installer.refreshGuard()
        var report = CrewReport()
        let state = loadState()
        for member in members {
            let charter = try? Data(contentsOf: member.charterURL)
            if let charter { history.record(member.name, .charter, content: charter, at: now) }
            if let notebook = member.notebook, let data = try? Data(contentsOf: notebook.url) {
                history.record(member.name, .notebook, content: data, at: now)
            }

            var note = CrewNote(displayName: member.displayName, face: member.persona?.face)
            let charters = history.versions(member.name, .charter)
            let notebooks = history.versions(member.name, .notebook)
            note.hasHistory = charters.count > 1 || notebooks.count > 1
            note.hasUnseenChanges = isUnseen(charters, key: Self.key(member.name, .charter), state)
                || isUnseen(notebooks, key: Self.key(member.name, .notebook), state)
            if let notebook = member.notebook, let baseline = Self.weekBaseline(notebooks, now: now) {
                let growth = notebook.lines - Self.lineCount(history.text(baseline))
                if growth != 0 { note.notebookGrowth = growth }
            }
            note.findings = CrewFindings.read(for: member)
            report.notes[member.name] = note

            if member.persona != nil, let charter {
                let text = String(data: charter, encoding: .utf8) ?? ""
                let hash = CrewHistory.hash(charter)
                if !CrewInstaller.hasGuard(text, agent: member.name) {
                    report.attention.append(attention(.guardMissing, member, detail: hash))
                } else if let written = installer.writtenHash(agentNamed: member.name) {
                    if written != hash { report.attention.append(attention(.charterEdited, member, detail: hash)) }
                } else {
                    // Hired before the app kept a copy: the charter as found becomes the one of record.
                    try? installer.acceptCharter(agentNamed: member.name)
                }
            }
            if let first = note.openFindings.first {
                var item = attention(.findings, member, detail: CrewHistory.hash(Data(note.openFindings.map(\.id).joined(separator: "\n").utf8)))
                item.count = note.openFindings.count
                item.detail = first.summary
                report.attention.append(item)
            }
            if member.notebook?.isNearlyFull == true {
                report.attention.append(attention(.notebookFull, member, detail: "full"))
            }
        }
        if let digest = CrewDigestWriter(keeper: self).latest(), let first = digest.openDecisions.first {
            var item = CrewAttention(kind: .decisions, member: CrewDigestWriter.agentName, displayName: CrewDigestWriter.displayName,
                                     face: CrewDigestWriter.face, id: "decisions/\(digest.url.deletingPathExtension().lastPathComponent)")
            item.count = digest.openDecisions.count
            item.detail = first.text
            report.attention.append(item)
        }
        report.attention.sort { ($0.rank, $0.displayName) < ($1.rank, $1.displayName) }
        return report
    }

    private func attention(_ kind: CrewAttention.Kind, _ member: TeamMember, detail: String) -> CrewAttention {
        CrewAttention(kind: kind, member: member.name, displayName: member.displayName, face: member.persona?.face,
                      id: "\(kind.rawValue)/\(member.name)/\(detail.prefix(12))")
    }

    static func key(_ agent: String, _ kind: CrewHistory.Kind) -> String { "\(agent)/\(kind.rawValue)" }

    /// A file with one version has nothing to compare; with more, unseen until the latest is looked at.
    private func isUnseen(_ versions: [CrewHistory.Version], key: String, _ state: State) -> Bool {
        guard versions.count > 1, let latest = versions.last else { return false }
        return state.seen[key] != latest.id
    }

    /// The version to measure the week's growth from: the newest one at least a week old, else the oldest.
    private static func weekBaseline(_ versions: [CrewHistory.Version], now: Date) -> CrewHistory.Version? {
        guard versions.count > 1 else { return nil }
        let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)
        return versions.last { $0.date <= weekAgo } ?? versions.first
    }

    private static func lineCount(_ text: String) -> Int {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last == "" { lines.removeLast() }
        return lines.count
    }

    // MARK: - What changed

    struct Change: Equatable, Sendable {
        let kind: CrewHistory.Kind
        /// When the version being compared against was saved.
        let since: Date
        let lines: [LineDiff.Line]
    }

    /// For each file, the difference between the version last looked at (the first one, if never) and now.
    func changes(for agent: String) -> [Change] {
        let state = loadState()
        return CrewHistory.Kind.allCases.compactMap { kind in
            let versions = history.versions(agent, kind)
            guard versions.count > 1, let latest = versions.last else { return nil }
            let seen = state.seen[Self.key(agent, kind)]
            let baseline = versions.first { $0.id == seen } ?? versions[0]
            guard baseline.id != latest.id else { return nil }
            let lines = LineDiff.lines(old: history.text(baseline), new: history.text(latest))
            return lines.contains { $0.kind != .same } ? Change(kind: kind, since: baseline.date, lines: lines) : nil
        }
    }

    /// For each file, the difference between how it stood at `since` (as first seen, if nil) and now.
    func changes(for agent: String, since: Date?) -> [Change] {
        CrewHistory.Kind.allCases.compactMap { kind in
            let versions = history.versions(agent, kind)
            guard versions.count > 1, let latest = versions.last else { return nil }
            let baseline = since.flatMap { date in versions.last { $0.date <= date } } ?? versions[0]
            guard baseline.id != latest.id else { return nil }
            let lines = LineDiff.lines(old: history.text(baseline), new: history.text(latest))
            return lines.contains { $0.kind != .same } ? Change(kind: kind, since: baseline.date, lines: lines) : nil
        }
    }

    /// The person has looked: the latest versions become the baseline for next time.
    func markSeen(_ agent: String) {
        var state = loadState()
        for kind in CrewHistory.Kind.allCases {
            if let latest = history.versions(agent, kind).last { state.seen[Self.key(agent, kind)] = latest.id }
        }
        saveState(state)
    }

    // MARK: - Alerts

    /// Attention not yet sent as a notification; marks it sent.
    func takeUnannounced(_ attention: [CrewAttention]) -> [CrewAttention] {
        var state = loadState()
        let fresh = attention.filter { !state.announced.contains($0.id) }
        guard !fresh.isEmpty || state.announced.count > attention.count else { return [] }
        // Forget alerts that no longer apply, so the same cause can be announced if it returns.
        state.announced = state.announced.intersection(attention.map(\.id)).union(fresh.map(\.id))
        state.noticed = state.noticed.intersection(attention.map(\.id))
        saveState(state)
        return fresh
    }

    /// Attention whose menu bar dot is still showing.
    func unnoticed(_ attention: [CrewAttention]) -> [CrewAttention] {
        let noticed = loadState().noticed
        return attention.filter { !noticed.contains($0.id) }
    }

    func markNoticed(_ attention: [CrewAttention]) {
        guard !attention.isEmpty else { return }
        var state = loadState()
        state.noticed.formUnion(attention.map(\.id))
        saveState(state)
    }
}
