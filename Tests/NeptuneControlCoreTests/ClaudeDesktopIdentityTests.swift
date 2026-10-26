import XCTest
import SQLite3
@testable import NeptuneControlCore

final class ClaudeDesktopIdentityTests: XCTestCase {
    var home: URL!
    var storage: URL!
    let companyUUID = "11111111-1111-4111-8111-111111111111"
    let privateUUID = "22222222-2222-4222-8222-222222222222"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = home.appendingPathComponent("control")
        try put(["oauthAccount": ["accountUuid": privateUUID, "emailAddress": "personal@example.com"]], at: home.appendingPathComponent(".claude.json"))
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try JSONEncoder().encode([ClaudeAccountBinding(accountUUID: companyUUID, email: "work@spaceinch.com")])
            .write(to: storage.appendingPathComponent("ClaudeAccountBindings.json"))
        try setDesktopAccount(companyUUID)
        try cookie()
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    func put(_ json: [String: Any], at path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: path)
    }

    func setDesktopAccount(_ uuid: String) throws {
        try put(["lastKnownAccountUuid": uuid], at: home.appendingPathComponent("Library/Application Support/Claude/config.json"))
    }

    func cookie(expired: Bool = false, host: String = ".claude.ai") throws {
        let path = home.appendingPathComponent("Library/Application Support/Claude/Cookies")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,expires_utc INTEGER); DELETE FROM cookies;", nil, nil, nil), SQLITE_OK)
        let expiry = expired ? "1" : "0"
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO cookies VALUES('\(host)','sessionKey','','FAKE_TEST_CREDENTIAL',\(expiry));", nil, nil, nil), SQLITE_OK)
    }

    func testCompanyDesktopOverridesSeparateStalePrivateTerminalLogin() throws {
        let identity = try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true))
        XCTAssertEqual(identity.email, "work@spaceinch.com")
        XCTAssertEqual(identity.connection, .connected)
        XCTAssertTrue(identity.isSpaceInch)
        XCTAssertEqual(identity.origin, "Claude desktop")
    }

    func testCompanyToPrivateAndBackUpdatesWithoutCodeWorkerOrUIAction() throws {
        XCTAssertTrue(try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true)).isSpaceInch)
        try setDesktopAccount(privateUUID)
        let privateAccount = try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true))
        XCTAssertEqual(privateAccount.email, "personal@example.com")
        XCTAssertEqual(privateAccount.connection, .connected)
        XCTAssertFalse(privateAccount.isSpaceInch)
        try setDesktopAccount(companyUUID)
        XCTAssertTrue(try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true)).isSpaceInch)
    }

    func testUnknownDesktopAccountCannotBorrowVerifiedCompanyEmail() throws {
        try setDesktopAccount("33333333-3333-4333-8333-333333333333")
        let identity = try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true))
        XCTAssertNil(identity.email)
        XCTAssertEqual(identity.connection, .unverified)
        XCTAssertFalse(identity.isSpaceInch)
    }

    func testExpiredMissingOrWrongOriginCookieDoesNotClaimConnected() throws {
        try cookie(expired: true)
        XCTAssertFalse(try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true)).isSpaceInch)
        try cookie(host: ".other.example")
        XCTAssertFalse(try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true)).isSpaceInch)
        try FileManager.default.removeItem(at: home.appendingPathComponent("Library/Application Support/Claude/Cookies"))
        XCTAssertEqual(try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true)).connection, .disconnected)
    }

    func testDesktopCompanyRemainsVisibleAlongsideUnidentifiedTerminalProcesses() throws {
        let desktop = try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true))
        let identity = AccountIdentityReader.claudeIdentity(cachedEmail: "personal@example.com", sessions: [.init(email: nil)], desktop: desktop)
        XCTAssertEqual(identity.email, "work@spaceinch.com")
        XCTAssertTrue(identity.isSpaceInch)
        XCTAssertTrue(identity.hasUnverifiedSessions)
        XCTAssertEqual(identity.emails, ["work@spaceinch.com"])
        // UI identity cannot grant a terminal hook permission without its own account.
        XCTAssertFalse(AccountPolicy.permits(.claudeCode, payload: Data("{}".utf8), environment: [:]))
    }

    func testSeparatePrivateCodeSessionRemainsVisibleAndBlocked() throws {
        let desktop = try XCTUnwrap(ClaudeDesktopIdentity.read(home: home, storage: storage, running: true))
        let identity = AccountIdentityReader.claudeIdentity(cachedEmail: nil, sessions: [.init(email: "personal@example.com")], desktop: desktop)
        XCTAssertTrue(identity.isSpaceInch)
        XCTAssertTrue(identity.hasPrivateAccount)
        XCTAssertEqual(identity.emails, ["personal@example.com", "work@spaceinch.com"])
        XCTAssertFalse(AccountPolicy.permits(.claudeCode, payload: Data("{}".utf8), environment: ["CLAUDE_CODE_USER_EMAIL": "personal@example.com", "CLAUDE_CODE_ACCOUNT_UUID": privateUUID]))
    }
}
