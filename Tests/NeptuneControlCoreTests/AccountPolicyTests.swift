import XCTest
@testable import NeptuneControlCore

final class AccountPolicyTests: XCTestCase {
    func testOnlyExactCompanyDomainIsAllowed() {
        for email in ["a@spaceinch.com", "Team.Member@SPACEINCH.COM"] { XCTAssertTrue(AccountPolicy.isAllowed(email)) }
        for email in ["a@gmail.com", "a@evilspaceinch.com", "a@spaceinch.com.evil", "a@sub.spaceinch.com", "@spaceinch.com", "a@spaceinch.com\n", " a@spaceinch.com", ""] {
            XCTAssertFalse(AccountPolicy.isAllowed(email), email)
        }
        XCTAssertFalse(AccountPolicy.isAllowed(nil))
    }

    func testCursorRequiresMatchingEventAndProcessIdentity() {
        let company = Data(#"{"user_email":"a@spaceinch.com","prompt":"test"}"#.utf8)
        XCTAssertTrue(AccountPolicy.permits(.cursor, payload: company, environment: ["CURSOR_USER_EMAIL": "a@spaceinch.com"]))
        XCTAssertFalse(AccountPolicy.permits(.cursor, payload: company, environment: [:]))
        XCTAssertFalse(AccountPolicy.permits(.cursor, payload: company, environment: ["CURSOR_USER_EMAIL": "a@gmail.com"]))
        XCTAssertFalse(AccountPolicy.permits(.cursor, payload: company, environment: ["CURSOR_USER_EMAIL": "b@spaceinch.com"]))
        XCTAssertFalse(AccountPolicy.permits(.cursor, payload: Data("{}".utf8), environment: ["CURSOR_USER_EMAIL": "a@spaceinch.com"]))
        XCTAssertFalse(AccountPolicy.permits(.cursor, payload: Data("invalid".utf8), environment: ["CURSOR_USER_EMAIL": "a@spaceinch.com"]))
    }

    func testPrivateCursorEventIsBlockedEvenWhenOtherIdentitySaysCompany() {
        XCTAssertFalse(AccountPolicy.permits(.cursor, payload: Data(#"{"user_email":"a@gmail.com"}"#.utf8), environment: ["CURSOR_USER_EMAIL": "a@spaceinch.com"]))
        XCTAssertFalse(AccountPolicy.permits(.cursor, payload: Data(#"{"user_email":null}"#.utf8), environment: ["CURSOR_USER_EMAIL": "a@spaceinch.com"]))
    }

    func testClaudeRequiresSessionEmailAndAccountID() {
        let input = Data("{}".utf8)
        XCTAssertTrue(AccountPolicy.permits(.claudeCode, payload: input, environment: ["CLAUDE_CODE_USER_EMAIL": "a@spaceinch.com", "CLAUDE_CODE_ACCOUNT_UUID": "company-session"]))
        XCTAssertFalse(AccountPolicy.permits(.claudeCode, payload: input, environment: ["CLAUDE_CODE_USER_EMAIL": "a@spaceinch.com"]))
        XCTAssertFalse(AccountPolicy.permits(.claudeCode, payload: input, environment: ["CLAUDE_CODE_USER_EMAIL": "a@gmail.com", "CLAUDE_CODE_ACCOUNT_UUID": "private-session"]))
        XCTAssertFalse(AccountPolicy.permits(.claudeCode, payload: input, environment: [:]))
        // Cursor identity must never substitute for a different Claude account.
        XCTAssertFalse(AccountPolicy.permits(.claudeCode, payload: input, environment: ["CURSOR_USER_EMAIL": "a@spaceinch.com"]))
    }

    func testUnsupportedClaudeAuthOverridesFailClosed() {
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"] {
            XCTAssertFalse(AccountPolicy.permits(.claudeCode, payload: Data("{}".utf8), environment: ["CLAUDE_CODE_USER_EMAIL": "a@spaceinch.com", "CLAUDE_CODE_ACCOUNT_UUID": "company", key: "present"]))
        }
        XCTAssertFalse(AccountPolicy.permits(.claudeCode, payload: Data(#"{"user_email":"a@gmail.com"}"#.utf8), environment: ["CLAUDE_CODE_USER_EMAIL": "a@spaceinch.com", "CLAUDE_CODE_ACCOUNT_UUID": "company"]))
    }
}

final class GuardedRunnerTests: XCTestCase {
    var home: URL!
    var controller: HookController!
    var marker: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NeptuneGuardTests-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        controller = HookController(home: home, identityProvider: { _ in AccountIdentity(email: "a@spaceinch.com") })
        marker = home.appendingPathComponent("harmless-test-script-ran")
        let root = controller.scriptsURL(.claudeCode)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("UserPromptSubmit.sh")
        // A local sentinel replaces Neptune entirely. No network or real credentials are used.
        try Data("#!/bin/bash\n/bin/cat >/dev/null\n/usr/bin/touch '\(marker.path)'\n".utf8).write(to: path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        let json: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": path.path]]]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: controller.configURL(.claudeCode))
    }

    override func tearDownWithError() throws { try fm.removeItem(at: home) }

    private var company: [String: String] { ["CLAUDE_CODE_USER_EMAIL": "a@spaceinch.com", "CLAUDE_CODE_ACCOUNT_UUID": "company"] }

    private func run(_ environment: [String: String]) -> Int32 {
        controller.runGuardedHook(target: .claudeCode, script: "UserPromptSubmit.sh", payload: Data("{}".utf8), environment: environment)
    }

    func testPrivateAndUnknownCannotExecuteOriginalEvenWithStaleCompanyUICache() throws {
        try controller.setEnabled(true, for: .claudeCode)
        XCTAssertEqual(run(["CLAUDE_CODE_USER_EMAIL": "a@gmail.com", "CLAUDE_CODE_ACCOUNT_UUID": "private"]), 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
        XCTAssertEqual(run([:]), 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testCompanyCanExecuteOnlyWhileArmed() throws {
        try controller.setEnabled(true, for: .claudeCode)
        XCTAssertEqual(run(company), 0)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        try fm.removeItem(at: marker)
        try controller.setEnabled(false, for: .claudeCode)
        XCTAssertEqual(run(company), 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testAccountSwitchIsCheckedOnEveryInvocation() throws {
        try controller.setEnabled(true, for: .claudeCode)
        XCTAssertEqual(run(company), 0)
        try fm.removeItem(at: marker)
        XCTAssertEqual(run(["CLAUDE_CODE_USER_EMAIL": "a@gmail.com", "CLAUDE_CODE_ACCOUNT_UUID": "private"]), 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
        XCTAssertEqual(run(company), 0)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
    }

    func testMissingOrInvalidPolicyBlocksCollection() throws {
        try controller.setEnabled(true, for: .claudeCode)
        try Data("invalid".utf8).write(to: controller.storage.appendingPathComponent("Policy.json"))
        XCTAssertEqual(run(company), 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testModifiedOriginalIsNeverExecuted() throws {
        try controller.setEnabled(true, for: .claudeCode)
        try Data("#!/bin/bash\n/usr/bin/touch '\(marker.path)'\n# changed\n".utf8).write(to: controller.storage.appendingPathComponent("Originals/claudeCode/UserPromptSubmit.sh"))
        XCTAssertEqual(run(company), 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testPrivateAndUnknownEnableRequestsMakeNoChanges() throws {
        let before = try Data(contentsOf: controller.configURL(.claudeCode))
        for email in ["a@gmail.com", nil] {
            let privateController = HookController(home: home, identityProvider: { _ in AccountIdentity(email: email) })
            XCTAssertThrowsError(try privateController.setEnabled(true, for: .claudeCode))
        }
        XCTAssertEqual(try Data(contentsOf: controller.configURL(.claudeCode)), before)
        XCTAssertFalse(fm.fileExists(atPath: controller.storage.path))
    }

    func testAutomaticStartupArmsGuardButKeepsPersonalCollectionOff() throws {
        let privateController = HookController(home: home, identityProvider: { _ in AccountIdentity(email: "a@gmail.com") })
        try privateController.prepareProtection()
        XCTAssertEqual(privateController.status(.claudeCode).registeredHooks, 1)
        XCTAssertTrue(privateController.isArmed(.claudeCode))
        XCTAssertFalse(privateController.status(.claudeCode).enabled)
        XCTAssertEqual(privateController.runGuardedHook(target: .claudeCode, script: "UserPromptSubmit.sh", payload: Data("{}".utf8), environment: ["CLAUDE_CODE_USER_EMAIL": "a@gmail.com", "CLAUDE_CODE_ACCOUNT_UUID": "personal"]), 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
        // A later company session works without opening the UI or changing a switch.
        XCTAssertEqual(privateController.runGuardedHook(target: .claudeCode, script: "UserPromptSubmit.sh", payload: Data("{}".utf8), environment: company), 0)
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
    }

    func testManualOffSurvivesAutomaticModeRestart() throws {
        try controller.prepareProtection()
        try controller.setEnabled(false, for: .claudeCode)
        try controller.prepareProtection()
        XCTAssertFalse(controller.isArmed(.claudeCode))
        XCTAssertEqual(controller.status(.claudeCode).registeredHooks, 0)
        XCTAssertEqual(run(company), 0)
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testBusinessPayloadAndEnvironmentAreForwardedUnchangedForBothTargets() throws {
        for target in HookTarget.allCases {
            let name = target == .cursor ? "beforeSubmitPrompt.sh" : "UserPromptSubmit.sh"
            let script = controller.scriptsURL(target).appendingPathComponent(name)
            let capture = home.appendingPathComponent(target.rawValue + "-input")
            let envCapture = home.appendingPathComponent(target.rawValue + "-env")
            try fm.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data("#!/bin/bash\n/bin/cat > '\(capture.path)'\n/usr/bin/printf '%s' \"$FORWARDING_SENTINEL\" > '\(envCapture.path)'\n".utf8)
            try bytes.write(to: script)
            let entry: [String: Any] = target == .cursor ? ["command": script.path] : ["hooks": [["type": "command", "command": script.path]]]
            let config: [String: Any] = ["hooks": [String(name.dropLast(3)): [entry]]]
            try JSONSerialization.data(withJSONObject: config).write(to: controller.configURL(target))
            try controller.setEnabled(true, for: target)
            let payload = Data("{\n  \"user_email\": \"a@spaceinch.com\", \"prompt\": \"exact bytes \\u2603\", \"other\": [1,2,3]\n}\n".utf8)
            var environment = target == .cursor ? ["CURSOR_USER_EMAIL": "a@spaceinch.com"] : company
            environment["FORWARDING_SENTINEL"] = "same environment value"
            XCTAssertEqual(controller.runGuardedHook(target: target, script: name, payload: payload, environment: environment), 0)
            XCTAssertEqual(try Data(contentsOf: capture), payload)
            XCTAssertEqual(try String(contentsOf: envCapture), "same environment value")
            XCTAssertEqual(try Data(contentsOf: controller.storage.appendingPathComponent("Originals/\(target.rawValue)/\(name)")), bytes)
            try fm.removeItem(at: capture)
            // A private identity must not reach the original, even with a company payload.
            environment[target == .cursor ? "CURSOR_USER_EMAIL" : "CLAUDE_CODE_USER_EMAIL"] = "a@gmail.com"
            XCTAssertEqual(controller.runGuardedHook(target: target, script: name, payload: payload, environment: environment), 0)
            XCTAssertFalse(fm.fileExists(atPath: capture.path))
        }
    }

    func testCompetingInstallerLocksEnableAndDisablesExistingHooks() throws {
        let extensionPath = home.appendingPathComponent(".cursor/extensions/on-neptune.neptune-hooks-9.9.9")
        try fm.createDirectory(at: extensionPath, withIntermediateDirectories: true)
        XCTAssertThrowsError(try controller.setEnabled(true, for: .claudeCode))
        XCTAssertThrowsError(try controller.prepareProtection())
        XCTAssertEqual(controller.status(.claudeCode).registeredHooks, 0)
        XCTAssertFalse(controller.isArmed(.claudeCode))
    }
}
