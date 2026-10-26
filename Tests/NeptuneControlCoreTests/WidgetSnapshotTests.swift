import XCTest
@testable import NeptuneControlCore

final class WidgetSnapshotTests: XCTestCase {
    func testSnapshotContainsNoAccountDetailsOrHookPayload() throws {
        let snapshot = WidgetSnapshot(apps: [WidgetAppStatus(id: "cursor", title: "Cursor", state: "Allowed for work", allowed: true, needsAttention: false)])
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["version", "updated", "apps"]))
        let row = try XCTUnwrap((json["apps"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(row.keys), Set(["id", "title", "state", "allowed", "needsAttention"]))
    }

    func testSnapshotExpiresRatherThanShowingAnOldPermissionAsCurrent() {
        let date = Date(timeIntervalSince1970: 1000)
        let snapshot = WidgetSnapshot(updated: date, apps: [])
        XCTAssertFalse(snapshot.isStale(at: date.addingTimeInterval(299)))
        XCTAssertTrue(snapshot.isStale(at: date.addingTimeInterval(301)))
    }

    func testCompactStatusDoesNotCallMissingCredentialsAllowed() {
        let status = HookStatus(target: .cursor, registeredHooks: 1, originalScripts: 0,
                                canEnable: true, globallyPaused: false, credentialsPresent: false,
                                issue: nil, account: AccountIdentity(email: "a@spaceinch.com"),
                                armed: true, protectedScripts: 1)
        XCTAssertEqual(status.compactState, "Neptune not connected")
        XCTAssertFalse(status.widgetStatus.allowed)
        XCTAssertTrue(status.widgetStatus.needsAttention)
    }
}
