import Foundation

public struct NeptuneSourceStats: Codable, Equatable {
    public let source: String
    public let tokens: Int64
    public let sessions: Int
    public let score: Double?
    public init(source: String, tokens: Int64, sessions: Int, score: Double?) {
        self.source = source; self.tokens = tokens; self.sessions = sessions; self.score = score
    }
}

public struct NeptuneMonthlyStats: Codable {
    public let month: String
    public let updated: Date
    public let apps: [NeptuneSourceStats]
    public let periodStart: String?
    public let periodEnd: String?
    public init(month: String, updated: Date = Date(), apps: [NeptuneSourceStats], periodStart: String? = nil, periodEnd: String? = nil) {
        self.month = month; self.updated = updated; self.apps = apps
        self.periodStart = periodStart; self.periodEnd = periodEnd
    }
    public static func dateRange(_ date: Date = Date(), timeZone: TimeZone = .current) -> (month: String, start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let end = f.string(from: date)
        return (String(end.prefix(7)), f.string(from: start), end)
    }
    public static func usageRange(_ date: Date = Date(), timeZone: TimeZone = .current) -> (month: String, start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let first = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: date))!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        let end = formatter.string(from: date)
        return (String(end.prefix(7)), formatter.string(from: first), end)
    }
    public func coversUsagePeriod(at date: Date = Date()) -> Bool {
        let range = Self.usageRange(date)
        return periodStart == range.start && periodEnd == range.end
    }
    public func isFresh(at date: Date = Date()) -> Bool {
        month == Self.dateRange(date).month && date.timeIntervalSince(updated) >= -60 && date.timeIntervalSince(updated) < 900
    }
    public var isValid: Bool {
        apps.count == 2 && Set(apps.map(\.source)) == Set(["claude-code", "cursor"]) && apps.allSatisfy {
            $0.tokens >= 0 && $0.sessions >= 0 && ($0.score == nil || ($0.score!.isFinite && (0...100).contains($0.score!)))
        }
    }
    public func app(_ target: String) -> NeptuneSourceStats? {
        apps.first { $0.source == (target == "claudeCode" ? "claude-code" : target) }
    }
}

public extension NeptuneSourceStats {
    var tokenLabel: String {
        if tokens >= 1_000_000_000 { return String(format: "%.2fB", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fK", Double(tokens) / 1_000) }
        return String(tokens)
    }
    var scoreLabel: String { score.map { "\(Int($0.rounded()))/100 score" } ?? "No score yet" }
}
