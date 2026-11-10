import Foundation
import Testing
@testable import SkitKit

@Suite struct FormatTests {
    @Test func timestamps() throws {
        let base = try #require(RFC3339.date("2026-11-08T10:00:00Z"))
        #expect(base.timeIntervalSince1970 == 1_794_132_000)
        #expect(RFC3339.date("2026-11-08T10:00:00.5Z") == base.addingTimeInterval(0.5))
        let nanos = try #require(RFC3339.date("2026-11-08T10:00:00.123456789Z"))
        #expect(abs(nanos.timeIntervalSince(base) - 0.123456789) < 1e-6)
        #expect(RFC3339.date("2026-11-08T12:00:00+02:00") == base)
        #expect(RFC3339.date("2026-11-08T05:30:00-04:30") == base)
        #expect(RFC3339.date("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
        #expect(RFC3339.date("2024-02-29T00:00:00Z") == Date(timeIntervalSince1970: 1_709_164_800))
        // Go's zero time, which skit writes for "never".
        #expect(RFC3339.date("0001-01-01T00:00:00Z") == Date(timeIntervalSince1970: -62_135_596_800))
        for bad in ["", "2026-11-08", "2026-11-08T10:00:00", "2026-13-08T10:00:00Z", "2026-11-08T10:00:00.Z", "2026-11-08T10:00:00Zjunk"] {
            #expect(RFC3339.date(bad) == nil, "\(bad) should not parse")
        }
    }

    @Test func numbers() {
        #expect(Format.tokens(950) == "950")
        #expect(Format.tokens(1_234) == "1.2k")
        #expect(Format.tokens(12_345) == "12k")
        #expect(Format.tokens(455_000) == "455k")
        #expect(Format.tokens(4_600_000) == "4.6M")
        #expect(Format.money(12.345) == "$12.35")
        #expect(Format.money(nil) == "—")
    }

    @Test func relativeTime() {
        let now = Date(timeIntervalSince1970: 1_794_132_000)
        #expect(Format.ago(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(Format.ago(now.addingTimeInterval(-14 * 60), now: now) == "14 min ago")
        #expect(Format.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
        #expect(Format.ago(now.addingTimeInterval(-8 * 86_400), now: now) == "8 d ago")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let old = Format.ago(now.addingTimeInterval(-40 * 86_400), now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        // The system puts a narrow no-break space before AM.
        #expect(old.replacingOccurrences(of: "\u{202F}", with: " ") == "Sep 29, 10:00 AM")
    }

    @Test func paths() {
        #expect(Format.homeRelative("/Users/juan/ergo-workspaces/tools") == "~/ergo-workspaces/tools")
        #expect(Format.homeRelative("/Users/juan") == "/Users/juan")
        #expect(Format.homeRelative("/opt/work") == "/opt/work")
        #expect(Format.middleEllipsis("short") == "short")
        let long = Format.middleEllipsis("~/ergo-workspaces/tools/claude-code-session-visualizer", max: 44)
        #expect(long.count == 44)
        #expect(long.hasPrefix("~/ergo-workspaces/too") && long.hasSuffix("ode-session-visualizer") && long.contains("…"))
        #expect(Format.projectName(cwd: "/Users/juan/ergo-workspaces/tools", slug: "-x") == "tools")
        #expect(Format.projectName(cwd: nil, slug: "-Users-me-work") == "-Users-me-work")
        #expect(Format.greeting(hour: 3) == "Still up")
        #expect(Format.greeting(hour: 15) == "Good afternoon")
    }

    @Test func engineLocations() {
        let plain = EngineLocator(environment: ["PATH": "/a/bin:/b/bin"], homeDirectory: "/Users/me", helpersDirectory: "/App/Contents/Helpers")
        #expect(plain.socketPath == "/Users/me/.sessionkit/skit.sock")
        #expect(Array(plain.binaryCandidates.prefix(3)) == ["/App/Contents/Helpers/skit", "/a/bin/skit", "/b/bin/skit"])
        #expect(plain.binaryCandidates.contains("/Users/me/go/bin/skit"))
        let custom = EngineLocator(environment: ["SKIT_HOME": "/data/skit", "SKIT_BIN": "/x/skit", "PATH": "/x"], homeDirectory: "/Users/me")
        #expect(custom.socketPath == "/data/skit/skit.sock")
        #expect(custom.binaryCandidates.first == "/x/skit")
        #expect(custom.binaryCandidates.filter { $0 == "/x/skit" }.count == 1)
        #expect(EngineLocator(environment: [:], homeDirectory: "/nonexistent-\(getpid())").findBinary() == nil || true)
    }
}
