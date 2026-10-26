import XCTest
import SQLite3
@testable import NeptuneControlCore

final class AccountIdentityTests: XCTestCase {
    func testCachedClaudeEmailNeverClaimsConnectedOrAllowsCollection() {
        let identity = AccountIdentityReader.claudeIdentity(cachedEmail: "a@spaceinch.com", sessions: [])
        XCTAssertEqual(identity.email, "a@spaceinch.com")
        XCTAssertEqual(identity.connection, .disconnected)
        XCTAssertFalse(identity.isSpaceInch)
    }

    func testLiveClaudePersonalAccountOverridesStaleBusinessCache() {
        let identity = AccountIdentityReader.claudeIdentity(cachedEmail: "a@spaceinch.com", sessions: [.init(email: "a@gmail.com")])
        XCTAssertEqual(identity.connection, .connected)
        XCTAssertEqual(identity.emails, ["a@gmail.com"])
        XCTAssertFalse(identity.isSpaceInch)
        XCTAssertTrue(identity.hasPrivateAccount)
    }

    func testUnidentifiedLiveClaudeCannotBorrowCachedIdentity() {
        let identity = AccountIdentityReader.claudeIdentity(cachedEmail: "a@spaceinch.com", sessions: [.init(email: nil)])
        XCTAssertEqual(identity.connection, .unverified)
        XCTAssertTrue(identity.hasUnverifiedSessions)
        XCTAssertFalse(identity.isSpaceInch)
    }

    func testMultipleClaudeAccountsStayVisibleAndSeparate() {
        let identity = AccountIdentityReader.claudeIdentity(cachedEmail: nil, sessions: [.init(email: "a@gmail.com"), .init(email: "b@spaceinch.com"), .init(email: nil)])
        XCTAssertEqual(identity.sessionCount, 3)
        XCTAssertEqual(identity.emails, ["a@gmail.com", "b@spaceinch.com"])
        XCTAssertTrue(identity.isSpaceInch)
        XCTAssertTrue(identity.hasPrivateAccount)
        XCTAssertTrue(identity.hasUnverifiedSessions)
    }

    func testCursorSignOutOverridesStaleEmail() {
        let identity = AccountIdentityReader.cursorIdentity(email: "a@spaceinch.com", hasSignIn: false, running: true)
        XCTAssertEqual(identity.connection, .disconnected)
        XCTAssertFalse(identity.isSpaceInch)
        XCTAssertEqual(AccountIdentityReader.cursorIdentity(email: "a@spaceinch.com", hasSignIn: true, running: true).connection, .connected)
        XCTAssertEqual(AccountIdentityReader.cursorIdentity(email: "a@spaceinch.com", hasSignIn: true, running: false).connection, .savedSignIn)
    }

    func testProcessIdentityParserReturnsOnlyWhitelistedMetadata() {
        var data = Data([2, 0, 0, 0])
        data.append(Data("/binary\0\0/binary\0private argument\0CLAUDE_CODE_USER_EMAIL=a@gmail.com\0CLAUDE_CODE_ACCOUNT_UUID=test-account\0CLAUDE_CODE_OAUTH_TOKEN=DO_NOT_RETURN\0PROMPT=DO_NOT_RETURN\0\0".utf8))
        XCTAssertEqual(LiveSessionReader.identity(fromProcessArguments: data), ["CLAUDE_CODE_USER_EMAIL": "a@gmail.com", "CLAUDE_CODE_ACCOUNT_UUID": "test-account"])
        XCTAssertTrue(LiveSessionReader.identity(fromProcessArguments: Data([1, 2])).isEmpty)
    }

    func testCursorReaderUsesCredentialPresenceAndDoesNotTreatCacheAsSignIn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT UNIQUE, value TEXT); INSERT INTO ItemTable VALUES('cursorAuth/cachedEmail','a@spaceinch.com');", nil, nil, nil), SQLITE_OK)
        XCTAssertFalse(AccountIdentityReader.read(.cursor, home: home).isSpaceInch)
        XCTAssertEqual(sqlite3_exec(database, "INSERT INTO ItemTable VALUES('cursorAuth/accessToken','FAKE_TEST_CREDENTIAL');", nil, nil, nil), SQLITE_OK)
        let identity = AccountIdentityReader.read(.cursor, home: home)
        XCTAssertEqual(identity.email, "a@spaceinch.com")
        XCTAssertEqual(identity.connection, .savedSignIn)
    }
}
