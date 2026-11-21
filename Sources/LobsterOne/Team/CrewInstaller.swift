import Foundation

/// Hires and removes crew members by writing Claude Code agent files into `~/.claude/agents`.
/// Only ever replaces or deletes a file it wrote itself (marked by `markerField`); the
/// person's own agents are left exactly as they were.
nonisolated struct CrewInstaller: Sendable {
    /// Frontmatter field on every charter the app writes. Claude Code ignores fields it doesn't know.
    static let markerField = "lobsterone-crew"
    static let nameField = "lobsterone-name"
    static let faceField = "lobsterone-face"
    static let titleField = "lobsterone-title"

    enum Model: String, CaseIterable, Identifiable, Sendable {
        case opus, sonnet, inherit
        var id: Self { self }
        var label: String {
            switch self {
            case .opus: "Opus"
            case .sonnet: "Sonnet"
            case .inherit: "the session's model"
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        case nameTaken(String)
        case notOurs(String)

        var errorDescription: String? {
            switch self {
            case .nameTaken(let id):
                "You already have an agent called \(id) that LobsterOne didn't write, so it was left alone. Rename yours or pick another name."
            case .notOurs(let id):
                "LobsterOne didn't write \(id), so it won't remove it."
            }
        }
    }

    let homeDirectory: URL
    let supportDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, supportDirectory: URL? = nil) {
        self.homeDirectory = homeDirectory
        self.supportDirectory = supportDirectory ?? homeDirectory.appendingPathComponent("Library/Application Support/LobsterOne/Crew")
    }

    var agentsDirectory: URL { homeDirectory.appendingPathComponent(".claude/agents") }
    var guardURL: URL { supportDirectory.appendingPathComponent("guard.sh") }

    func charterURL(for role: CrewRole) -> URL { agentsDirectory.appendingPathComponent("\(role.id).md") }

    /// The charter as the app last wrote it or the person last accepted it: what an edit is measured against.
    func writtenURL(agentNamed id: String) -> URL {
        supportDirectory.appendingPathComponent("Written").appendingPathComponent("\(CrewRole.slug(id)).md")
    }

    // MARK: - Hire

    /// True when hiring `role` would collide with an agent file the app did not write.
    func isNameTaken(_ role: CrewRole) -> Bool {
        let url = charterURL(for: role)
        return FileManager.default.fileExists(atPath: url.path) && !Self.isOurs(url)
    }

    /// Replaces a guard script written by an earlier version of the app. Charters point at the
    /// script by path, so a fix to it reaches the crew already hired. Does nothing before a first hire.
    func refreshGuard() {
        let current = Data(CrewGuard.script.utf8)
        guard let onDisk = try? Data(contentsOf: guardURL), onDisk != current else { return }
        do {
            try current.write(to: guardURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guardURL.path)
        } catch {
            NSLog("LobsterOne crew: could not update the guard script: %@", error.localizedDescription)
        }
    }

    /// Writes the guard script and the charter. Replaces an earlier charter of ours for the
    /// same role; refuses to touch anyone else's file of that name.
    @discardableResult
    func hire(_ role: CrewRole, model: Model) throws -> URL {
        let fm = FileManager.default
        let url = charterURL(for: role)
        if isNameTaken(role) { throw Failure.nameTaken(role.id) }
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Data(CrewGuard.script.utf8).write(to: guardURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: guardURL.path)
        try fm.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
        let data = Data(charter(for: role, model: model).utf8)
        try data.write(to: url, options: .atomic)
        try keepWritten(data, agentNamed: role.id)
        return url
    }

    private func keepWritten(_ charter: Data, agentNamed id: String) throws {
        let written = writtenURL(agentNamed: id)
        try FileManager.default.createDirectory(at: written.deletingLastPathComponent(), withIntermediateDirectories: true)
        try charter.write(to: written, options: .atomic)
    }

    func writtenHash(agentNamed id: String) -> String? {
        (try? Data(contentsOf: writtenURL(agentNamed: id))).map(CrewHistory.hash)
    }

    /// The person has read an outside edit and is keeping it: it becomes the charter of record.
    func acceptCharter(agentNamed id: String) throws {
        let url = agentsDirectory.appendingPathComponent("\(id).md")
        guard Self.isOurs(url) else { throw Failure.notOurs(id) }
        try keepWritten(Data(contentsOf: url), agentNamed: id)
    }

    /// Puts back the charter of record, undoing an outside edit.
    func restoreCharter(agentNamed id: String) throws {
        let url = agentsDirectory.appendingPathComponent("\(id).md")
        guard Self.isOurs(url) else { throw Failure.notOurs(id) }
        try Data(contentsOf: writtenURL(agentNamed: id)).write(to: url, options: .atomic)
    }

    /// True while the charter's frontmatter still runs the guard for this agent before it writes or
    /// runs a command. Text below the frontmatter is instructions and does not count.
    static func hasGuard(_ charter: String, agent id: String) -> Bool {
        let lines = charter.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let hooks = lines[..<close].firstIndex(where: { $0.hasPrefix("hooks:") }) else { return false }
        // The hooks block runs until the next field that starts at the margin.
        let block = lines[(hooks + 1)..<close].prefix { $0.first?.isWhitespace ?? true }
        func indent(_ line: Substring) -> Int { line.prefix { $0.isWhitespace }.count }
        func isComment(_ line: Substring) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        guard let event = block.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "PreToolUse:" }) else { return false }
        // PreToolUse runs until the next line no deeper than it, such as PostToolUse. Comments don't count.
        let body = block[(event + 1)...]
            .filter { !isComment($0) }
            .prefix { $0.trimmingCharacters(in: .whitespaces).isEmpty || indent($0) > indent(block[event]) }
        // One entry per matcher. The guard must sit in an entry whose matcher is exactly the one the
        // app writes, so Edit, MultiEdit or NotebookEdit can't drop out of it unnoticed.
        let entries = body.joined(separator: "\n").components(separatedBy: "- matcher:").dropFirst()
        return entries.contains { entry in
            let lines = entry.split(whereSeparator: \.isNewline)
            let matcher = entry.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
            return [guardMatcher, "\"\(guardMatcher)\"", "'\(guardMatcher)'"].contains(matcher)
                && lines.contains { line in
                    let field = line.trimmingCharacters(in: .whitespaces)
                    return (field.hasPrefix("command:") || field.hasPrefix("- command:")) && field.contains("guard.sh' \(id)\"")
                }
        }
    }

    /// A second entry for a member who may use the web, so the same guard sees those calls too.
    /// It is separate so every other charter keeps the one matcher `hasGuard` looks for.
    private func webGuard(for role: CrewRole, command: String) -> String {
        guard role.usesWeb else { return "" }
        // Indented to sit under PreToolUse, beside the first entry.
        return [
            "",
            "    - matcher: \(Self.yamlQuoted(Self.webMatcher))",
            "      hooks:",
            "        - type: command",
            "          command: \(Self.yamlQuoted(command))",
        ].joined(separator: "\n")
    }

    static let webMatcher = "WebSearch|WebFetch"

    /// Every tool that can change a file or run a command.
    static let guardMatcher = "Write|Edit|MultiEdit|NotebookEdit|Bash"

    /// The whole agent file, exactly as it is written to disk.
    func charter(for role: CrewRole, model: Model) -> String {
        let guardCommand = "\(Self.shellQuoted(guardURL.path)) \(role.id)"
        return """
        ---
        name: \(role.id)
        description: \(Self.yamlQuoted(role.description))
        tools: \(role.tools.joined(separator: ", "))
        model: \(model.rawValue)
        memory: user
        \(Self.markerField): 1
        \(Self.nameField): \(Self.yamlQuoted(role.name))
        \(Self.faceField): \(role.face)
        \(Self.titleField): \(Self.yamlQuoted(role.title))
        hooks:
          PreToolUse:
            - matcher: \(Self.yamlQuoted(Self.guardMatcher))
              hooks:
                - type: command
                  command: \(Self.yamlQuoted(guardCommand))\(webGuard(for: role, command: guardCommand))
        ---
        \(role.instructions)

        \(role.houseRules)\(findingsInstructions(for: role))

        """
    }

    private func findingsInstructions(for role: CrewRole) -> String {
        guard role.logsFindings else { return "" }
        let log = homeDirectory.appendingPathComponent(".claude/agent-memory/\(role.id)/\(CrewFindings.fileName)").path
        return "\n\n" + CrewFindings.instructions(logPath: log)
    }

    // MARK: - Remove

    /// Deletes a charter the app wrote. The member's notebook is left in place.
    func remove(agentNamed id: String) throws {
        let url = agentsDirectory.appendingPathComponent("\(id).md")
        guard Self.isOurs(url) else { throw Failure.notOurs(id) }
        try FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: writtenURL(agentNamed: id))
    }

    static func isOurs(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return false }
        return TeamScanner.frontmatter(text)[markerField] != nil
    }

    // MARK: - Quoting

    /// A YAML double-quoted scalar.
    static func yamlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// One shell word, whatever the path contains.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The script every crew charter runs before a tool call (a Claude Code PreToolUse hook).
