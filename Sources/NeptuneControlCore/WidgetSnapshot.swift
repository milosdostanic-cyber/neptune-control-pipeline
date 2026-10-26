import Foundation
import Darwin

/// A deliberately small, credential-free view of status for the sandboxed widget.
public struct WidgetAppStatus: Codable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let state: String
    public let allowed: Bool
    public let needsAttention: Bool
    public init(id: String, title: String, state: String, allowed: Bool, needsAttention: Bool) {
        self.id = id; self.title = title; self.state = state
        self.allowed = allowed; self.needsAttention = needsAttention
    }
}

public struct WidgetSnapshot: Codable {
    public let version: Int
    public let updated: Date
    public let apps: [WidgetAppStatus]
    public let stats: NeptuneMonthlyStats?
    public init(updated: Date = Date(), apps: [WidgetAppStatus], stats: NeptuneMonthlyStats? = nil) {
        version = 1; self.updated = updated; self.apps = apps; self.stats = stats
    }
    public func isStale(at date: Date) -> Bool { date.timeIntervalSince(updated) > 300 }
    public static var fileURL: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Neptune Control/Widget/status.json")
    }
    public static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let result = try? JSONDecoder().decode(Self.self, from: data),
              result.version == 1, result.apps.count == 2,
              Set(result.apps.map(\.id)) == Set(["claudeCode", "cursor"]) else { return nil }
        return result
    }
}

#if !WIDGET_EXTENSION
public extension HookStatus {
    var compactState: String {
        if issue != nil { return "Check settings" }
        if originalScripts > 0 { return "Protection needed" }
        if !configured && !canEnable { return "Neptune setup needed" }
        if !armed { return "Off" }
        if !account.isSpaceInch {
            if account.hasPrivateAccount { return "Personal account blocked" }
            return account.connection == .disconnected ? "Not connected" : "Account not verified"
        }
        if globallyPaused { return "Paused in Neptune" }
        if !credentialsPresent { return "Neptune not connected" }
        if registeredHooks == 0 { return "Setup needed" }
        return account.connection == .savedSignIn ? "Ready when connected" : "Ready to sync"
    }
    var widgetStatus: WidgetAppStatus {
        WidgetAppStatus(id: target.rawValue, title: target.title, state: compactState,
                        allowed: enabled, needsAttention: issue != nil || originalScripts > 0 || (armed && account.isSpaceInch && (!credentialsPresent || registeredHooks == 0)))
    }
}
#endif
