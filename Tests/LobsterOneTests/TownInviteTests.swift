import Testing
import Foundation
@testable import LobsterOne

// Fixed zone so the quiet hours don't depend on the machine running the tests.
private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Australia/Sydney")!
    return c
}()

/// 17 Nov 2026 at the given local time in Sydney.
private func at(_ hour: Int, _ minute: Int = 0, day: Int = 17) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

private func invite(_ id: String, expires: Date? = nil) -> TownInvite {
    TownInvite(id: "n\(id)", inviteId: id, fromName: "Pierre", place: "the fountain", expiresAt: expires)
}

// MARK: - Decoding

@Test func countDecodesTownInvites() throws {
    let json = """
    {"unread": 2, "town_invites": [
      {"id": 41, "invite_id": "inv_a", "from_name": "Pierre", "place": "the fountain", "expires_at": "2026-11-17T09:30:00.123Z"},
      {"id": "42", "invite_id": "inv_b", "from_name": "Maya", "place": "the jetty", "expires_at": 1795426200000}
    ]}
    """.data(using: .utf8)!
    let response = try JSONDecoder().decode(NotificationCountResponse.self, from: json)
    #expect(response.unread == 2)
    let invites = try #require(response.townInvites)
    #expect(invites.map(\.inviteId) == ["inv_a", "inv_b"])
    #expect(invites[0].id == "41")
    let expected = ISO8601DateFormatter().date(from: "2026-11-17T09:30:00Z")!.addingTimeInterval(0.123)
    #expect(abs(try #require(invites[0].expiresAt).timeIntervalSince(expected)) < 0.001)
    #expect(invites[1].expiresAt == Date(timeIntervalSince1970: 1_795_426_200))
}