nonisolated enum CrewGuard {
    static let script = #"""
    #!/bin/sh
    # LobsterOne crew guard. Runs before a crew member uses a tool (a Claude Code PreToolUse hook).
    # A member may write only inside its own notebook folder, and may run only read-only git
    # commands and ls. Exit 2 refuses the tool call and tells the member why.
    # This guards against mistakes; it is not a sandbox.
    agent="$1"
    notebook="$HOME/.claude/agent-memory/$agent/"
    input=$(cat)
    # Pattern ranges below must mean ASCII only, whatever the person's locale.
    LC_ALL=C
    export LC_ALL
    # Prints a field of the tool call, or nothing when it is missing or the input is not JSON.
    # plutil's exit status decides: on some macOS versions it prints its error to standard output,
    # which must never be mistaken for a value.
    field() {
      value=$(printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null) || return 0
      printf '%s' "$value"
    }
    refuse() { echo "LobsterOne: $1" >&2; exit 2; }

    tool=$(field tool_name)
    case "$tool" in
      Write|Edit|MultiEdit|NotebookEdit)
        path=$(field tool_input.file_path)
        [ -n "$path" ] || path=$(field tool_input.notebook_path)
        case "$path" in
          *..*) refuse "this crew member may write only in its notebook ($notebook)." ;;
          "$notebook"*) exit 0 ;;
          *) refuse "this crew member may write only in its notebook ($notebook). Report the change instead of making it." ;;
        esac ;;
      Bash)
        command=$(field tool_input.command)
        # An allowlist, not a deny-list: only letters, digits, spaces, quotes and . _ / : @ , + = - % ^ ~
        # pass. Everything else is refused even inside quotes, because the shell rewrites words after
        # this check has read them, and zsh runs code from forms a deny-list keeps missing: glob
        # qualifiers ls *(e:'cmd':), process substitution =(cmd), ${(e)...}. So no pipes, redirects,
        # chaining, $, backticks, backslashes, parentheses, braces, brackets, wildcards or line breaks.
        case "$command" in
          *[!A-Za-z0-9\ ._/:@,+=%^~\'\"-]*) refuse "this crew member may run only plain read-only git commands and ls: no pipes, redirects, chaining, \$, backslashes, parentheses, braces or wildcards, even inside quotes. For another folder use git -C <folder>; to search, use the Grep tool." ;;
        esac
        # Quotes can hide a flag from a text match (--out''put), so flags are checked without them.
        # --out and --ext also cover the abbreviations git accepts for --output and --ext-diff.
        plain=$(printf '%s' "$command" | /usr/bin/tr -d "'\"")
        case "$plain" in
          *--out*|*--ext*|*' -c '*) refuse "this crew member may not ask git to write a file or run another program." ;;
        esac
        # The folder is read as the shell will read it: wholly quoted, or bare with no quotes inside
        # and no ~ or = in front for zsh to expand. Any other spelling is refused, so the config
        # check below can never look at a different folder from the one git runs in.
        folder=$(printf '%s' "$command" | /usr/bin/sed -nE "s/^git -C ('([^']*)'|\"([^\"]*)\"|([^ '\"~=][^ '\"]*)) .*/\2\3\4/p")
        case "$command" in
          'git -C '*) [ -n "$folder" ] || refuse "this crew member may name a folder for git -C only plainly or wholly in quotes, with no ~ in front." ;;
        esac
        # "git -C <folder> status" reads the same as "git status".
        command=$(printf '%s' "$command" | /usr/bin/sed -E "s/^git -C ('[^']*'|\"[^\"]*\"|[^ ]+) /git /")
        case "$command" in
          ls|'ls '*) exit 0 ;;
          'git diff'|'git diff '*|'git log'|'git log '*|'git show'|'git show '*|'git status'|'git status '*|'git blame '*|'git rev-parse '*|'git ls-files'|'git ls-files '*|'git branch --show-current'|'git merge-base '*) ;;
          *) refuse "this crew member may run only read-only git commands (diff, log, show, status, blame) and ls. For another folder use git -C <folder>." ;;
        esac
        # Even read-only git runs programs a repository's own config names: core.fsmonitor on
        # status and diff, diff.external and diff drivers, clean and smudge filters, gpg on signed
        # commits, and a fetch for a missing object in a partial clone (upload-pack, ssh, proxies).
        # Git is refused in a repository whose own config sets any of these. The person's global and
        # system config are theirs and trusted. A submodule's config is not checked. Anything this
        # check can't settle (no such folder, not a repository, git missing or too old) is refused.
        cwd=$(field cwd)
        if [ -n "$cwd" ]; then cd "$cwd" 2>/dev/null || refuse "the crew guard could not find the folder this command runs in, so it was refused."; fi
        git -C "${folder:-.}" rev-parse --git-dir >/dev/null 2>&1 || refuse "the crew guard could not check this folder's git config (is it a repository?), so git was refused."
        # git status and git diff rewrite the index, and every index write runs a post-index-change
        # hook. The path git gives follows core.hooksPath, so repositories that keep their hooks
        # elsewhere (husky and the like) still pass unless they have this one hook.
        hook=$(git -C "${folder:-.}" rev-parse --path-format=absolute --git-path hooks/post-index-change 2>/dev/null) \
          || refuse "the crew guard could not check this folder's git hooks, so git was refused."
        [ ! -x "$hook" ] || refuse "this repository has a hook git would run, so the crew may not run git in it. Ask the person to look at its git hooks."
        risky=$(git -C "${folder:-.}" config --show-scope --get-regexp '^(core\.fsmonitor|diff\.external|diff\..*\.(command|textconv)|filter\..*\.(clean|smudge|process)|gpg\.|extensions\.partialclone|remote\..*\.(uploadpack|promisor)|core\.sshcommand|core\.gitproxy|protocol\.)' 2>/dev/null)
        [ $? -le 1 ] || refuse "the crew guard could not check this folder's git config, so git was refused."
        # Key names come from the repository, so they are not repeated back.
        printf '%s\n' "$risky" | /usr/bin/grep -E '^(local|worktree)[[:space:]]' \
          | /usr/bin/grep -Eivq '^[a-z]+[[:space:]]+core\.fsmonitor (true|false|yes|no|on|off|1|0)$' \
          && refuse "this repository's own git config names a program git would run, so the crew may not run git in it. Ask the person to look at its .git/config."
        exit 0 ;;
      WebFetch)
        # Only a member whose charter sends web calls here has them at all. Prices and documentation
        # are read from cloud providers' own sites: https, a listed host, and a plain path with no
        # query, so nothing from the project can ride out in an address.
        url=$(field tool_input.url)
        case "$url" in
          https://*) ;;
          *) refuse "this crew member may read only https pages on cloud providers' own sites." ;;
        esac
        rest=${url#https://}
        host=${rest%%/*}
        case "$rest" in
          *[!A-Za-z0-9._/-]*) refuse "this crew member may read only plain addresses: no query, fragment or encoded characters." ;;
        esac
        [ ${#url} -le 200 ] || refuse "that address is too long for a pricing or documentation page."
        case "$host" in
          aws.amazon.com|docs.aws.amazon.com|calculator.aws|cloud.google.com|firebase.google.com|azure.microsoft.com|learn.microsoft.com|www.cloudflare.com|developers.cloudflare.com|vercel.com|www.netlify.com|docs.netlify.com|fly.io|render.com|railway.com|docs.railway.com|supabase.com|neon.tech|neon.com|planetscale.com|upstash.com|www.mongodb.com|www.digitalocean.com|docs.digitalocean.com|www.hetzner.com|www.heroku.com|devcenter.heroku.com|docs.github.com|www.docker.com|docs.docker.com|kubernetes.io) exit 0 ;;
          *) refuse "this crew member may read only cloud providers' own pricing and documentation pages. Say which page would help and let the person open it." ;;
        esac ;;
      WebSearch)
        # A search goes to a search engine, so it must not carry anything that looks lifted from
        # the project: short, plain words only, and no long unbroken string such as a key or a path.
        query=$(field tool_input.query)
        [ -n "$query" ] || refuse "the crew guard could not read this search, so it was refused."
        [ ${#query} -le 120 ] || refuse "keep a search under 120 characters: the service and what you want to know."
        case "$query" in
          *[!A-Za-z0-9\ .,+%$\'-]*) refuse "search in plain words only: no paths, addresses, quotes or symbols." ;;
        esac
        printf '%s' "$query" | /usr/bin/grep -Eq '[^ ]{25,}' && refuse "that search holds a long unbroken string. Never put names, keys or paths from the project into a search."
        exit 0 ;;
      '') refuse "the crew guard could not read this tool call, so it was refused." ;;
      *) exit 0 ;;
    esac

    """#
}
