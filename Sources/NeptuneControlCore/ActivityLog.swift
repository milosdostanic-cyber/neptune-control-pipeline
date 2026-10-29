import Foundation
import Darwin

/// Why the guard kept an event from Neptune's original script.
public enum BlockReason: String, CaseIterable, Codable {
    case collectionOff = "off"
    case personalAccount = "personal"
    case unverified
    case unsupportedLogin = "login"
    case accountMismatch = "mismatch"
    case integrity

    public var label: String {
        switch self {
        case .collectionOff: return "collection off"
        case .personalAccount: return "non-company account"
        case .unverified: return "unverified session"
        case .unsupportedLogin: return "API key or cloud login"
        case .accountMismatch: return "account mismatch"
        case .integrity: return "protection check failed"
        }
    }
}

public enum ActivityOutcome: Equatable {
    /// Neptune's original script ran and exited successfully. Server receipt is not confirmed.
    case sent
    /// Neptune's original script ran and exited with an error.
    case failed
    case blocked(BlockReason)

    var code: String {
        switch self {
        case .sent: return "sent"
        case .failed: return "failed"
        case .blocked(let reason): return "blocked:" + reason.rawValue
        }
    }

    init?(code: Substring) {
        switch code {
        case "sent": self = .sent
        case "failed": self = .failed
        default:
            guard code.hasPrefix("blocked:"), let reason = BlockReason(rawValue: String(code.dropFirst(8))) else { return nil }
            self = .blocked(reason)
        }
    }
}

public struct ActivitySummary: Equatable {
    public var sent = 0
    public var failed = 0
    public var blocked: [BlockReason: Int] = [:]
    public var lastSent: Date?
    public init() {}
    public var blockedTotal: Int { blocked.values.reduce(0, +) }
    public var total: Int { sent + failed + blockedTotal }
}

/// A per-day local record of guard decisions: time, app and outcome only.
/// Payloads, prompts, emails and environment values are never written.
public struct ActivityLog: Sendable {
    public let directory: URL
    public static let retentionDays = 7

    public init(storage: URL) {
        directory = storage.appendingPathComponent("Activity")
    }

    /// Never throws: a logging failure must not change what the hook does.
    public func record(_ target: HookTarget, _ outcome: ActivityOutcome, at date: Date = Date()) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let line = "\(Int(date.timeIntervalSince1970))\t\(target.rawValue)\t\(outcome.code)\n"
        let descriptor = open(fileURL(for: date).path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        // One short O_APPEND write keeps lines intact when hooks from several sessions record at once.
        _ = line.utf8CString.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count - 1) }
    }

    public func summary(on day: Date = Date()) -> [HookTarget: ActivitySummary] {
        var result: [HookTarget: ActivitySummary] = [:]
        guard let text = try? String(contentsOf: fileURL(for: day), encoding: .utf8) else { return result }
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, let seconds = TimeInterval(fields[0]),
                  let target = HookTarget(rawValue: String(fields[1])), let outcome = ActivityOutcome(code: fields[2]) else { continue }
            var item = result[target] ?? ActivitySummary()
            switch outcome {
            case .sent:
                item.sent += 1
                let date = Date(timeIntervalSince1970: seconds)
                if item.lastSent.map({ date > $0 }) ?? true { item.lastSent = date }
            case .failed: item.failed += 1
            case .blocked(let reason): item.blocked[reason, default: 0] += 1
            }
            result[target] = item
        }
        return result
    }

    public func prune(now: Date = Date()) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Calendar.current.startOfDay(for: now)) ?? now
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "log" {
            if let day = Self.dayFormatter.date(from: file.deletingPathExtension().lastPathComponent), day < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func fileURL(for date: Date) -> URL {
        directory.appendingPathComponent(Self.dayFormatter.string(from: date) + ".log")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