@Test func countWithoutTownInvitesIsNil() throws {
    // Older backends: the app must leave town banners alone, not clear them.
    let response = try JSONDecoder().decode(NotificationCountResponse.self, from: #"{"unread": 5}"#.data(using: .utf8)!)
    #expect(response.unread == 5)
    #expect(response.townInvites == nil)
}

@Test func badInviteIsSkippedNotFatal() throws {
    let json = #"{"unread": 1, "town_invites": [{"id": 1}, {"id": 2, "invite_id": "ok", "from_name": "Sam", "place": "the inn"}]}"#
    let response = try JSONDecoder().decode(NotificationCountResponse.self, from: json.data(using: .utf8)!)
    #expect(response.townInvites?.map(\.inviteId) == ["ok"])
    #expect(response.townInvites?.first?.expiresAt == nil)
}

@Test func inviteWordingIsFixed() {
    let i = invite("x")
    #expect(i.notificationTitle == "Pierre is in town")
    #expect(i.notificationBody == "Pierre wants to chat. They're at the fountain.")
    #expect(i.rowText == "Pierre wants to chat in town")
    let nameless = TownInvite(id: "1", inviteId: "y", fromName: "  ", place: "", expiresAt: nil)
    #expect(nameless.notificationTitle == "A LobsterOne builder is in town")
    #expect(nameless.notificationBody == "A LobsterOne builder wants to chat.")
}

@Test func identifiersAndJoinLink() {
    #expect(TownInvite.notificationId("abc") == "town-abc")
    #expect(TownInvite.inviteId(fromNotificationId: "town-abc") == "abc")
    #expect(TownInvite.inviteId(fromNotificationId: "pace-session-1") == nil)
    #expect(TownInvite.inviteId(fromNotificationId: "town-") == nil)
    #expect(TownInvite.joinURL(inviteId: "abc")?.absoluteString == "https://app.lobsterone.ai/town?invite=abc")
    // An odd id can't break out of the query.
    #expect(TownInvite.joinURL(inviteId: "a&b=c#d")?.absoluteString == "https://app.lobsterone.ai/town?invite=a%26b%3Dc%23d")
}

@Test func townClearPushIds() {
    #expect(PushRegistration.clearedInviteIds(["town_clear": ["a", "b"]]) == ["a", "b"])
    #expect(PushRegistration.clearedInviteIds(["town_clear": [7]]) == ["7"])
    #expect(PushRegistration.clearedInviteIds(["aps": ["alert": "x"]]) == nil)
}

// MARK: - Diffing

@Test func newInvitePostsOnceAcrossPolls() {
    var ledger = TownInviteLedger()
    let now = at(14)
    let first = ledger.plan(invites: [invite("a")], delivered: [], enabled: true, now: now, calendar: calendar)
    #expect(first.post.map(\.inviteId) == ["a"])
    // Next poll: same invite, banner still up or already dismissed. Either way, no repeat.
    let again = ledger.plan(invites: [invite("a")], delivered: ["a"], enabled: true, now: now + 300, calendar: calendar)
    #expect(again.post.isEmpty)
    let dismissed = ledger.plan(invites: [invite("a")], delivered: [], enabled: true, now: now + 600, calendar: calendar)
    #expect(dismissed.post.isEmpty)
}

@Test func vanishedOrExpiredInvitesLoseTheirBanner() {
    var ledger = TownInviteLedger()
    let now = at(14)
    _ = ledger.plan(invites: [invite("a"), invite("b")], delivered: [], enabled: true, now: now, calendar: calendar)
    // "a" was answered elsewhere, "b" is still listed but past its expiry.
    let plan = ledger.plan(invites: [invite("b", expires: now + 60)], delivered: ["a", "b"],
                           enabled: true, now: now + 120, calendar: calendar)
    #expect(plan.remove == ["a", "b"])
    #expect(plan.post.isEmpty)
}

@Test func pushedInviteIsNotPostedAgainByPoll() {
    var ledger = TownInviteLedger()
    let plan = ledger.plan(invites: [invite("a")], delivered: ["a"], enabled: true, now: at(14), calendar: calendar)
    #expect(plan.post.isEmpty)
    #expect(plan.remove.isEmpty)
}

@Test func switchOffPostsNothing() {
    var ledger = TownInviteLedger()
    let plan = ledger.plan(invites: [invite("a")], delivered: [], enabled: false, now: at(14), calendar: calendar)
    #expect(plan.post.isEmpty)
    let admitted1 = ledger.admitPush(inviteId: "b", enabled: false, now: at(14), calendar: calendar)
    #expect(!admitted1)
}

@Test func ledgerForgetsAfterADay() {
    var ledger = TownInviteLedger()
    _ = ledger.plan(invites: [invite("a")], delivered: [], enabled: true, now: at(10), calendar: calendar)
    _ = ledger.plan(invites: [], delivered: [], enabled: true, now: at(11, day: 18), calendar: calendar)
    #expect(ledger.seen.isEmpty)
}

// MARK: - Quiet hours

@Test func quietHoursAreEightPmToNineAm() {
    #expect(TownInviteLedger.isQuiet(at(20), calendar: calendar))
    #expect(TownInviteLedger.isQuiet(at(23, 59), calendar: calendar))
    #expect(TownInviteLedger.isQuiet(at(0), calendar: calendar))
    #expect(TownInviteLedger.isQuiet(at(8, 59), calendar: calendar))
    #expect(!TownInviteLedger.isQuiet(at(9), calendar: calendar))
    #expect(!TownInviteLedger.isQuiet(at(19, 59), calendar: calendar))
}

@Test func quietInviteShowsAfterNineIfStillOpen() {
    var ledger = TownInviteLedger()
    let open = invite("a", expires: at(9, 20))
    let early = ledger.plan(invites: [open], delivered: [], enabled: true, now: at(8, 55), calendar: calendar)
    #expect(early.post.isEmpty)
    let later = ledger.plan(invites: [open], delivered: [], enabled: true, now: at(9, 5), calendar: calendar)
    #expect(later.post.map(\.inviteId) == ["a"])
}

@Test func pushInQuietHoursIsHidden() {
    var ledger = TownInviteLedger()
    let admitted2 = ledger.admitPush(inviteId: "a", enabled: true, now: at(21), calendar: calendar)
    #expect(!admitted2)
    let admitted3 = ledger.admitPush(inviteId: "b", enabled: true, now: at(12), calendar: calendar)
    #expect(admitted3)
}

// MARK: - Daily cap

@Test func atMostThreeADay() {
    var ledger = TownInviteLedger()
    let invites = (1...5).map { invite("i\($0)") }
    let plan = ledger.plan(invites: invites, delivered: [], enabled: true, now: at(10), calendar: calendar)
    #expect(plan.post.map(\.inviteId) == ["i1", "i2", "i3"])
    // The capped ones don't come back later the same day...
    let later = ledger.plan(invites: invites, delivered: [], enabled: true, now: at(11), calendar: calendar)
    #expect(later.post.isEmpty)
    // ...and a push counts against the same cap.
    let admitted4 = ledger.admitPush(inviteId: "p", enabled: true, now: at(12), calendar: calendar)
    #expect(!admitted4)
    // A new local day starts the count again.
    let tomorrow = ledger.plan(invites: [invite("t")], delivered: [], enabled: true, now: at(10, day: 18), calendar: calendar)
    #expect(tomorrow.post.map(\.inviteId) == ["t"])
}

@Test func pushesCountTowardTheCapAndRepeatCallsAgree() {
    var ledger = TownInviteLedger()
    for id in ["a", "b", "c"] {
        let admitted5 = ledger.admitPush(inviteId: id, enabled: true, now: at(13), calendar: calendar)
        #expect(admitted5)
    }
    let admitted6 = ledger.admitPush(inviteId: "d", enabled: true, now: at(13), calendar: calendar)
    #expect(!admitted6)
    // willPresent and didReceiveRemoteNotification can both ask about one push.
    let admitted7 = ledger.admitPush(inviteId: "a", enabled: true, now: at(13), calendar: calendar)
    #expect(admitted7)
    let admitted8 = ledger.admitPush(inviteId: "d", enabled: true, now: at(13), calendar: calendar)
    #expect(!admitted8)
    // Poll after the pushes: nothing more to post.
    let plan = ledger.plan(invites: [invite("e")], delivered: ["a", "b", "c"], enabled: true, now: at(14), calendar: calendar)
    #expect(plan.post.isEmpty)
}

// MARK: - Device registration

@Test func apnsDeviceBodyCarriesTimeZone() throws {
    let body = APNsDeviceRequest(token: "ab12", environment: "production", timeZone: "Australia/Sydney")
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: String]
    #expect(json == ["token": "ab12", "environment": "production", "time_zone": "Australia/Sydney"])
}
