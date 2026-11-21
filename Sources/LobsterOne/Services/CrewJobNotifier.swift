import Foundation
import UserNotifications

/// Tells the person about crew jobs: one that asks first is due (with a button to start it), or
/// one that started by itself has finished.
@MainActor
enum CrewJobNotifier {
    nonisolated static let categoryId = "CREW_JOB"
    nonisolated static let runActionId = "CREW_JOB_RUN"
    nonisolated static let laterActionId = "CREW_JOB_LATER"
    nonisolated static let idPrefix = "crew-job-"
    /// Posted when the person answers a reminder. `userInfo` holds `key` and `run`.
    nonisolated static let answered = Notification.Name("LobsterOneCrewJobAnswered")

    nonisolated static var category: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryId, actions: [
            UNNotificationAction(identifier: runActionId, title: "Run now", options: []),
            UNNotificationAction(identifier: laterActionId, title: "Later", options: []),
        ], intentIdentifiers: [], options: [])
    }

    /// UNUserNotificationCenter traps when the process has no bundle (e.g. `swift run`).
    private static var canUseNotifications: Bool { Bundle.main.bundleIdentifier != nil }

    static func announce(_ due: [(job: CrewJob, due: Date)], members: [TeamMember]) {
        guard CrewNotifier.isEnabled, canUseNotifications, !due.isEmpty else { return }
        Task {
            switch await PaceNotifier.permission() {
            case .allowed: break
            case .notAsked: guard await PaceNotifier.requestPermission() else { return }
            case .denied, .unavailable: return
            }
            for item in due {
                let person = CrewCalendar.person(item.job.agent, members: members)
                let content = UNMutableNotificationContent()
                content.title = "\(person.name) is due"
                content.body = body(item.job)
                content.sound = .default
                content.categoryIdentifier = categoryId
                let key = CrewRun.key(job: item.job.id, due: item.due)
                content.userInfo = ["crewJobKey": key]
                if let face = person.face, let attachment = portrait(face) { content.attachments = [attachment] }
                do {
                    try await UNUserNotificationCenter.current()
                        .add(UNNotificationRequest(identifier: idPrefix + key, content: content, trigger: nil))
                } catch {
                    DebugLog.shared.log("Crew job reminder not shown: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Says what came of a job that ran by itself. Clicking it opens the calendar.
    static func finished(_ job: CrewJob, _ run: CrewRun, members: [TeamMember]) {
        guard CrewNotifier.isEnabled, canUseNotifications else { return }
        Task {
            guard await PaceNotifier.permission() == .allowed else { return }
            let person = CrewCalendar.person(job.agent, members: members)
            let content = UNMutableNotificationContent()
            let outcome = outcome(run, name: person.name)
            content.title = outcome.title
            content.body = "\(outcome.detail) \(body(job))"
            content.sound = .default
            content.userInfo = ["crewJobKey": run.id]
            if let face = person.face, let attachment = portrait(face) { content.attachments = [attachment] }
            try? await UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: idPrefix + run.id + "-done", content: content, trigger: nil))
        }
    }

    /// "Wren is done" and "2 findings.", or "Wren did not finish" and why.
    nonisolated static func outcome(_ run: CrewRun, name: String) -> (title: String, detail: String) {
        guard run.state == .done else { return ("\(name) did not finish", run.note ?? "It did not finish.") }
        switch run.findings {
        case nil: return ("\(name) is done", "The report is on the calendar.")
        case 0?: return ("\(name) is done", "Nothing found.")
        case 1?: return ("\(name) is done", "1 finding.")
        case let count?: return ("\(name) is done", "\(count) findings.")
        }
    }

    /// "Review what merged to main. In Robocog---Mac."
    nonisolated static func body(_ job: CrewJob) -> String {
        let task = job.task.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = task.count > 120 ? String(task.prefix(117)) + "\u{2026}" : task
        let ended = short.hasSuffix(".") || short.hasSuffix("\u{2026}") ? short : short + "."
        return "\(ended) In \(job.places)."
    }

    /// True when the response belonged to a crew job reminder; passes the answer on.
    nonisolated static func handle(_ response: UNNotificationResponse) -> Bool {
        let request = response.notification.request
        guard request.identifier.hasPrefix(idPrefix),
              let key = request.content.userInfo["crewJobKey"] as? String else { return false }
        // "Later" needs nothing done: the job stays waiting on the calendar.
        guard response.actionIdentifier != laterActionId else { return true }
        let run = response.actionIdentifier == runActionId
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: answered, object: nil, userInfo: ["key": key, "run": run])
        }
        return true
    }

    private static func portrait(_ face: String) -> UNNotificationAttachment? {
        guard let source = CrewPortrait.url(face) else { return nil }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("crew-\(face)-\(UUID().uuidString).jpg")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            return try UNNotificationAttachment(identifier: face, url: copy)
        } catch {
            return nil
        }
    }
}
