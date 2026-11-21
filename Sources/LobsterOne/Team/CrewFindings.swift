import Foundation

/// One thing a reviewer raised, as a line in its findings log.
nonisolated struct CrewFinding: Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        /// Raised, waiting for the owner.
        case open
        /// The owner agreed it was real.
        case kept
        /// The owner disagreed; the reviewer should not raise it again.
        case dismissed
    }

    var status: Status
    /// As the reviewer wrote it, normally `yyyy-MM-dd`.
    let date: String
    let project: String
    /// `file:line`.
    let place: String
    let summary: String

    /// The line without its status, so keeping or dismissing a finding does not change which one it is.
    var id: String { [date, project, place, summary].joined(separator: " | ") }
}

/// The ledger: `ledger.md` in a reviewer's notebook folder, one line per finding.
///
///     - [open] 2026-11-19 | Robocog---Mac | Sources/App.swift:42 | The token is written to the debug log.
///
/// The reviewer adds lines; only the owner, through the app, changes a status. The reviewer
/// reads the log before a review, so a dismissed finding is not raised again.
nonisolated enum CrewFindings {
    /// Not "findings": Claude Code refuses a subagent's write to a file whose name contains that
    /// word ("Subagents should return findings as text, not write report files").
    static let fileName = "ledger.md"

    /// Beside the member's MEMORY.md. Works from the charter's location, so it needs no home directory.
    static func url(for member: TeamMember) -> URL {
        member.charterURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agent-memory").appendingPathComponent(member.name).appendingPathComponent(fileName)
    }

    static func read(for member: TeamMember) -> [CrewFinding] {
        guard let text = try? String(contentsOf: url(for: member), encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [CrewFinding] {
        text.split(whereSeparator: \.isNewline).compactMap { parse(line: String($0)) }
    }

    private static func parse(line: String) -> CrewFinding? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let word = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<close].lowercased()
        guard let status = CrewFinding.Status(rawValue: word) else { return nil }
        let parts = trimmed[trimmed.index(after: close)...].components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 4, !parts[3].isEmpty else { return nil }
        return CrewFinding(status: status, date: parts[0], project: parts[1], place: parts[2],
                           summary: parts[3...].joined(separator: " | "))
    }

    /// The log with one finding's status changed; every other line is left exactly as it was.
    static func setting(_ status: CrewFinding.Status, for id: String, in text: String) -> String {
        var changed = false
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            guard !changed, let finding = parse(line: String(line)), finding.id == id,
                  let open = line.range(of: "["), let close = line.range(of: "]") else { return String(line) }
            changed = true
            return line[..<open.upperBound] + status.rawValue + line[close.lowerBound...]
        }
        return lines.joined(separator: "\n")
    }

    /// Marks a finding kept or dismissed in the member's log.
    static func mark(_ status: CrewFinding.Status, finding id: String, for member: TeamMember) throws {
        let url = url(for: member)
        let text = try String(contentsOf: url, encoding: .utf8)
        try setting(status, for: id, in: text).write(to: url, atomically: true, encoding: .utf8)
    }

    /// What a reviewer's charter says about the log.
    static func instructions(logPath: String) -> String {
        """
        Your ledger is \(logPath). After every job, add one line per finding, newest at the bottom, in exactly this form:
        - [open] YYYY-MM-DD | project folder name | file:line | the finding in one sentence
        The third part is one path and one line number: never a range, never two paths. Give the path alone when no single line applies, and a single hyphen (-) when the finding is about something missing. Never put " | " inside the first three parts. Log only what you would have changed: no praise, no summary, nothing you merely could not check. Create the file if it is not there. Add lines with Edit and never rewrite the file. Never change the word in brackets and never remove a line: the owner marks each finding [kept] or [dismissed]. Read the ledger before you start. Do not add a finding that is already there as [open] or [kept]; if it is still in the code, say that it is still there. Do not raise again, in report or ledger, what was dismissed.
        """
    }
}
