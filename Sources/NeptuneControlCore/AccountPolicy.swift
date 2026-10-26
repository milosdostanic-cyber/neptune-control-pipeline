import Foundation
import SQLite3

public enum AccountConnection {
    case connected, savedSignIn, unverified, disconnected
    public var label: String {
        switch self {
        case .connected: return "Connected"
        case .savedSignIn: return "Saved sign-in · app closed"
        case .unverified: return "Account not verified"
        case .disconnected: return "Not connected"
        }
    }
}

public struct AccountIdentity {
    public let email: String?
    public let connection: AccountConnection
    public let sessionEmails: [String]
    public let sessionCount: Int
    public let hasUnverifiedSessions: Bool
    public let origin: String?
    public init(email: String?, connection: AccountConnection = .connected, sessionEmails: [String] = [],
                sessionCount: Int = 0, hasUnverifiedSessions: Bool = false, origin: String? = nil) {
        self.email = email
        self.connection = connection
        self.sessionEmails = sessionEmails
        self.sessionCount = sessionCount
        self.hasUnverifiedSessions = hasUnverifiedSessions
        self.origin = origin
    }
    public var emails: [String] { sessionEmails.isEmpty ? email.map { [$0] } ?? [] : sessionEmails }
    public var isSpaceInch: Bool {
        (connection == .connected || connection == .savedSignIn) && emails.contains(where: AccountPolicy.isAllowed)
    }
    public var hasPrivateAccount: Bool { emails.contains { !AccountPolicy.isAllowed($0) } }
    public var label: String { email ?? "No account detected" }
}

public enum AccountPolicy {
    public static let domain = "spaceinch.com"

    public static func isAllowed(_ email: String?) -> Bool {
        guard let email = email, email.utf8.count < 255 else { return false }
        return email.range(of: #"\A[A-Za-z0-9._%+\-]+@spaceinch\.com\z"#, options: .regularExpression) != nil ||
            email.lowercased().range(of: #"\A[A-Za-z0-9._%+\-]+@spaceinch\.com\z"#, options: .regularExpression) != nil
    }

    /// Decisions use identity attached to this hook execution, never the UI's cached email.
    /// Missing, conflicting, non-company or unsupported auth identities always deny collection.
    public static func permits(_ target: HookTarget, payload: Data, environment: [String: String]) -> Bool {
        guard let event = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        if target == .cursor {
            guard let fromEvent = event["user_email"] as? String,
                  let fromProcess = environment["CURSOR_USER_EMAIL"],
                  isAllowed(fromEvent), isAllowed(fromProcess),
                  fromEvent.lowercased() == fromProcess.lowercased() else { return false }
            return true
        }
        guard let email = environment["CLAUDE_CODE_USER_EMAIL"], isAllowed(email),
              let account = environment["CLAUDE_CODE_ACCOUNT_UUID"], !account.isEmpty else { return false }
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            if !(environment[key] ?? "").isEmpty { return false }
        }
        if let other = event["user_email"] as? String, other.lowercased() != email.lowercased() { return false }
        return true
    }
}

public enum AccountIdentityReader {
    /// Presentation only. Hook execution always checks the identity of its own event.
    public static func read(_ target: HookTarget, home: URL, storage: URL? = nil) -> AccountIdentity {
        if target == .claudeCode {
            let path = home.appendingPathComponent(".claude.json")
            let bytes = try? Data(contentsOf: path)
            let json = bytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let cached = (json?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
            // Test homes never inspect real sessions on the user's computer.
            let live = home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                ? LiveSessionReader.claudeSessions(home: home) : []
            let running = home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL && LiveSessionReader.claudeDesktopIsRunning()
            let desktop = ClaudeDesktopIdentity.read(home: home, storage: storage ?? home.appendingPathComponent("Library/Application Support/Neptune Control"), running: running)
            return claudeIdentity(cachedEmail: cached, sessions: live, desktop: desktop)
        }
        let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database = database { sqlite3_close(database) }
            return AccountIdentity(email: nil, connection: .unverified)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 200)
        var statement: OpaquePointer?
        // Check credential presence inside SQLite. Never return or read a token value.
        let query = "SELECT (SELECT value FROM ItemTable WHERE key='cursorAuth/cachedEmail' LIMIT 1), EXISTS(SELECT 1 FROM ItemTable WHERE key='cursorAuth/accessToken' AND length(value)>0)"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return AccountIdentity(email: nil, connection: .unverified) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return AccountIdentity(email: nil, connection: .unverified) }
        let email = sqlite3_column_text(statement, 0).map { String(cString: $0) }
        let hasSignIn = sqlite3_column_int(statement, 1) == 1
        let running = home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL && LiveSessionReader.cursorIsRunning()
        return cursorIdentity(email: email, hasSignIn: hasSignIn, running: running)
    }

    static func claudeIdentity(cachedEmail: String?, sessions: [LiveClaudeSession], desktop: AccountIdentity? = nil) -> AccountIdentity {
        if let desktop, desktop.connection == .connected || desktop.connection == .savedSignIn {
            let emails = Array(Set(desktop.emails + sessions.compactMap(\.email).map { $0.lowercased() })).sorted()
            return AccountIdentity(email: desktop.email, connection: desktop.connection, sessionEmails: emails,
                                   sessionCount: sessions.count, hasUnverifiedSessions: sessions.contains { $0.email == nil }, origin: desktop.origin)
        }
        if let desktop, sessions.isEmpty || sessions.allSatisfy({ $0.email == nil }) {
            return AccountIdentity(email: desktop.email, connection: desktop.connection, sessionCount: sessions.count,
                                   hasUnverifiedSessions: !sessions.isEmpty, origin: desktop.origin)
        }
        guard !sessions.isEmpty else { return AccountIdentity(email: cachedEmail, connection: .disconnected) }
        let emails = Array(Set(sessions.compactMap(\.email).map { $0.lowercased() })).sorted()
        return AccountIdentity(email: emails.first ?? cachedEmail, connection: emails.isEmpty ? .unverified : .connected,
                               sessionEmails: emails, sessionCount: sessions.count,
                               hasUnverifiedSessions: sessions.contains { $0.email == nil })
    }

    static func cursorIdentity(email: String?, hasSignIn: Bool, running: Bool) -> AccountIdentity {
        let connection: AccountConnection = hasSignIn && email != nil ? (running ? .connected : .savedSignIn) : .disconnected
        return AccountIdentity(email: email, connection: connection)
    }
}
