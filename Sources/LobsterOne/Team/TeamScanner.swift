import Foundation

/// An agent the user has defined in `~/.claude/agents`, with what it did this week.
nonisolated struct TeamMember: Identifiable, Equatable, Sendable {
    /// The agent's `name`, which is also the `agentType` Claude Code records for its runs.
    let name: String
    var id: String { name }
    let description: String?
    let model: String?
    /// `user`, `project` or `local`, as written in the charter; nil when memory is off.
    let memoryScope: String?
    let charterURL: URL
    let charterModified: Date?
    /// Set on charters the app wrote: who the member is in the interface.
    var persona: Persona?
    /// Set only for `memory: user`, the one scope with a single folder to read.
    var notebook: Notebook?
    var usage = AgentUsage()

    struct Persona: Equatable, Sendable {
        let name: String
        /// Portrait in Resources/Crew.
        let face: String?
        /// "Release reviewer".
        let title: String?
    }

    /// The person's name when the app hired them, else the agent name read as words.
    var displayName: String { persona?.name ?? TeamScanner.title(name) }

    struct Notebook: Equatable, Sendable {
        let url: URL
        let lines: Int
        let bytes: Int
        let modified: Date?

        /// Claude Code loads the first 200 lines or 25 KB of MEMORY.md, whichever comes first.
        static let lineLimit = 200
        static let byteLimit = 25_000

        var isNearlyFull: Bool {
            Double(lines) >= Double(Self.lineLimit) * 0.9 || Double(bytes) >= Double(Self.byteLimit) * 0.9
        }
    }
}

/// What one agent type cost over the window: input plus output tokens, as the session scanner counts them.
nonisolated struct AgentUsage: Equatable, Sendable {
    var runs = 0
    var tokens = 0
    var lastRun: Date?
    /// The project its latest run was in.
    var lastProject: String?
    var lastModel: String?
}

nonisolated struct TeamSnapshot: Equatable, Sendable {
    let scannedAt: Date
    /// Busiest first.
    let members: [TeamMember]

    var crewTokens: Int { members.reduce(0) { $0 + $1.usage.tokens } }
    var crewRuns: Int { members.reduce(0) { $0 + $1.usage.runs } }
}

