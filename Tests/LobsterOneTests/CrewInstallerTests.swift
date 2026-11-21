import Testing
import Foundation
@testable import LobsterOne

private func tempHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("crew-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct CrewInstallerTests {
    @Test func hireWritesACharterTheScannerReadsBack() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home)

        let url = try installer.hire(.bram, model: .opus)
        #expect(url.path.hasSuffix(".claude/agents/release-reviewer.md"))

        let text = try String(contentsOf: url, encoding: .utf8)
        let fields = TeamScanner.frontmatter(text)
        #expect(fields["name"] == "release-reviewer")
        #expect(fields["description"] == CrewRole.bram.description)
        #expect(fields["tools"] == "Read, Grep, Glob, Bash")
        #expect(fields["model"] == "opus")
        #expect(fields["memory"] == "user")
        #expect(text.contains("You are Bram, the release reviewer."))
        #expect(text.contains("command: \"'\(installer.guardURL.path)' release-reviewer\""))

        let member = try #require(TeamScanner.charters(in: installer.agentsDirectory).first)
        #expect(member.persona == .init(name: "Bram", face: "bram", title: "Release reviewer"))
        #expect(member.displayName == "Bram")
        #expect(CrewInstaller.isOurs(url))
    }

    @Test func hireInstallsAnExecutableGuard() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home)
        try installer.hire(.wren, model: .inherit)
        #expect(installer.guardURL.path.hasSuffix("Library/Application Support/LobsterOne/Crew/guard.sh"))
        #expect(FileManager.default.isExecutableFile(atPath: installer.guardURL.path))
    }

    @Test func hireNeverOverwritesSomeoneElsesAgent() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home)
        try FileManager.default.createDirectory(at: installer.agentsDirectory, withIntermediateDirectories: true)
        let mine = "---\nname: release-reviewer\ndescription: my own\n---\nMine.\n"
        try mine.write(to: installer.charterURL(for: .bram), atomically: true, encoding: .utf8)

        #expect(installer.isNameTaken(.bram))
        #expect(throws: CrewInstaller.Failure.nameTaken("release-reviewer")) { try installer.hire(.bram, model: .opus) }
        #expect(try String(contentsOf: installer.charterURL(for: .bram), encoding: .utf8) == mine)
        #expect(throws: CrewInstaller.Failure.notOurs("release-reviewer")) { try installer.remove(agentNamed: "release-reviewer") }
        #expect(FileManager.default.fileExists(atPath: installer.charterURL(for: .bram).path))
    }

    @Test func hiringAgainReplacesOurOwnCharter() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home)
        try installer.hire(.bram, model: .opus)
        #expect(!installer.isNameTaken(.bram))
        try installer.hire(.bram, model: .sonnet)
        let text = try String(contentsOf: installer.charterURL(for: .bram), encoding: .utf8)
        #expect(TeamScanner.frontmatter(text)["model"] == "sonnet")
    }

    @Test func removeDeletesTheCharterAndKeepsTheNotebook() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home)
        try installer.hire(.edda, model: .opus)
        let notebook = home.appendingPathComponent(".claude/agent-memory/data-analyst/MEMORY.md")
        try FileManager.default.createDirectory(at: notebook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "- weekly actives: distinct signed-in users\n".write(to: notebook, atomically: true, encoding: .utf8)

        try installer.remove(agentNamed: "data-analyst")
        #expect(!FileManager.default.fileExists(atPath: installer.charterURL(for: .edda).path))
        #expect(FileManager.default.fileExists(atPath: notebook.path))
    }

    @Test func theHiringWindowOpensOnAShortRosterAndKeepsTheRestBehindShowMore() {
        #expect(CrewRole.featured.map(\.name) == ["Wren", "Bram", "Edda", "Old Tom", "Finn", "Flick", "Marco", "Cora"])
        #expect(CrewRole.more.map(\.name) == ["Dougal", "Marla", "Semicolon", "Pip", "Hilda", "Ivy", "Mort", "Zephyr"])
        // Between them they are everyone, once each.
        #expect(Set((CrewRole.featured + CrewRole.more).map(\.id)) == Set(CrewRole.ready.map(\.id)))
        #expect(CrewRole.featured.count + CrewRole.more.count == CrewRole.ready.count)
        #expect(URL(string: Constants.teamsURL)?.host == "lobsterone.ai")
    }

    @Test func theWholeTownCanBeHired() {
        let roles = CrewRole.ready
        #expect(roles.count == 16)
        #expect(Set(roles.map(\.name)).count == roles.count)
        #expect(Set(roles.map(\.face)).count == roles.count)
        for role in roles {
            // The id is the file name and the agent's name in Claude Code.
            #expect(CrewRole.slug(role.id) == role.id)
            #expect(CrewPortrait.url(role.face) != nil, "no portrait for \(role.name)")
            #expect(role.instructions.hasPrefix("You are \(role.name), "))
            #expect(role.instructions.contains("Your notebook:"))
            #expect(role.instructions.hasSuffix(role.logsFindings ? "Write nowhere else but your ledger." : "Write nowhere else."))
            #expect(role.firstJob.contains(role.name))
            #expect(role.does.hasSuffix(".") && role.quote.count < 80)
            // Nobody is given a tool the guard would have to refuse outright.
            #expect(Set(role.tools).isSubset(of: ["Read", "Grep", "Glob", "Bash", "WebSearch", "WebFetch"]))
            // Everyone has a lane, and an example of a job to put on the calendar.
            #expect(role.houseRules.contains("(\(role.name))"), "\(role.name) has no lane")
            #expect(CrewCalendar.examples[role.id] != nil, "no calendar example for \(role.name)")
        }
        // Only Marco reaches the web, and his charter sends those calls through the guard too.
        #expect(roles.filter(\.usesWeb).map(\.name) == ["Marco"])
        let installer = CrewInstaller(homeDirectory: URL(fileURLWithPath: "/Users/me"))
        let marco = installer.charter(for: .marco, model: .opus)
        #expect(marco.contains("    - matcher: \"WebSearch|WebFetch\"\n      hooks:\n        - type: command\n          command: \"'/Users/me/Library/Application Support/LobsterOne/Crew/guard.sh' cost-controller\""))
        #expect(CrewInstaller.hasGuard(marco, agent: "cost-controller"))
        #expect(marco.contains("Your web access is for prices and documentation only."))
        #expect(!marco.contains("you cannot reach the network"))
        let cora = installer.charter(for: .cora, model: .opus)
        #expect(!cora.contains("WebSearch") && cora.contains("you cannot reach the network"))
        #expect(CrewInstaller.hasGuard(cora, agent: "seo-specialist"))
        // Cora asks for the SEO plugin; she is never told to install or update it herself.
        #expect(cora.contains("You never install or update anything yourself; you ask the owner."))
        #expect(cora.contains("/plugin install claude-seo@agricidaniel-claude-seo"))
        #expect(!CrewRole.cora.tools.contains("WebFetch"))
        // Those who run nothing keep no findings log.
        #expect(roles.filter { !$0.logsFindings }.map(\.name) == ["Edda", "Marla", "Pip", "Zephyr"])
    }

    @Test func anOldGuardScriptIsReplacedAndNoneIsCreatedBeforeAHire() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("guard-refresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let installer = CrewInstaller(homeDirectory: home, supportDirectory: home.appendingPathComponent("support"))
        installer.refreshGuard()
        #expect(!FileManager.default.fileExists(atPath: installer.guardURL.path))
        try installer.hire(.wren, model: .opus)
        try "#!/bin/sh\nexit 0\n".write(to: installer.guardURL, atomically: true, encoding: .utf8)
        installer.refreshGuard()
        #expect(try String(contentsOf: installer.guardURL, encoding: .utf8) == CrewGuard.script)
        #expect(FileManager.default.isExecutableFile(atPath: installer.guardURL.path))
    }

    @Test func everyReadyRoleHasADistinctNameAndAGuardedCharter() {
        let installer = CrewInstaller(homeDirectory: URL(fileURLWithPath: "/Users/it's me"))
        #expect(Set(CrewRole.ready.map(\.id)).count == CrewRole.ready.count)
        for role in CrewRole.ready {
            let text = installer.charter(for: role, model: .opus)
            let fields = TeamScanner.frontmatter(text)
            #expect(fields["name"] == role.id)
            #expect(fields[CrewInstaller.markerField] == "1")
            #expect(fields[CrewInstaller.nameField] == role.name)
            #expect(fields["description"]?.hasPrefix("\(role.name). ") == true)
            // A quote in the home path survives the shell and the YAML.
            #expect(text.contains(#"command: "'/Users/it'\\''s me/Library/Application Support/LobsterOne/Crew/guard.sh' \#(role.id)""#))
            #expect(!role.tools.contains("Write") && !role.tools.contains("Edit"))
        }
        // Edda runs nothing at all.
        #expect(!CrewRole.edda.runsCommands)
    }

    @Test func customRolesGetASafeNameAndOneLineText() throws {
        let role = try #require(CrewRole.custom(name: "  Zed \"the\" Fixer\n", job: "Checks migrations\nbefore they run"))
        #expect(role.id == "zed-the-fixer")
        #expect(role.name == "Zed the Fixer")
        #expect(role.does == "Checks migrations before they run.")
        #expect(role.face == "newcomer")
        #expect(CrewRole.custom(name: "!!!", job: "x") == nil)
        #expect(CrewRole.custom(name: "Zed", job: "  ") == nil)
        #expect(CrewRole.slug("../../etc/passwd") == "etc-passwd")
        #expect(CrewRole.slug("Émile  O'Neil") == "mile-o-neil")

        let text = CrewInstaller(homeDirectory: URL(fileURLWithPath: "/Users/me")).charter(for: role, model: .inherit)
        #expect(TeamScanner.frontmatter(text)["name"] == "zed-the-fixer")
        #expect(TeamScanner.frontmatter(text)[CrewInstaller.nameField] == "Zed the Fixer")
    }

    @Test func frontmatterUnescapesDoubleQuotedValues() {
        let fields = TeamScanner.frontmatter("---\nname: x\ndescription: \"says \\\"hi\\\" in C:\\\\dir\"\n---\n")
        #expect(fields["description"] == "says \"hi\" in C:\\dir")
    }
}

