import Foundation

/// An open invite into the harbour town, as listed by GET /v1/notifications/count
/// (`town_invites`, unread and unexpired). The wording is fixed; nothing here is free text
/// from the sender except their profile name and the place name the town chose.
struct TownInvite: Decodable, Equatable, Identifiable {
    let id: String
    let inviteId: String
    let fromName: String
    let place: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case inviteId = "invite_id"
        case fromName = "from_name"
        case place
        case expiresAt = "expires_at"
    }

    init(id: String, inviteId: String, fromName: String, place: String, expiresAt: Date?) {
        self.id = id
        self.inviteId = inviteId
        self.fromName = fromName
        self.place = place
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The row id may arrive as a number or a string depending on the column type.
        if let text = try? c.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        inviteId = try c.decode(String.self, forKey: .inviteId)
        fromName = (try? c.decode(String.self, forKey: .fromName)) ?? ""
        place = (try? c.decode(String.self, forKey: .place)) ?? ""
        expiresAt = Self.date(c, .expiresAt)
    }

    /// ISO 8601 text (with or without fractions) or a number in seconds or milliseconds.
    private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let text = try? c.decode(String.self, forKey: key) {
            let plain = ISO8601DateFormatter()
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text) ?? plain.date(from: text)
        }
        if let number = try? c.decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
        }
        return nil
    }

    var name: String {
        let trimmed = fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A LobsterOne builder" : trimmed
    }

    /// With no expiry the backend's own filter is trusted.
    func isLive(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now
    }

    // MARK: - Wording (fixed, matches the backend's push)

    var notificationTitle: String { "\(name) is in town" }

    var notificationBody: String {
        let spot = place.trimmingCharacters(in: .whitespacesAndNewlines)
        return spot.isEmpty ? "\(name) wants to chat." : "\(name) wants to chat. They're at \(spot)."
    }

    var rowText: String { "\(name) wants to chat in town" }

    // MARK: - Identifiers and links

    /// Same as the backend's apns-collapse-id, so a push and a later poll land on one notification.
    static func notificationId(_ inviteId: String) -> String { "town-\(inviteId)" }

    static func inviteId(fromNotificationId identifier: String) -> String? {
        guard identifier.hasPrefix("town-") else { return nil }
        let id = String(identifier.dropFirst("town-".count))
        return id.isEmpty ? nil : id
    }

    /// Always built here from the invite id, never taken from a push payload.
    static func joinURL(inviteId: String) -> URL? {
        var components = URLComponents(string: "\(Constants.appURL)/town")
        components?.queryItems = [URLQueryItem(name: "invite", value: inviteId)]
        return components?.url
    }
}

/// What the Mac has done with each invite, kept across launches: which ones were already shown
/// (by poll or push) and how many banners went out today. Pure, so the rules are testable.
struct TownInviteLedger: Codable, Equatable {
    /// Invite id -> when it was handled (shown, or deliberately not shown).
    var seen: [String: Double] = [:]
    /// Invites held back by the cap or the switch, so a push for them stays hidden too.
    var muted: [String: Double] = [:]
    /// Local calendar day the count belongs to, "2026-11-17".
    var day = ""
    var shownToday = 0

    static let dailyCap = 3
    static let quietStartHour = 20
    static let quietEndHour = 9
    /// Invites expire after 30 minutes; a day is plenty to stop repeats.
    static let forgetAfter: TimeInterval = 24 * 3600

    struct Plan: Equatable {
        /// Invites to post a banner for now.
        var post: [TownInvite] = []
        /// Invite ids whose delivered banner should go: the invite was answered, cleared or expired.
        var remove: [String] = []
    }

    /// 20:00 to 09:00 local time, no banners.
    static func isQuiet(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= quietStartHour || hour < quietEndHour
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Decide what one poll's invite list means for the banners.
    /// `delivered` holds the invite ids that have a banner in Notification Center right now.
    mutating func plan(invites: [TownInvite], delivered: Set<String>, enabled: Bool,
                       now: Date, calendar: Calendar = .current) -> Plan {
        rollDay(now, calendar: calendar)
        let live = invites.filter { $0.isLive(at: now) }
        let liveIds = Set(live.map(\.inviteId))
        var plan = Plan(remove: delivered.subtracting(liveIds).sorted())

        let stamp = now.timeIntervalSince1970
        for invite in live where seen[invite.inviteId] == nil {
            if delivered.contains(invite.inviteId) {
                // A push already showed it.
                seen[invite.inviteId] = stamp
            } else if !enabled {
                seen[invite.inviteId] = stamp
            } else if Self.isQuiet(now, calendar: calendar) {
                // Not marked: if it is still open after 09:00 it can show then.
                continue
            } else if shownToday >= Self.dailyCap {
                seen[invite.inviteId] = stamp
            } else {
                seen[invite.inviteId] = stamp
                shownToday += 1
                plan.post.append(invite)
            }
        }
        forgetOld(now)
        return plan
    }

    /// A push banner arrived for this invite. Returns whether it may stay on screen.
    /// Safe to call more than once for the same push.
    mutating func admitPush(inviteId: String, enabled: Bool, now: Date, calendar: Calendar = .current) -> Bool {
        rollDay(now, calendar: calendar)
        if seen[inviteId] != nil { return muted[inviteId] == nil }
        if Self.isQuiet(now, calendar: calendar) { return false }
        let stamp = now.timeIntervalSince1970
        seen[inviteId] = stamp
        guard enabled, shownToday < Self.dailyCap else {
            muted[inviteId] = stamp
            return false
        }
        shownToday += 1
        forgetOld(now)
        return true
    }

    private mutating func rollDay(_ now: Date, calendar: Calendar) {
        let today = Self.dayKey(now, calendar: calendar)
        if day != today {
            day = today
            shownToday = 0
        }
    }

    private mutating func forgetOld(_ now: Date) {
        let cutoff = now.timeIntervalSince1970 - Self.forgetAfter
        seen = seen.filter { $0.value >= cutoff }
        muted = muted.filter { $0.value >= cutoff }
    }
}
