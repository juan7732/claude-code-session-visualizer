import Foundation

/// How the client writes numbers, times and paths. The same rules as the mock
/// (`ux-mocks/app.js`), so a view and its reference read alike.
public enum Format {
    /// 950, 1.2k, 12k, 4.6M.
    public static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return String(n)
    }

    /// "$12.34", or a dash when Claude Code recorded no cost.
    public static func money(_ usd: Double?) -> String {
        guard let usd else { return "—" }
        return String(format: "$%.2f", usd)
    }

    /// "just now", "14 min ago", "3 h ago", "8 d ago", then the date.
    public static func ago(_ date: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 120 { return "just now" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min ago" }
        if seconds < 86_400 { return "\(Int((seconds / 3600).rounded())) h ago" }
        if seconds < 86_400 * 30 { return "\(Int((seconds / 86_400).rounded())) d ago" }
        return dateTime(date, calendar: calendar, locale: locale)
    }

    /// "Nov 7, 8:18 PM": the day and the time, never the year (the mock's `fmtDate`).
    public static func dateTime(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return date.formatted(base.month(.abbreviated).day()) + ", " + date.formatted(base.hour().minute())
    }

    /// `/Users/someone/work` → `~/work`.
    public static func homeRelative(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0].isEmpty, parts[1] == "Users" else { return path }
        return "~/" + parts.dropFirst(3).joined(separator: "/")
    }

    /// Shortens in the middle, the way macOS shortens paths: the start and the end both matter.
    public static func middleEllipsis(_ text: String, max: Int = 44) -> String {
        guard text.count > max, max > 2 else { return text }
        let head = (max + 1) / 2 - 1
        let tail = max / 2
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }

    /// The name a project goes by: the last component of the directory Claude Code was started in.
    public static func projectName(cwd: String?, slug: String?) -> String {
        if let cwd, let last = cwd.split(separator: "/").last { return String(last) }
        return slug ?? "unknown"
    }

    /// The first eight characters of a session id.
    public static func shortID(_ id: String) -> String { String(id.prefix(8)) }

    /// "Good morning" by the clock.
    public static func greeting(hour: Int) -> String {
        switch hour {
        case ..<5: "Still up"
        case ..<12: "Good morning"
        case ..<18: "Good afternoon"
        default: "Good evening"
        }
    }
}
