import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The Stats page: the order of its table and the grid of its calendar. Its
/// numbers are the engine's and are checked by the contract tests.
@Suite struct StatsTests {
    static func rows() throws -> [SessionSummary] {
        try JSONDecoder.skit().decode([SessionSummary].self, from: Fixtures.data("sessions.json"))
    }

    @Test func theTableSortsEitherWay() throws {
        let rows = try Self.rows()
        let most = StatsContent.sorted(rows, by: .actions, ascending: false)
        #expect(zip(most, most.dropFirst()).allSatisfy { $0.requests >= $1.requests })
        let least = StatsContent.sorted(rows, by: .actions, ascending: true)
        #expect(zip(least, least.dropFirst()).allSatisfy { $0.requests <= $1.requests })
        let named = StatsContent.sorted(rows, by: .session, ascending: true)
        #expect(zip(named, named.dropFirst()).allSatisfy { $0.title.localizedCaseInsensitiveCompare($1.title) != .orderedDescending })
        // No row is lost or doubled whatever the column.
        for column in StatsColumn.allCases {
            #expect(Set(StatsContent.sorted(rows, by: column, ascending: false).map(\.id)) == Set(rows.map(\.id)))
        }
        #expect(StatsColumn.session.numeric == false && StatsColumn.cost.numeric)
    }

    @Test func theCalendarIsAYearOfWholeWeeks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        // A Tuesday.
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 21)))
        let weeks = StatsContent.weeks(endingAt: today, calendar: calendar)
        #expect(weeks.count == 53 && weeks.allSatisfy { $0.count == 7 })
        // Each column runs Sunday to Saturday; the last one holds today.
        #expect(weeks.allSatisfy { calendar.component(.weekday, from: $0[0]) == 1 && calendar.component(.weekday, from: $0[6]) == 7 })
        let last = try #require(weeks.last)
        #expect(last.map { StatsContent.key($0, calendar: calendar) } == ["2026-11-08", "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14"])
        // Days follow each other without a gap, across the change of clocks in March and November.
        let days = weeks.flatMap { $0 }.map { StatsContent.key($0, calendar: calendar) }
        #expect(Set(days).count == 371 && days == days.sorted())
        // A day's key is the day in the engine's zone, not in UTC: 9 pm in Chicago is already the 11th in UTC.
        #expect(StatsContent.key(today, calendar: calendar) == "2026-11-10")
        #expect(StatsContent.calendar(in: "Nowhere/At_All").timeZone == TimeZone.current)
    }

    @Test func smallNumbers() {
        #expect(StatsContent.median([]) == 0 && StatsContent.median([5]) == 5 && StatsContent.median([9, 1, 4]) == 4)
        #expect(StatsPage.count(1, "session") == "1 session" && StatsPage.count(0, "project") == "0 projects")
        #expect(StatsPage.toolName("mcp__claude_ai_Google_Slides__update_presentation") == "Google Slides · update presentation")
        #expect(StatsPage.toolName("Bash") == "Bash")
    }
}
