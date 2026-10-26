import XCTest
@testable import NeptuneControlCore

final class HookControllerTests: XCTestCase {
    var home: URL!
    var controller: HookController!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NeptuneControlTests-" + UUID().uuidString)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        controller = HookController(home: home, identityProvider: { _ in AccountIdentity(email: "test@spaceinch.com") })
        try put(Data("NEPTUNE_API_KEY=FAKE_TEST_KEY\nNEPTUNE_API_URL=https://example.invalid\n".utf8), at: home.appendingPathComponent(".neptune/.env"))
    }

    override func tearDownWithError() throws {
        if let home = home { try fm.removeItem(at: home) }
    }

    private func put(_ data: Data, at url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func json(_ object: [String: Any], at url: URL) throws {
        try put(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), at: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @discardableResult
    private func install(_ target: HookTarget, extra: Bool = false) throws -> Data {
        let name = target == .claudeCode ? "UserPromptSubmit" : "beforeSubmitPrompt"
        let script = controller.scriptsURL(target).appendingPathComponent(name + ".sh")
        let bytes = Data(("#!/bin/bash\n# neptune-hooks:test\n# Original fixture; never execute during tests.\nexit 99\nprintf '{\"continue\":true}\\n'\n").utf8)
        try put(bytes, at: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let neptune: [String: Any] = ["type": "command", "command": script.path, "async": true]
        let unrelated: [String: Any] = ["type": "command", "command": "/usr/bin/true", "timeout": 5]
        var hooks: [String: Any]
        if target == .claudeCode {
            hooks = [name: [["matcher": "Read|Write", "hooks": extra ? [neptune, unrelated] : [neptune]]]]
        } else {
            hooks = [name: extra ? [["command": script.path], ["command": "/usr/bin/true", "timeout": 5]] : [["command": script.path]]]
        }
        var config: [String: Any] = ["hooks": hooks, "customSetting": ["keep": true, "value": "unchanged"]]
        if target == .cursor { config["version"] = 1 }
        else { config["enabledPlugins"] = ["figma": true] }
        try json(config, at: controller.configURL(target))
        return bytes
    }

    func testClaudeDisablePreservesMixedHookAndSettings() throws {
        try install(.claudeCode, extra: true)
        try controller.setEnabled(false, for: .claudeCode)
        let config = try read(controller.configURL(.claudeCode))
        XCTAssertEqual((config["enabledPlugins"] as? [String: Bool])?["figma"], true)
        XCTAssertEqual((config["customSetting"] as? [String: Any])?["value"] as? String, "unchanged")
        let events = try XCTUnwrap(config["hooks"] as? [String: [[String: Any]]])
        let group = try XCTUnwrap(events["UserPromptSubmit"]?.first)
        XCTAssertEqual(group["matcher"] as? String, "Read|Write")
        let handlers = try XCTUnwrap(group["hooks"] as? [[String: Any]])
        XCTAssertEqual(handlers.count, 1)
        XCTAssertEqual(handlers.first?["command"] as? String, "/usr/bin/true")
        XCTAssertFalse(controller.status(.claudeCode).enabled)
    }

    func testEnableMergesWithSettingsEditedWhileOffAndDoesNotDuplicate() throws {
        let original = try install(.claudeCode, extra: true)
        try controller.setEnabled(false, for: .claudeCode)
        var config = try read(controller.configURL(.claudeCode))
        config["newSetting"] = "added while off"
        try json(config, at: controller.configURL(.claudeCode))
        try controller.setEnabled(true, for: .claudeCode)
        try controller.setEnabled(true, for: .claudeCode)
        let restored = try read(controller.configURL(.claudeCode))
        XCTAssertEqual(restored["newSetting"] as? String, "added while off")
        XCTAssertEqual(controller.status(.claudeCode).registeredHooks, 1)
        XCTAssertTrue(try String(contentsOf: controller.scriptsURL(.claudeCode).appendingPathComponent("UserPromptSubmit.sh")).contains("NEPTUNE_CONTROL_ACCOUNT_GUARD"))
        XCTAssertEqual(try Data(contentsOf: controller.storage.appendingPathComponent("Originals/claudeCode/UserPromptSubmit.sh")), original)
    }

    func testCursorDisablePreservesProtocolForCachedSessions() throws {
        try install(.cursor, extra: true)
        try controller.setEnabled(false, for: .cursor)
        let path = controller.scriptsURL(.cursor).appendingPathComponent("beforeSubmitPrompt.sh")
        let text = try String(contentsOf: path)
        XCTAssertFalse(text.contains("curl"))
        XCTAssertFalse(text.contains("NEPTUNE_API_KEY"))
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [path.path]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        task.standardInput = input; task.standardOutput = output; task.standardError = errors
        try task.run()
        input.fileHandleForWriting.write(Data("{}".utf8))
        try input.fileHandleForWriting.close()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "{\"continue\":true}\n")
        XCTAssertTrue(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
        let config = try read(controller.configURL(.cursor))
        XCTAssertEqual(config["version"] as? Int, 1)
        let groups = (config["hooks"] as? [String: [[String: Any]]])?["beforeSubmitPrompt"]
        XCTAssertEqual(groups?.count, 1)
        XCTAssertEqual(groups?.first?["command"] as? String, "/usr/bin/true")
    }

    func testTargetsAndCredentialsRemainIndependent() throws {
        try install(.claudeCode)
        try install(.cursor)
        let cursor = try Data(contentsOf: controller.configURL(.cursor))
        let envPath = home.appendingPathComponent(".neptune/.env")
        let env = try Data(contentsOf: envPath)
        try controller.setEnabled(false, for: .claudeCode)
        XCTAssertEqual(try Data(contentsOf: controller.configURL(.cursor)), cursor)
        XCTAssertEqual(try Data(contentsOf: envPath), env)
        XCTAssertTrue(controller.status(.cursor).configured)
        XCTAssertFalse(controller.status(.claudeCode).enabled)
    }

    func testRecoverOriginalsFromEarlierClaudeBackup() throws {
        let original = try install(.claudeCode)
        let old = home.appendingPathComponent(".claude/backups/neptune-disabled-20261026T090031Z")
        try put(try Data(contentsOf: controller.configURL(.claudeCode)), at: old.appendingPathComponent("settings.json"))
        try put(original, at: old.appendingPathComponent("original-neptune-scripts/UserPromptSubmit.sh"))
        try json(["enabledPlugins": ["keep": true], "model": "private-choice"], at: controller.configURL(.claudeCode))
        try put(Data("#!/bin/bash\n# Neptune collection disabled for Claude Code at the user's request.\nexit 0\n".utf8), at: controller.scriptsURL(.claudeCode).appendingPathComponent("UserPromptSubmit.sh"))
        let status = controller.status(.claudeCode)
        XCTAssertFalse(status.enabled)
        XCTAssertTrue(status.canEnable)
        try controller.setEnabled(true, for: .claudeCode)
        XCTAssertEqual(try read(controller.configURL(.claudeCode))["model"] as? String, "private-choice")
        XCTAssertEqual((try read(controller.configURL(.claudeCode))["enabledPlugins"] as? [String: Bool])?["keep"], true)
        XCTAssertEqual(controller.status(.claudeCode).registeredHooks, 1)
    }

    func testMalformedJSONIsNeverOverwritten() throws {
        try install(.claudeCode)
        let invalid = Data("{unfinished".utf8)
        try put(invalid, at: controller.configURL(.claudeCode))
        XCTAssertThrowsError(try controller.setEnabled(false, for: .claudeCode))
        XCTAssertEqual(try Data(contentsOf: controller.configURL(.claudeCode)), invalid)
        XCTAssertFalse(fm.fileExists(atPath: controller.backupsURL.path))
        XCTAssertNotNil(controller.status(.claudeCode).issue)
    }

    func testInvalidHookShapeIsNeverOverwritten() throws {
        try json(["hooks": ["UserPromptSubmit": "unexpected"]], at: controller.configURL(.claudeCode))
        let before = try Data(contentsOf: controller.configURL(.claudeCode))
        XCTAssertThrowsError(try controller.setEnabled(false, for: .claudeCode))
        XCTAssertEqual(try Data(contentsOf: controller.configURL(.claudeCode)), before)
    }

    func testSymlinkConfigurationIsRejectedWithoutChangingDestination() throws {
        let destination = home.appendingPathComponent("elsewhere.json")
        try json(["private": true], at: destination)
        try fm.createDirectory(at: controller.configURL(.claudeCode).deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: controller.configURL(.claudeCode), withDestinationURL: destination)
        let before = try Data(contentsOf: destination)
        XCTAssertThrowsError(try controller.setEnabled(false, for: .claudeCode))
        XCTAssertEqual(try Data(contentsOf: destination), before)
    }

    func testSymlinkScriptIsRejected() throws {
        try install(.cursor)
        let link = controller.scriptsURL(.cursor).appendingPathComponent("outside.sh")
        try fm.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("elsewhere.sh"))
        let before = try Data(contentsOf: controller.configURL(.cursor))
        XCTAssertThrowsError(try controller.setEnabled(false, for: .cursor))
        XCTAssertEqual(try Data(contentsOf: controller.configURL(.cursor)), before)
    }

    func testGlobalPauseIsReadAndPreserved() throws {
        try install(.cursor)
        let envPath = home.appendingPathComponent(".neptune/.env")
        var env = try Data(contentsOf: envPath)
        env.append(Data("NEPTUNE_PAUSED=true\n".utf8))
        try put(env, at: envPath)
        try controller.prepareProtection()
        XCTAssertEqual(controller.status(.cursor).title, "Collection paused in Neptune")
        try controller.setEnabled(false, for: .cursor)
        try controller.setEnabled(true, for: .cursor)
        XCTAssertEqual(try Data(contentsOf: envPath), env)
        XCTAssertEqual(controller.status(.cursor).title, "Collection paused in Neptune")
    }

    func testStatusRefreshIsReadOnly() throws {
        try install(.claudeCode)
        let before = try Data(contentsOf: controller.configURL(.claudeCode))
        let script = try Data(contentsOf: controller.scriptsURL(.claudeCode).appendingPathComponent("UserPromptSubmit.sh"))
        _ = controller.statuses()
        _ = controller.statuses()
        XCTAssertFalse(fm.fileExists(atPath: controller.storage.path))
        XCTAssertEqual(try Data(contentsOf: controller.configURL(.claudeCode)), before)
        XCTAssertEqual(try Data(contentsOf: controller.scriptsURL(.claudeCode).appendingPathComponent("UserPromptSubmit.sh")), script)
    }

    func testBackupContainsOriginalsAndSnapshotPermissionsArePrivate() throws {
        let original = try install(.cursor)
        let config = try Data(contentsOf: controller.configURL(.cursor))
        let change = try controller.setEnabled(false, for: .cursor)
        let backup = try XCTUnwrap(change.backup)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("configuration.json")), config)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("scripts/beforeSubmitPrompt.sh")), original)
        let saved = controller.storage.appendingPathComponent("Snapshots/cursor.json")
        let permissions = try fm.attributesOfItem(atPath: saved.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try controller.setEnabled(true, for: .cursor)
        let restoredMode = try fm.attributesOfItem(atPath: controller.scriptsURL(.cursor).appendingPathComponent("beforeSubmitPrompt.sh").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(restoredMode?.intValue, 0o700)
    }

    func testRepeatedDisableDoesNotOverwriteRestorePoint() throws {
        try install(.claudeCode)
        try controller.setEnabled(false, for: .claudeCode)
        let snapshot = controller.storage.appendingPathComponent("Snapshots/claudeCode.json")
        let before = try Data(contentsOf: snapshot)
        let second = try controller.setEnabled(false, for: .claudeCode)
        XCTAssertNil(second.backup)
        XCTAssertEqual(try Data(contentsOf: snapshot), before)
        try controller.setEnabled(true, for: .claudeCode)
        XCTAssertTrue(controller.status(.claudeCode).enabled)
    }

    func testTamperedSnapshotCannotWriteOutsideScriptDirectory() throws {
        try install(.cursor)
        try controller.setEnabled(false, for: .cursor)
        let path = controller.storage.appendingPathComponent("Snapshots/cursor.json")
        var snapshot = try read(path)
        var files = try XCTUnwrap(snapshot["scripts"] as? [[String: Any]])
        files[0]["path"] = "../../../outside.sh"
        snapshot["scripts"] = files
        try json(snapshot, at: path)
        let before = try Data(contentsOf: controller.configURL(.cursor))
        XCTAssertThrowsError(try controller.setEnabled(true, for: .cursor))
        XCTAssertEqual(try Data(contentsOf: controller.configURL(.cursor)), before)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent("outside.sh").path))
    }

    func testMissingOriginalScriptCannotBeEnabled() throws {
        try install(.claudeCode)
        try fm.removeItem(at: controller.scriptsURL(.claudeCode).appendingPathComponent("UserPromptSubmit.sh"))
        XCTAssertFalse(controller.status(.claudeCode).canEnable)
        XCTAssertThrowsError(try controller.setEnabled(true, for: .claudeCode))
        try controller.setEnabled(false, for: .claudeCode)
        XCTAssertFalse(controller.status(.claudeCode).enabled)
    }

    func testNoInstalledHooksCannotBeEnabledOrModified() throws {
        let status = controller.status(.claudeCode)
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(status.canEnable)
        XCTAssertThrowsError(try controller.setEnabled(true, for: .claudeCode))
        XCTAssertNil(try controller.setEnabled(false, for: .claudeCode).backup)
        XCTAssertFalse(fm.fileExists(atPath: controller.configURL(.claudeCode).path))
    }
}
