import XCTest
@testable import NeptuneControlCore

final class ActivityLogTests: XCTestCase {
    var storage: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        storage = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NeptuneActivityTests-" + UUID().uuidString)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: storage) }

    func testSummaryCountsOutcomesPerAppForTheDay() {
        let log = ActivityLog(storage: storage)
        let now = Date()
        log.record(.claudeCode, .sent, at: now.addingTimeInterval(-120))
        log.record(.claudeCode, .sent, at: now.addingTimeInterval(-30))
        log.record(.claudeCode, .failed, at: now)
        log.record(.claudeCode, .blocked(.personalAccount), at: now)
        log.record(.claudeCode, .blocked(.personalAccount), at: now)
        log.record(.cursor, .blocked(.unverified), at: now)
        let summary = log.summary(on: now)
        XCTAssertEqual(summary[.claudeCode]?.sent, 2)
        XCTAssertEqual(summary[.claudeCode]?.failed, 1)
        XCTAssertEqual(summary[.claudeCode]?.blocked, [.personalAccount: 2])
        XCTAssertEqual(summary[.claudeCode]?.lastSent.map { Int($0.timeIntervalSince1970) }, Int(now.addingTimeInterval(-30).timeIntervalSince1970))
        XCTAssertEqual(summary[.cursor]?.blockedTotal, 1)
        XCTAssertNil(summary[.cursor]?.lastSent)
    }

    func testOtherDaysAndMalformedLinesAreIgnored() throws {
        let log = ActivityLog(storage: storage)
        let now = Date()
        log.record(.claudeCode, .sent, at: now.addingTimeInterval(-2 * 86_400))
        log.record(.claudeCode, .sent, at: now)
        let handle = try FileHandle(forWritingTo: log.fileURL(for: now))
        handle.seekToEndOfFile()
        handle.write(Data("garbage\n1\tclaudeCode\tblocked:unknown\n1\tother\tsent\n".utf8))
        try handle.close()
        XCTAssertEqual(log.summary(on: now)[.claudeCode]?.total, 1)
    }

    func testLogHoldsNoIdentityOrPayloadAndIsPrivate() throws {
        let log = ActivityLog(storage: storage)
        log.record(.cursor, .blocked(.accountMismatch))
        let file = log.fileURL(for: Date())
        let text = try String(contentsOf: file)
        XCTAssertFalse(text.contains("@"))
        XCTAssertEqual(text.split(separator: "\t").count, 3)
        XCTAssertEqual((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPruneRemovesOnlyFilesOlderThanRetention() {
        let log = ActivityLog(storage: storage)
        let now = Date()
        let old = now.addingTimeInterval(-Double(ActivityLog.retentionDays + 2) * 86_400)
        log.record(.claudeCode, .sent, at: old)
        log.record(.claudeCode, .sent, at: now)
        log.prune(now: now)
        XCTAssertFalse(fm.fileExists(atPath: log.fileURL(for: old).path))
        XCTAssertTrue(fm.fileExists(atPath: log.fileURL(for: now).path))
    }

    func testDenialReasonsMatchPermits() {
        let company = ["CLAUDE_CODE_USER_EMAIL": "a@spaceinch.com", "CLAUDE_CODE_ACCOUNT_UUID": "company"]
        let empty = Data("{}".utf8)
        XCTAssertNil(AccountPolicy.denial(.claudeCode, payload: empty, environment: company))
        XCTAssertEqual(AccountPolicy.denial(.claudeCode, payload: empty, environment: [:]), .unverified)
        XCTAssertEqual(AccountPolicy.denial(.claudeCode, payload: empty, environment: ["CLAUDE_CODE_USER_EMAIL": "a@spaceinch.com"]), .unverified)
        XCTAssertEqual(AccountPolicy.denial(.claudeCode, payload: empty, environment: ["CLAUDE_CODE_USER_EMAIL": "a@gmail.com", "CLAUDE_CODE_ACCOUNT_UUID": "x"]), .personalAccount)
        XCTAssertEqual(AccountPolicy.denial(.claudeCode, payload: empty, environment: company.merging(["ANTHROPIC_API_KEY": "x"]) { $1 }), .unsupportedLogin)
        XCTAssertEqual(AccountPolicy.denial(.claudeCode, payload: Data(#"{"user_email":"b@spaceinch.com"}"#.utf8), environment: company), .accountMismatch)
        XCTAssertEqual(AccountPolicy.denial(.claudeCode, payload: Data("invalid".utf8), environment: company), .unverified)
        let cursorEvent = Data(#"{"user_email":"a@spaceinch.com"}"#.utf8)
        XCTAssertNil(AccountPolicy.denial(.cursor, payload: cursorEvent, environment: ["CURSOR_USER_EMAIL": "a@spaceinch.com"]))
        XCTAssertEqual(AccountPolicy.denial(.cursor, payload: cursorEvent, environment: [:]), .unverified)
        XCTAssertEqual(AccountPolicy.denial(.cursor, payload: cursorEvent, environment: ["CURSOR_USER_EMAIL": "a@gmail.com"]), .personalAccount)
        XCTAssertEqual(AccountPolicy.denial(.cursor, payload: cursorEvent, environment: ["CURSOR_USER_EMAIL": "b@spaceinch.com"]), .accountMismatch)
    }
}

final class GuardedRunnerActivityTests: XCTestCase {
    func testGuardRecordsSentBlockedAndIntegrityOutcomes() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NeptuneGuardActivity-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let controller = HookController(home: home, identityProvider: { _ in AccountIdentity(email: "a@spaceinch.com") })
        let root = controller.scriptsURL(.claudeCode)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("UserPromptSubmit.sh")
        try Data("#!/bin/bash\n/bin/cat >/dev/null\n".utf8).write(to: path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let json: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": path.path]]]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: controller.configURL(.claudeCode))
        try controller.setEnabled(true, for: .claudeCode)

        let company = ["CLAUDE_CODE_USER_EMAIL": "a@spaceinch.com", "CLAUDE_CODE_ACCOUNT_UUID": "company"]
        let run = { (environment: [String: String]) in
            _ = controller.runGuardedHook(target: .claudeCode, script: "UserPromptSubmit.sh", payload: Data("{}".utf8), environment: environment)
        }
        run(company)
        run(["CLAUDE_CODE_USER_EMAIL": "a@gmail.com", "CLAUDE_CODE_ACCOUNT_UUID": "private"])
        run([:])
        try Data("#!/bin/bash\n# changed\n".utf8).write(to: controller.storage.appendingPathComponent("Originals/claudeCode/UserPromptSubmit.sh"))
        run(company)

        let summary = ActivityLog(storage: controller.storage).summary()[.claudeCode]
        XCTAssertEqual(summary?.sent, 1)
        XCTAssertNotNil(summary?.lastSent)
        XCTAssertEqual(summary?.blocked, [.personalAccount: 1, .unverified: 1, .integrity: 1])
    }
}
