import XCTest
@testable import NeptuneControlCore

final class NeptuneMonthlyStatsTests: XCTestCase {
    func testDailyStatsExpireAndCannotCarryYesterdayIntoToday() {
        let now = ISO8601DateFormatter().date(from: "2026-10-26T10:00:00Z")!
        let stats = NeptuneMonthlyStats(month: "2026-10", updated: now, apps: [])
        XCTAssertTrue(stats.isFresh(at: now.addingTimeInterval(899)))
        XCTAssertFalse(stats.isFresh(at: now.addingTimeInterval(901)))
        XCTAssertFalse(stats.isFresh(at: now.addingTimeInterval(86400)))
        XCTAssertFalse(stats.isFresh(at: now.addingTimeInterval(-61)))
    }
    func testMonthlyRangeUsesTheInstallingUsersTimezone() {
        let date = ISO8601DateFormatter().date(from: "2026-11-01T00:30:00Z")!
        let west = NeptuneMonthlyStats.dateRange(date, timeZone: TimeZone(secondsFromGMT: -7200)!)
        let east = NeptuneMonthlyStats.dateRange(date, timeZone: TimeZone(secondsFromGMT: 3600)!)
        XCTAssertEqual(west.month, "2026-10")
        XCTAssertEqual(west.start, "2026-10-01")
        XCTAssertEqual(west.end, "2026-10-31")
        XCTAssertEqual(east.month, "2026-11")
        XCTAssertEqual(east.start, "2026-11-01")
    }
    func testRollingUsageRangeIncludesThirtyCalendarDaysAcrossDST() {
        let date = ISO8601DateFormatter().date(from: "2026-10-26T10:00:00Z")!
        let range = NeptuneMonthlyStats.usageRange(date, timeZone: TimeZone(identifier: "Europe/Belgrade")!)
        XCTAssertEqual(range.start, "2026-09-27")
        XCTAssertEqual(range.end, "2026-10-26")
        let oldMonthly = NeptuneMonthlyStats(month: range.month, updated: date, apps: [])
        XCTAssertFalse(oldMonthly.coversUsagePeriod(at: date))
        let rolling = NeptuneMonthlyStats(month: range.month, updated: date, apps: [], periodStart: range.start, periodEnd: range.end)
        XCTAssertTrue(rolling.coversUsagePeriod(at: date))
        XCTAssertFalse(rolling.coversUsagePeriod(at: date.addingTimeInterval(86400)))
    }
    func testRollingUsageRangeUsesLocalDayAtMonthBoundary() {
        let date = ISO8601DateFormatter().date(from: "2026-11-01T00:30:00Z")!
        let west = NeptuneMonthlyStats.usageRange(date, timeZone: TimeZone(secondsFromGMT: -7200)!)
        let east = NeptuneMonthlyStats.usageRange(date, timeZone: TimeZone(secondsFromGMT: 3600)!)
        XCTAssertEqual(west.start, "2026-10-02")
        XCTAssertEqual(west.end, "2026-10-31")
        XCTAssertEqual(east.start, "2026-10-03")
        XCTAssertEqual(east.end, "2026-11-01")
    }
    func testMissingAndZeroScoreAreDistinct() {
        let zero = NeptuneSourceStats(source: "cursor", tokens: 0, sessions: 1, score: 0)
        let unknown = NeptuneSourceStats(source: "claude-code", tokens: 0, sessions: 0, score: nil)
        XCTAssertEqual(zero.scoreLabel, "0/100 score")
        XCTAssertEqual(unknown.scoreLabel, "No score yet")
        XCTAssertTrue(NeptuneMonthlyStats(month: "2026-10", apps: [zero, unknown]).isValid)
    }
    func testInvalidSourcesAndNegativeCountsAreRejected() {
        let valid = NeptuneSourceStats(source: "cursor", tokens: 0, sessions: 0, score: nil)
        let invalid = NeptuneSourceStats(source: "claude-code", tokens: -1, sessions: 1, score: 101)
        XCTAssertFalse(NeptuneMonthlyStats(month: "2026-10", apps: [valid, invalid]).isValid)
        XCTAssertFalse(NeptuneMonthlyStats(month: "2026-10", apps: [valid, valid]).isValid)
    }
}