/// Runs the real guard script against sample tool calls, as Claude Code would.
struct CrewGuardTests {
    private let home: URL
    private let script: URL

    init() throws {
        home = try tempHome()
        let installer = CrewInstaller(homeDirectory: home)
        try installer.hire(.bram, model: .opus)
        script = installer.guardURL
    }

    /// The guard's exit code for one tool call: 0 lets it through, 2 refuses it.
    private func verdict(_ tool: String, _ input: [String: String], raw: String? = nil, cwd: URL? = nil) throws -> (code: Int32, message: String) {
        let process = Process()
        process.executableURL = script
        process.arguments = ["release-reviewer"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        let body = try raw.map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject: ["tool_name": tool, "tool_input": input, "cwd": cwd?.path ?? ""])
        stdin.fileHandleForWriting.write(body)
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, message)
    }

    private var notebook: String { home.path + "/.claude/agent-memory/release-reviewer/" }

    @Test func writesAreAllowedOnlyInTheMembersOwnNotebook() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try verdict("Write", ["file_path": notebook + "MEMORY.md"]).code == 0)
        #expect(try verdict("Edit", ["file_path": notebook + "topics/releases.md"]).code == 0)

        let refused = try verdict("Write", ["file_path": "/Users/me/app/main.swift"])
        #expect(refused.code == 2)
        #expect(refused.message.contains("may write only in its notebook"))
        #expect(try verdict("Edit", ["file_path": notebook + "../../settings.json"]).code == 2)
        // Another member whose name starts the same way.
        #expect(try verdict("Write", ["file_path": home.path + "/.claude/agent-memory/release-reviewer-2/MEMORY.md"]).code == 2)
        #expect(try verdict("NotebookEdit", ["notebook_path": "/Users/me/app/analysis.ipynb"]).code == 2)
    }

    @Test func onlyReadOnlyGitAndLsMayRun() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for allowed in ["git status", "git diff main...HEAD -- Sources", "git log -5 --format=\"%h %s\"", "git show HEAD~1",
                        "git blame Sources/App.swift", "git -C \(try repo([], named: "app").path) status",
                        "git -C '\(try repo([], named: "my app").path)' diff",
                        "git branch --show-current", "ls", "ls -la Sources"] {
            #expect(try verdict("Bash", ["command": allowed]).code == 0, "\(allowed)")
        }
        for refused in ["rm -rf build", "touch y.txt", "git push", "git commit -am x", "git checkout main", "git diff > out.txt",
                        "git status; rm -rf x", "git status && git push", "git log | sh", "git diff --output=x", "git status\nrm x",
                        "git -c core.pager=sh log", "echo $(whoami)", "git -C /tmp push", "lsof", "cat ~/.ssh/id_rsa"] {
            #expect(try verdict("Bash", ["command": refused]).code == 2, "\(refused)")
        }
    }

    /// Marco may look prices up: plain searches, and pages on cloud providers' own sites only.
    @Test func theWebIsForPricesAndNothingFromTheProjectRidesOut() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for allowed in ["https://aws.amazon.com/rds/pricing/", "https://cloud.google.com/run/pricing",
                        "https://docs.aws.amazon.com/lambda/latest/dg/welcome.html", "https://fly.io/docs/about/pricing/"] {
            #expect(try verdict("WebFetch", ["url": allowed]).code == 0, "\(allowed)")
        }
        for refused in ["http://aws.amazon.com/rds/pricing/", "https://evil.example/collect", "https://aws.amazon.com.evil.example/x",
                        "https://aws.amazon.com/rds/pricing/?key=AKIAABCDEFGH", "https://aws.amazon.com/x#secret",
                        "https://user@aws.amazon.com/x", "https://aws.amazon.com/%41", "https://pastebin.com/raw/abc",
                        "https://aws.amazon.com/" + String(repeating: "a", count: 200), "file:///etc/passwd", ""] {
            #expect(try verdict("WebFetch", ["url": refused]).code == 2, "\(refused)")
        }
        for allowed in ["aws nat gateway pricing us-east-1", "fargate vs lambda cost 2026", "rds t4g.micro price per hour"] {
            #expect(try verdict("WebSearch", ["query": allowed]).code == 0, "\(allowed)")
        }
        for refused in ["sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz012345", "what is /Users/me/app/.env", "site:evil.example \"secret\"",
                        "pricing for https://example.com/x", String(repeating: "word ", count: 30), ""] {
            #expect(try verdict("WebSearch", ["query": refused]).code == 2, "\(refused)")
        }
    }

    /// The shell rejoins a word after the guard has read it, so a flag split by quotes, a backslash,
    /// an empty variable or braces must be refused as firmly as the flag itself.
    @Test func aFlagCannotBeSmuggledPastTheGuard() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for refused in ["git log -1 --format=x --out''put=/tmp/x", "git log -1 --o\"utput\"=/tmp/x", "git log -1 --outpu\\t=/tmp/x",
                        "git log -1 --out${NOPE}put=/tmp/x", "git log -1 --{output,x}=/tmp/x", "git log -1 --outpu=/tmp/x",
                        "git diff --ext HEAD", "git diff --ext-diff", "git show 'HEAD' '-c' x", "git log --format=%x --out*",
                        "git log -1 --format='[core]%n%x09fsmonitor = x' --out''put=.git/config", "git status\trm"] {
            #expect(try verdict("Bash", ["command": refused]).code == 2, "\(refused)")
        }
        // What the charters tell the crew to run still passes.
        for allowed in ["git rev-parse --abbrev-ref origin/HEAD", "git diff main...HEAD", "git diff HEAD", "git merge-base HEAD origin/main",
                        "git log -p -- Sources/App.swift", "git log -S risingLine --oneline", "git log -1 --format=%as -- Package.resolved",
                        "git blame -L 10,20 --date=short Sources/App.swift", "git ls-files -ci --exclude-standard",
                        "git show HEAD~2:README.md", "git -C \"\(try repo([], named: "my app").path)\" log -n 20", "ls -la .github/workflows"] {
            #expect(try verdict("Bash", ["command": allowed]).code == 0, "\(allowed)")
        }
    }

    /// zsh runs code from glob qualifiers, process substitution and parameter flags, all inside
    /// an otherwise harmless ls or git. Only plain characters may pass, even inside quotes.
    @Test func shellFormsThatRunCodeAreRefused() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        for refused in ["ls -d /(e:'REPLY=/tmp':)", "ls *(e:'touch x':)", "ls =(touch x)", "git log =(touch x)", "ls ${(e)x}",
                        "ls ${x@P}", "git diff \"$(touch x)\"", "ls `touch x`", "ls {a,b}", "ls *", "ls ?", "ls [ab]", "ls a#",
                        "ls 'a\\b'", "ls !x", "git status\trm", "ls \u{00e9}", "git log --out''put=/tmp/x", "git log --outpu=/tmp/x",
                        "git diff --ext"] {
            #expect(try verdict("Bash", ["command": refused]).code == 2, "\(refused)")
        }
        for allowed in ["ls", "git diff", "git log", "git status", "git show HEAD~2:README.md", "git log -1 --format=%h^%s",
                        "git -C \"\(try repo([], named: "my app").path)\" log -n 20", "git blame -L 10,20 Sources/App.swift"] {
            #expect(try verdict("Bash", ["command": allowed]).code == 0, "\(allowed)")
        }
    }

    /// Read-only git still runs programs a repository's own config names, so such a repository is refused.
    @Test func gitIsRefusedInARepositoryWhoseConfigNamesAProgram() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let plain = try repo([]), builtin = try repo(["core.fsmonitor true"])
        for dir in [plain, builtin] {
            for command in ["git status", "git diff", "git log", "git -C '\(dir.path)' status"] {
                #expect(try verdict("Bash", ["command": command], cwd: dir).code == 0, "\(command) in \(dir.lastPathComponent)")
            }
        }
        for key in ["core.fsmonitor /tmp/run-me", "diff.external /tmp/run-me", "diff.pic.textconv /tmp/run-me",
                    "diff.pic.command /tmp/run-me", "filter.pic.clean /tmp/run-me", "gpg.program /tmp/run-me",
                    // A partial clone fetches a missing object, which can run upload-pack, ssh or a proxy.
                    "extensions.partialClone origin", "remote.origin.promisor true", "remote.origin.uploadpack /tmp/run-me",
                    "core.sshCommand /tmp/run-me", "core.gitProxy /tmp/run-me", "protocol.ext.allow always"] {
            let dir = try repo([key])
            for command in ["git status", "git diff", "git log", "git show", "git blame x"] {
                let refused = try verdict("Bash", ["command": command], cwd: dir)
                #expect(refused.code == 2, "\(command) with \(key)")
                // The key names come from the repository and are not echoed back.
                #expect(refused.message.contains("names a program git would run"), "\(refused.message)")
                #expect(!refused.message.contains(String(key.prefix { $0 != " " }).lowercased()), "\(refused.message)")
            }
            // Naming the folder with -C is checked the same way, from anywhere.
            #expect(try verdict("Bash", ["command": "git -C \"\(dir.path)\" status"], cwd: plain).code == 2, "\(key)")
            // ls runs no git.
            #expect(try verdict("Bash", ["command": "ls"], cwd: dir).code == 0)
        }
    }

    /// git status and git diff write the index, which runs a post-index-change hook, wherever core.hooksPath puts it.
    @Test func gitIsRefusedWhereAnIndexHookWouldRun() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        func hook(_ folder: URL, executable: Bool = true) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("post-index-change")
            try "#!/bin/sh\ntouch /tmp/ran\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path)
        }
        let inGitDir = try repo([], named: "in-git-dir")
        try hook(inGitDir.appendingPathComponent(".git/hooks"))
        let husky = try repo(["core.hooksPath .husky"], named: "husky")
        try hook(husky.appendingPathComponent(".husky"))
        for dir in [inGitDir, husky] {
            for command in ["git status", "git diff", "git log", "git -C \"\(dir.path)\" status"] {
                let refused = try verdict("Bash", ["command": command], cwd: dir)
                #expect(refused.code == 2, "\(command) in \(dir.lastPathComponent)")
                #expect(refused.message.contains("has a hook git would run"), "\(refused.message)")
            }
        }
        // Hooks folders without that hook, or with it switched off, are fine: a husky setup, the samples git installs.
        let otherHooks = try repo(["core.hooksPath .husky"], named: "other-hooks")
        try FileManager.default.createDirectory(at: otherHooks.appendingPathComponent(".husky"), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: otherHooks.appendingPathComponent(".husky/pre-commit"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: otherHooks.appendingPathComponent(".husky/pre-commit").path)
        let switchedOff = try repo([], named: "switched-off")
        try hook(switchedOff.appendingPathComponent(".git/hooks"), executable: false)
        for dir in [otherHooks, switchedOff] {
            #expect(try verdict("Bash", ["command": "git status"], cwd: dir).code == 0, "\(dir.lastPathComponent)")
        }
    }

    /// The config check must look at the folder git will run in. zsh expands ~ and = and joins quotes,
    /// so those spellings are refused, and a folder the check can't read is refused rather than passed.
    @Test func aFolderTheCheckCannotReadIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try repo(["core.fsmonitor /tmp/run-me"], named: "evil")
        let elsewhere = try repo([], named: "clean")
        for refused in ["git -C ~/evil status", "git -C ~ status", "git -C ev'il' status", "git -C ev\"il\" status", "git -C 'ev'il status",
                        "git -C =evil status", "git -C '' status", "git -C nowhere status", "git -C \(home.path)/nowhere log"] {
            #expect(try verdict("Bash", ["command": refused], cwd: home).code == 2, "\(refused)")
        }
        // Not a repository, or a working folder that is gone.
        #expect(try verdict("Bash", ["command": "git status"], cwd: home).code == 2)
        #expect(try verdict("Bash", ["command": "git status"], cwd: home.appendingPathComponent("gone")).code == 2)
        // The same folder spelled plainly, relative to where the command runs, is checked and allowed when clean.
        #expect(try verdict("Bash", ["command": "git -C clean status"], cwd: home).code == 0)
        #expect(try verdict("Bash", ["command": "git -C \"\(elsewhere.path)\" status"], cwd: home).code == 0)
        #expect(try verdict("Bash", ["command": "git -C evil status"], cwd: home).code == 2)
    }

    /// A fresh repository under the temporary home, with `config` given as "key value" pairs.
    private func repo(_ config: [String], named name: String? = nil) throws -> URL {
        let dir = home.appendingPathComponent(name ?? "repo-\(UUID().uuidString)")
        try git(["init", "-q", dir.path])
        for pair in config { try git(["-C", dir.path, "config"] + pair.split(separator: " ", maxSplits: 1).map(String.init)) }
        return dir
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments)")
    }

    @Test func readingIsNotItsBusinessAndGarbageIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try verdict("Read", ["file_path": "/etc/hosts"]).code == 0)
        #expect(try verdict("Grep", ["pattern": "TODO"]).code == 0)
        let garbage = try verdict("", [:], raw: "not json")
        #expect(garbage.code == 2)
        #expect(garbage.message.contains("could not read this tool call"))
    }
}

/// The guard decides on plutil's exit status, never on what it printed: on some macOS versions
/// plutil writes its error to standard output, which once read as a tool name and was let through.
struct CrewGuardScriptTests {
    @Test func aFailedLookupYieldsNothingWhateverPlutilPrinted() throws {
        #expect(CrewGuard.script.contains(#"-extract "$1" raw -o - - 2>/dev/null) || return 0"#))
        // Run the script's own field() against a plutil stand-in that fails noisily on standard output.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("plutil")
        try "#!/bin/sh\necho '<stdin>: Property List error: Unexpected character'\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let script = dir.appendingPathComponent("guard.sh")
        try CrewGuard.script.replacingOccurrences(of: "/usr/bin/plutil", with: fake.path).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = script
        process.arguments = ["release-reviewer"]
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(#"{"tool_name":"Write","tool_input":{"file_path":"/Users/me/app/main.swift"}}"#.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 2)
        #expect(String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.contains("could not read this tool call") == true)
    }
}