/// Reads the crew from Claude Code's own files. Reads only; nothing here is uploaded.
///
/// - Charters: `agents/*.md`, for the name, description, model and memory scope.
/// - Notebooks: `agent-memory/<name>/MEMORY.md`.
/// - Runs: `projects/<project>/<session>/subagents/agent-*.meta.json`, which names the agent,
///   beside the transcript whose tokens are summed.
///
/// Separate from `ClaudeSessionScanner`, which uploads sessions and is left alone.
nonisolated enum TeamScanner {
    static let window: TimeInterval = 7 * 24 * 3600

    static var defaultClaudeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// Token counts per transcript, kept between scans so an unchanged file is not read again.
    final class Cache: @unchecked Sendable {
        struct Entry {
            let modified: Date
            let size: Int
            /// The earliest usage line in the file. The count holds while this is inside the window.
            let oldest: Date?
            let tokens: Int
            let model: String?
        }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func entry(for path: String) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            return entries[path]
        }

        /// The transcripts read so far.
        var paths: [String] {
            lock.lock(); defer { lock.unlock() }
            return entries.keys.sorted()
        }

        func store(_ entry: Entry, for path: String) {
            lock.lock(); defer { lock.unlock() }
            entries[path] = entry
        }
    }

    static func scan(claudeDirectory: URL = defaultClaudeDirectory, now: Date = Date(), cache: Cache? = nil,
                     progress: Progress? = nil) -> TeamSnapshot {
        // Only the crew's own runs are read. Other agents' transcripts are skipped by their meta file,
        // which is what keeps this quick on a Mac with a busy week.
        let crew = crew(claudeDirectory: claudeDirectory)
        let usage = usageByAgent(projects: claudeDirectory.appendingPathComponent("projects"), now: now,
                                 only: Set(crew.map(\.name)), cache: cache, progress: progress)
        let members = crew.map { charter -> TeamMember in
            var member = charter
            member.usage = usage[charter.name] ?? AgentUsage()
            return member
        }
        return TeamSnapshot(scannedAt: now, members: members.sorted(by: busier))
    }

    /// The crew with their notebooks but without this week's usage: cheap enough to read on every file change.
    static func crew(claudeDirectory: URL = defaultClaudeDirectory) -> [TeamMember] {
        charters(in: claudeDirectory.appendingPathComponent("agents")).map { charter in
            var member = charter
            if member.memoryScope == "user" {
                member.notebook = notebook(at: claudeDirectory.appendingPathComponent("agent-memory/\(member.name)/MEMORY.md"))
            }
            return member
        }
    }

    private static func busier(_ a: TeamMember, _ b: TeamMember) -> Bool {
        a.usage.tokens != b.usage.tokens ? a.usage.tokens > b.usage.tokens : a.name < b.name
    }


    // MARK: - Charters

    static func charters(in directory: URL) -> [TeamMember] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        var seen = Set<String>()
        return files.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
            let fields = frontmatter(text)
            guard let name = fields["name"], !name.isEmpty, seen.insert(name).inserted else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            var member = TeamMember(name: name, description: fields["description"], model: fields["model"],
                                    memoryScope: fields["memory"], charterURL: url, charterModified: modified, notebook: nil)
            if fields[CrewInstaller.markerField] != nil {
                member.persona = .init(name: fields[CrewInstaller.nameField] ?? title(name),
                                       face: fields[CrewInstaller.faceField], title: fields[CrewInstaller.titleField])
            }
            return member
        }
    }

    /// The top-level `key: value` pairs between the opening and closing `---`. Nested values
    /// (hooks, lists) are skipped; the fields read here are all single-line scalars.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return fields }
            guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
                if quote == "\"" {
                    value = value.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                }
            }
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        return [:] // no closing line: not frontmatter
    }

    /// "security-reviewer" reads as "Security reviewer".
    static func title(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func notebook(at url: URL) -> TeamMember.Notebook? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let newlines = data.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        let lines = data.isEmpty ? 0 : newlines + (data.last == UInt8(ascii: "\n") ? 0 : 1)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return TeamMember.Notebook(url: url, lines: lines, bytes: data.count, modified: modified)
    }

    // MARK: - Runs

    /// Called as a scan goes, with how much of the week's transcripts has been read, from 0 to 1.
    typealias Progress = @Sendable (Double) -> Void

    /// This week's runs and tokens per agent. With `only`, runs by any other agent are skipped unread.
    static func usageByAgent(projects: URL, now: Date, only: Set<String>? = nil, cache: Cache? = nil,
                             progress: Progress? = nil) -> [String: AgentUsage] {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-window)
        if let only, only.isEmpty { return [:] }
        guard let projectDirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else { return [:] }
        // First find this week's runs, which is quick; then read them, which is not, and can report how far it has got.
        struct Run {
            let agent: (type: String, model: String?), transcript: URL, modified: Date, size: Int, folder: String
        }
        var runs: [Run] = []
        for projectDir in projectDirs {
            guard let sessionDirs = try? fm.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil,
                                                                options: [.skipsHiddenFiles]) else { continue }
            for sessionDir in sessionDirs {
                let subagents = sessionDir.appendingPathComponent("subagents")
                guard let walker = fm.enumerator(at: subagents, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                 options: [.skipsHiddenFiles]) else { continue }
                for case let meta as URL in walker where meta.lastPathComponent.hasSuffix(".meta.json") {
                    let transcript = meta.deletingLastPathComponent()
                        .appendingPathComponent(String(meta.lastPathComponent.dropLast(".meta.json".count)) + ".jsonl")
                    guard let values = try? transcript.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                          let modified = values.contentModificationDate, modified >= cutoff,
                          let agent = agentType(meta: meta), only?.contains(agent.type) ?? true else { continue }
                    runs.append(Run(agent: agent, transcript: transcript, modified: modified, size: values.fileSize ?? 0,
                                    folder: projectDir.lastPathComponent))
                }
            }
        }

        // Progress goes by bytes, since one long run can outweigh a hundred short ones.
        let totalBytes = max(1, runs.reduce(0) { $0 + $1.size })
        var readBytes = 0
        var lastReported = 0.0
        progress?(0)
        var result: [String: AgentUsage] = [:]
        for run in runs {
            defer {
                readBytes += run.size
                let fraction = Double(readBytes) / Double(totalBytes)
                if fraction - lastReported >= 0.02 || fraction >= 1 {
                    lastReported = fraction
                    progress?(min(1, fraction))
                }
            }
            let agent = run.agent
            let counted = tokens(in: run.transcript, modified: run.modified, size: run.size, cutoff: cutoff, cache: cache)
            guard counted.tokens > 0 else { continue }
            var usage = result[agent.type] ?? AgentUsage()
            usage.runs += 1
            usage.tokens += counted.tokens
            if usage.lastRun.map({ run.modified > $0 }) ?? true {
                usage.lastRun = run.modified
                usage.lastProject = projectName(transcript: run.transcript, folder: run.folder)
                usage.lastModel = counted.model ?? agent.model
            }
            result[agent.type] = usage
        }
        if runs.isEmpty { progress?(1) }
        return result
    }

    private static func agentType(meta: URL) -> (type: String, model: String?)? {
        guard let data = try? Data(contentsOf: meta),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["agentType"] as? String, !type.isEmpty else { return nil }
        return (type, object["model"] as? String)
    }

    /// Input plus output tokens on lines stamped inside the window, and the last model seen.
    private static func tokens(in transcript: URL, modified: Date, size: Int, cutoff: Date, cache: Cache?) -> (tokens: Int, model: String?) {
        // An unchanged file keeps its count for as long as every line in it is still inside the window.
        if let hit = cache?.entry(for: transcript.path), hit.modified == modified, hit.size == size,
           hit.oldest.map({ $0 >= cutoff }) ?? true {
            return (hit.tokens, hit.model)
        }
        guard let data = try? Data(contentsOf: transcript, options: .mappedIfSafe) else { return (0, nil) }
        var total = 0
        var oldest: Date?
        var model: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Most lines are tool output with no usage; skip them without decoding the JSON.
            guard line.range(of: usageMarker) != nil else { continue }
            var usage: (tokens: Int, model: String?)?
            var stamp: Date?
            for event in ClaudeJSONLParser.parseLine(Data(line)) {
                switch event.kind {
                case .assistantUsage(let lineModel, let input, let output, _, _):
                    usage = (input + output, lineModel)
                case .metadata(_, _, let timestamp, _, _):
                    stamp = timestamp.flatMap(parseTimestamp)
                default:
                    break
                }
            }
            guard let usage else { continue }
            if let stamp, oldest.map({ stamp < $0 }) ?? true { oldest = stamp }
            guard stamp.map({ $0 >= cutoff }) ?? true else { continue }
            total += usage.tokens
            if let lineModel = usage.model { model = lineModel }
        }
        cache?.store(.init(modified: modified, size: size, oldest: oldest, tokens: total, model: model), for: transcript.path)
        return (total, model)
    }

    private static let usageMarker = Data("\"usage\"".utf8)

    private static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The folder the run worked in, read from the transcript's first line; falls back to the
    /// encoded project folder name.
    private static func projectName(transcript: URL, folder: String) -> String {
        if let handle = try? FileHandle(forReadingFrom: transcript) {
            defer { try? handle.close() }
            let head = handle.readData(ofLength: 65_536)
            if let line = head.split(separator: UInt8(ascii: "\n")).first,
               let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let cwd = object["cwd"] as? String, !cwd.isEmpty {
                return projectName(cwd: cwd)
            }
        }
        return folder.split(separator: "-").last.map(String.init) ?? folder
    }

    /// The repository folder, not a worktree inside it: `…/Robocog---Mac/.claude/worktrees/x` reads as `Robocog---Mac`.
    static func projectName(cwd: String) -> String {
        var path = cwd
        if let range = path.range(of: "/.claude/worktrees/") ?? path.range(of: "/.worktrees/") {
            path = String(path[..<range.lowerBound])
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}
