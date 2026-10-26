import Foundation
import SQLite3

struct ClaudeAccountBinding: Codable {
    let accountUUID: String
    let email: String
}

/// Claude desktop and the terminal have separate sign-ins. Desktop persists its active
/// account UUID even before it starts a Code worker. Email bindings are local identity
/// metadata verified in Claude's account menu; they never authorize a hook invocation.
enum ClaudeDesktopIdentity {
    static func read(home: URL, storage: URL, running: Bool) -> AccountIdentity? {
        let root = home.appendingPathComponent("Library/Application Support/Claude")
        guard let data = try? Data(contentsOf: root.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = config["lastKnownAccountUuid"] as? String, UUID(uuidString: uuid) != nil else { return nil }
        let bindingsData = try? Data(contentsOf: storage.appendingPathComponent("ClaudeAccountBindings.json"))
        let bindings = bindingsData.flatMap { try? JSONDecoder().decode([ClaudeAccountBinding].self, from: $0) } ?? []
        let cachedData = try? Data(contentsOf: home.appendingPathComponent(".claude.json"))
        let cached = cachedData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let oauth = cached?["oauthAccount"] as? [String: Any]
        let cachedUUID = oauth?["accountUuid"] as? String
        let cachedEmail = oauth?["emailAddress"] as? String
        let email = bindings.first { $0.accountUUID.lowercased() == uuid.lowercased() }?.email ??
            (cachedUUID?.lowercased() == uuid.lowercased() ? cachedEmail : nil)
        let signedIn = hasSessionCookie(root.appendingPathComponent("Cookies"))
        return identity(email: email, signedIn: signedIn, running: running)
    }

    static func identity(email: String?, signedIn: Bool, running: Bool) -> AccountIdentity {
        let connection: AccountConnection
        if !signedIn { connection = .disconnected }
        else if email == nil { connection = .unverified }
        else { connection = running ? .connected : .savedSignIn }
        return AccountIdentity(email: email, connection: connection, origin: "Claude desktop")
    }

    private static func hasSessionCookie(_ path: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(path.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return false
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        var statement: OpaquePointer?
        // Read only presence and expiry. No cookie or credential value leaves SQLite.
        let query = "SELECT EXISTS(SELECT 1 FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name='sessionKey' AND (length(value)>0 OR length(encrypted_value)>0) AND (expires_utc=0 OR expires_utc>?))"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        let chromeNow = Int64((Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        sqlite3_bind_int64(statement, 1, chromeNow)
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 1
    }
}
