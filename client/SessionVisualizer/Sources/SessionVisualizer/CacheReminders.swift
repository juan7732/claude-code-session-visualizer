import Foundation
import Observation
import SkitKit
import UserNotifications

/// Reminders before a session's prompt cache expires: for each session whose
/// bell is on, one notification when the cache has a few minutes left
/// (Settings › General › Now), so the session can be picked up before its next
/// prompt pays for the whole context again.
///
/// The engine says when a cache expires; this only keeps one pending
/// notification per session in step with that moment, which moves every time
/// the session makes a request.
@Observable
final class CacheReminders {
    /// Sessions whose bell is on.
    private(set) var sessions: Set<String>
    /// What is scheduled now: the moment each session's reminder fires.
    private(set) var scheduled: [String: Date] = [:]
    /// The system said no to notifications; the bell still marks the card.
    private(set) var denied = false
    /// Sessions already told about, by the expiry they were told of.
    private var told: [String: Date] = [:]

    /// A notification needs an application bundle: run from the build
    /// directory there is none, and asking the system then is fatal.
    nonisolated static let available = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil

    init() {
        sessions = Snapshot.keepsNothing ? [] : Set(UserDefaults.standard.stringArray(forKey: SettingsKey.nowReminders) ?? [])
    }

    /// Minutes before the end at which to tell.
    static var lead: Int {
        let minutes = UserDefaults.standard.integer(forKey: SettingsKey.nowReminderMinutes)
        return minutes > 0 ? minutes : 5
    }

    func isOn(_ id: String) -> Bool { sessions.contains(id) }

    func toggle(_ session: NowReport.Session, now: Date = Date()) {
        if sessions.contains(session.id) {
            sessions.remove(session.id)
            cancel(session.id)
        } else {
            sessions.insert(session.id)
            if Self.available {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in self.denied = !granted }
                }
            }
            schedule(session, now: now)
        }
        save()
    }

    /// Brings the pending notifications in step with what the engine just said.
    func sync(_ report: NowReport, now: Date = Date()) {
        let listed = Set(report.sessions.map(\.id))
        // A session that left the window is done with: its cache is long gone.
        let left = sessions.subtracting(listed)
        for id in left {
            sessions.remove(id)
            cancel(id)
        }
        if !left.isEmpty { save() }
        for session in report.sessions where sessions.contains(session.id) { schedule(session, now: now) }
    }

    /// When the reminder for a cache that ends at `expires` is due, and whether that is still ahead.
    nonisolated static func plan(expires: Date, lead minutes: Int, now: Date) -> (fire: Date, state: Plan) {
        let fire = expires.addingTimeInterval(-Double(minutes) * 60)
        if expires <= now { return (fire, .gone) }
        return (fire, fire > now ? .ahead : .due)
    }

    enum Plan: Equatable { case ahead, due, gone }

    private func schedule(_ session: NowReport.Session, now: Date) {
        guard let expires = session.cache?.expiresAt else { return cancel(session.id) }
        let plan = Self.plan(expires: expires, lead: Self.lead, now: now)
        switch plan.state {
        case .gone:
            cancel(session.id)
        case .due:
            // Already inside the last minutes: tell once for this end.
            guard told[session.id] != expires else { return }
            told[session.id] = expires
            scheduled[session.id] = nil
            post(session, expires: expires, after: nil)
        case .ahead:
            guard scheduled[session.id] != plan.fire else { return }
            scheduled[session.id] = plan.fire
            told[session.id] = nil
            post(session, expires: expires, after: plan.fire.timeIntervalSince(now))
        }
    }

    private func cancel(_ id: String) {
        scheduled[id] = nil
        told[id] = nil
        guard Self.available else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.identifier(id)])
    }

    nonisolated static func identifier(_ id: String) -> String { "cache-" + id }

    /// One request per session: adding one with the same identifier replaces the one pending.
    private func post(_ session: NowReport.Session, expires: Date, after seconds: TimeInterval?) {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        let text = Self.words(session, expires: expires, lead: Self.lead, early: seconds == nil)
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        content.sound = .default
        content.userInfo = ["session": session.id]
        let trigger = seconds.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.identifier(session.id), content: content, trigger: trigger))
    }

    /// What the notification says.
    nonisolated static func words(_ session: NowReport.Session, expires: Date, lead: Int, early: Bool) -> (title: String, subtitle: String, body: String) {
        let clock = expires.formatted(date: .omitted, time: .shortened)
        let title = early ? "Prompt cache expires at \(clock)" : "Prompt cache expires in \(lead) minutes"
        let name = session.title.flatMap { $0.isEmpty ? nil : $0 } ?? Format.shortID(session.id)
        var body = "After \(clock) its next prompt pays for the whole context again"
        if let tokens = session.cache?.contextTokens, tokens > 0 { body += " (\(Format.tokens(tokens)) tokens)" }
        return (title, name, body + ".")
    }

    private func save() {
        guard !Snapshot.keepsNothing else { return }
        UserDefaults.standard.set(sessions.sorted(), forKey: SettingsKey.nowReminders)
    }
}

/// Shows a reminder even while the app is in front, where the system would otherwise keep it quiet.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
