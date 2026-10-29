import Foundation

public enum HookTarget: String, Codable, CaseIterable, Identifiable {
    case claudeCode, cursor
    public var id: String { rawValue }
    public var title: String { self == .claudeCode ? "Claude Code" : "Cursor" }
    public var directory: String { self == .claudeCode ? ".claude" : ".cursor" }
    public var configuration: String { self == .claudeCode ? "settings.json" : "hooks.json" }
}

public struct HookStatus: Identifiable, Equatable {
    public let target: HookTarget
    public let registeredHooks: Int
    public let originalScripts: Int
    public let canEnable: Bool
    public let globallyPaused: Bool
    public let credentialsPresent: Bool
    public let issue: String?
    public let account: AccountIdentity
    public let armed: Bool
    public let protectedScripts: Int
    public var id: HookTarget { target }
    public var configured: Bool { registeredHooks > 0 || originalScripts > 0 || armed }
    public var enabled: Bool { armed && account.isSpaceInch && !globallyPaused && credentialsPresent && issue == nil && originalScripts == 0 && registeredHooks > 0 }
    public var title: String {
        if issue != nil { return "Check settings" }
        if originalScripts > 0 { return "Account protection required" }
        if !account.isSpaceInch {
            if account.hasPrivateAccount && (account.connection == .connected || account.connection == .savedSignIn) { return "Collection blocked · personal account" }
            if account.connection == .disconnected { return "Collection blocked · not connected" }
            return "Collection blocked · account not verified"
        }
        if !armed { return "Collection off" }
        if globallyPaused { return "Collection paused in Neptune" }
        if !credentialsPresent { return "Neptune connection missing" }
        if registeredHooks == 0 { return "Hooks not installed" }
        if account.hasPrivateAccount || account.hasUnverifiedSessions { return "Collection allowed · other sessions blocked" }
        if account.connection == .savedSignIn { return "Collection ready · SpaceInch only" }
        return "Collection allowed · SpaceInch only"
    }
}

public enum HookControlError: LocalizedError {
    case invalid(String), unavailable(String), changed, verification
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail), .unavailable(let detail): return detail
        case .changed: return "Settings changed during the update. Refresh and try again."
        case .verification: return "The change could not be verified. A backup was saved."
        }
    }
}

private struct ScriptRecord: Codable {
    var path: String
    var bytes: Data
    var permissions: Int
}

private struct HookSnapshot: Codable {
    var version = 1
    var target: HookTarget
    var groups: Data
    var scripts: [ScriptRecord]
    var createdAt: Date
}

public struct HookChange {
    public let target: HookTarget
    public let enabled: Bool
    public let backup: URL?
}

/// Owns local hook configuration and the account-checking hook runner.
/// The control UI makes no network requests. Approved events use the saved Neptune scripts.
/// All stored properties are immutable; the app serializes calls on one background queue.
public final class HookController: @unchecked Sendable {
    public let home: URL
    public let storage: URL
    private let fm = FileManager.default
    private let marker = "NEPTUNE_CONTROL_DISABLED"
    private let guardMarker = "NEPTUNE_CONTROL_ACCOUNT_GUARD"
    public let runnerExecutable: URL
    private let identityProvider: ((HookTarget) -> AccountIdentity)?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, storage: URL? = nil,
                runnerExecutable: URL? = nil, identityProvider: ((HookTarget) -> AccountIdentity)? = nil) {
        self.home = home.standardizedFileURL
        self.storage = storage ?? home.appendingPathComponent("Library/Application Support/Neptune Control")
        self.runnerExecutable = runnerExecutable ?? Bundle.main.executableURL ?? URL(fileURLWithPath: "/nonexistent/NeptuneControl")
        self.identityProvider = identityProvider
    }

    public func configURL(_ target: HookTarget) -> URL {
        home.appendingPathComponent(target.directory).appendingPathComponent(target.configuration)
    }

    public func scriptsURL(_ target: HookTarget) -> URL {
        home.appendingPathComponent(target.directory).appendingPathComponent("hooks/neptune")
    }

    public var backupsURL: URL { storage.appendingPathComponent("Backups") }

    public var competingInstallerPresent: Bool {
        let root = home.appendingPathComponent(".cursor/extensions")
        let paths = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return paths.contains { $0.lastPathComponent.hasPrefix("on-neptune.neptune-hooks-") }
    }

    public func statuses() -> [HookStatus] { HookTarget.allCases.map(status) }

    public func status(_ target: HookTarget) -> HookStatus {
        let account = identityProvider?(target) ?? AccountIdentityReader.read(target, home: home, storage: storage)
        do {
            let config = try readConfiguration(configURL(target))
            let groups = try extractNeptuneGroups(config, target: target)
            let files = try readScripts(scriptsURL(target))
            let originals = files.filter { $0.path.hasSuffix(".sh") && !isDisabled($0.bytes) && !isGuarded($0.bytes) }.count
            let protected = files.filter { $0.path.hasSuffix(".sh") && isGuarded($0.bytes) }.count
            let environment = readEnvironment()
            let available = (try? findSnapshot(target, currentConfig: config, currentScripts: files)) != nil
            return HookStatus(target: target, registeredHooks: count(groups, target: target),
                              originalScripts: originals, canEnable: available,
                              globallyPaused: environment.paused, credentialsPresent: environment.configured, issue: nil,
                              account: account, armed: isArmed(target), protectedScripts: protected)
        } catch {
            return HookStatus(target: target, registeredHooks: 0, originalScripts: 0, canEnable: false,
                              globallyPaused: false, credentialsPresent: false, issue: error.localizedDescription,
                              account: account, armed: false, protectedScripts: 0)
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, for target: HookTarget) throws -> HookChange {
        try configure(enabled, for: target, requireCompanyAccount: true)
    }

    @discardableResult
    private func configure(_ enabled: Bool, for target: HookTarget, requireCompanyAccount: Bool) throws -> HookChange {
        let configPath = configURL(target)
        let scriptRoot = scriptsURL(target)
        try ensureNotSymlink(configPath)
        let previousData = try dataIfPresent(configPath)
        var config = try readConfiguration(configPath)
        let currentScripts = try readScripts(scriptRoot)
        let currentGroups = try extractNeptuneGroups(config, target: target)
        let priorSnapshot = try? findSnapshot(target, currentConfig: config, currentScripts: currentScripts)

        if enabled {
            guard !competingInstallerPresent else { throw HookControlError.unavailable("The Neptune Hooks extension can overwrite account protection. Remove it from Cursor before enabling collection.") }
            let account = identityProvider?(target) ?? AccountIdentityReader.read(target, home: home, storage: storage)
            guard !requireCompanyAccount || account.isSpaceInch else { throw HookControlError.unavailable("Collection can only be enabled for a confirmed @spaceinch.com account. Personal and unverified accounts are blocked.") }
        }

        if !enabled && count(currentGroups, target: target) == 0 &&
            currentScripts.allSatisfy({ !$0.path.hasSuffix(".sh") || isDisabled($0.bytes) }) {
            if isArmed(target) { try setArmed(false, target: target) }
            return HookChange(target: target, enabled: false, backup: nil)
        }

        let snapshot: HookSnapshot?
        if enabled {
            guard let saved = priorSnapshot else {
                throw HookControlError.unavailable("No original hooks were saved for \(target.title). Restore a Neptune backup before enabling collection.")
            }
            try validate(saved, target: target)
            snapshot = saved
        } else {
            snapshot = priorSnapshot
        }

        let backup = try makeBackup(target: target, config: previousData, scripts: currentScripts)
        if let saved = snapshot { try saveSnapshot(saved) }
        try setArmed(false, target: target)

        // Compare before editing; an unrelated external settings change must never be overwritten.
        guard try dataIfPresent(configPath) == previousData else { throw HookControlError.changed }
        if enabled, let saved = snapshot {
            do {
                for file in saved.scripts {
                    try write(file.bytes, to: safeChild(file.path, in: originalsURL(target)), permissions: file.permissions)
                    if file.path.hasSuffix(".sh") {
                        try write(guardedScript(target: target, file: file), to: safeChild(file.path, in: scriptRoot), permissions: file.permissions)
                    }
                }
                let groups = try decodeDictionary(saved.groups)
                config = try merging(groups, into: config, target: target)
                guard try dataIfPresent(configPath) == previousData else { throw HookControlError.changed }
                try writeConfiguration(config, to: configPath)
                try setArmed(true, target: target)
            } catch {
                // On an enable failure, put scripts back into their previous local state.
                // Keep a concurrently edited configuration; never overwrite it with stale data.
                for file in currentScripts {
                    try? write(file.bytes, to: safeChild(file.path, in: scriptRoot), permissions: file.permissions)
                }
                try? setArmed(false, target: target)
                let oldPaths = Set(currentScripts.map(\.path))
                for file in saved.scripts where !oldPaths.contains(file.path) {
                    // Leave new paths harmless rather than deleting files after a failed enable.
                    try? write(disabledScript(for: target, original: file), to: safeChild(file.path, in: scriptRoot), permissions: file.permissions)
                }
                throw error
            }
        } else {
            // Disable the executable paths first, so already-open AI sessions cannot use cached hooks.
            // A later error leaves these paths disabled, rather than resuming collection.
            for file in currentScripts where file.path.hasSuffix(".sh") {
                let original = snapshot?.scripts.first(where: { $0.path == file.path }) ?? file
                try write(disabledScript(for: target, original: original), to: safeChild(file.path, in: scriptRoot), permissions: file.permissions)
            }
            config = try merging([:], into: config, target: target)
            guard try dataIfPresent(configPath) == previousData else { throw HookControlError.changed }
            try writeConfiguration(config, to: configPath)
        }

        let verifiedConfig = try readConfiguration(configPath)
        let verifiedGroups = try extractNeptuneGroups(verifiedConfig, target: target)
        let verifiedScripts = try readScripts(scriptRoot)
        if enabled {
            guard count(verifiedGroups, target: target) > 0, let saved = snapshot else { throw HookControlError.verification }
            for file in saved.scripts {
                guard try Data(contentsOf: safeChild(file.path, in: originalsURL(target))) == file.bytes else { throw HookControlError.verification }
                if file.path.hasSuffix(".sh") {
                    guard try Data(contentsOf: safeChild(file.path, in: scriptRoot)) == guardedScript(target: target, file: file) else { throw HookControlError.verification }
                }
            }
        } else {
            guard count(verifiedGroups, target: target) == 0,
                  verifiedScripts.filter({ $0.path.hasSuffix(".sh") }).allSatisfy({ isDisabled($0.bytes) }) else {
                throw HookControlError.verification
            }
        }
        return HookChange(target: target, enabled: enabled, backup: backup)
    }

    private func readEnvironment() -> (paused: Bool, configured: Bool) {
        guard let text = try? String(contentsOf: home.appendingPathComponent(".neptune/.env"), encoding: .utf8) else { return (false, false) }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let split = line.firstIndex(of: "=") else { continue }
            values[String(line[..<split])] = String(line[line.index(after: split)...])
        }
        return (values["NEPTUNE_PAUSED"] == "true", !(values["NEPTUNE_API_KEY"] ?? "").isEmpty && !(values["NEPTUNE_API_URL"] ?? "").isEmpty)
    }

    private func isNeptune(_ handler: [String: Any], target: HookTarget) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        let normalized = command.replacingOccurrences(of: "\\", with: "/")
        return normalized.contains("\(target.directory)/hooks/neptune/")
    }

    private func extractNeptuneGroups(_ config: [String: Any], target: HookTarget) throws -> [String: Any] {
        guard let raw = config["hooks"] else { return [:] }
        guard let events = raw as? [String: Any] else { throw HookControlError.invalid("The hooks field has an unexpected format. The file was not changed.") }
        var result: [String: Any] = [:]
        for (event, value) in events {
            guard let groups = value as? [[String: Any]] else { throw HookControlError.invalid("The \(event) event has an unexpected format. The file was not changed.") }
            var selected: [[String: Any]] = []
            for var group in groups {
                if target == .cursor {
                    if isNeptune(group, target: target) { selected.append(group) }
                } else {
                    guard let handlers = group["hooks"] as? [[String: Any]] else { throw HookControlError.invalid("A Claude hook has an unexpected format. The file was not changed.") }
                    let neptune = handlers.filter { isNeptune($0, target: target) }
                    if !neptune.isEmpty { group["hooks"] = neptune; selected.append(group) }
                }
            }
            if !selected.isEmpty { result[event] = selected }
        }
        return result
    }

    private func merging(_ saved: [String: Any], into config: [String: Any], target: HookTarget) throws -> [String: Any] {
        var result = config
        var events = (config["hooks"] as? [String: Any]) ?? [:]
        for (event, value) in events {
            guard let groups = value as? [[String: Any]] else { throw HookControlError.invalid("Unexpected hook format. The file was not changed.") }
            var others: [[String: Any]] = []
            for var group in groups {
                if target == .cursor {
                    if !isNeptune(group, target: target) { others.append(group) }
                } else {
                    guard let handlers = group["hooks"] as? [[String: Any]] else { throw HookControlError.invalid("Unexpected Claude hook format. The file was not changed.") }
                    let remaining = handlers.filter { !isNeptune($0, target: target) }
                    if !remaining.isEmpty { group["hooks"] = remaining; others.append(group) }
                }
            }
            if others.isEmpty { events.removeValue(forKey: event) } else { events[event] = others }
        }
        for (event, value) in saved {
            guard let groups = value as? [[String: Any]] else { throw HookControlError.invalid("The hook backup is invalid.") }
            events[event] = groups + ((events[event] as? [[String: Any]]) ?? [])
        }
        if events.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = events }
        return result
    }

    private func count(_ groups: [String: Any], target: HookTarget) -> Int {
        groups.values.reduce(0) { total, value in
            guard let entries = value as? [[String: Any]] else { return total }
            if target == .cursor { return total + entries.count }
            return total + entries.reduce(0) { $0 + (($1["hooks"] as? [Any])?.count ?? 0) }
        }
    }

    private func makeSnapshot(_ target: HookTarget, config: [String: Any], scripts: [ScriptRecord]) throws -> HookSnapshot {
        let groups = try extractNeptuneGroups(config, target: target)
        guard count(groups, target: target) > 0 else { throw HookControlError.unavailable("No Neptune hooks were saved.") }
        let snapshot = HookSnapshot(target: target, groups: try encodeDictionary(groups), scripts: scripts, createdAt: Date())
        try validate(snapshot, target: target)
        return snapshot
    }

    private func findSnapshot(_ target: HookTarget, currentConfig: [String: Any], currentScripts: [ScriptRecord]) throws -> HookSnapshot {
        if let current = try? makeSnapshot(target, config: currentConfig, scripts: currentScripts) { return current }
        let savedPath = storage.appendingPathComponent("Snapshots/\(target.rawValue).json")
        if let data = try? Data(contentsOf: savedPath), let saved = try? JSONDecoder().decode(HookSnapshot.self, from: data) {
            try validate(saved, target: target)
            return saved
        }
        // Recover the Claude originals saved when collection was disabled before this app existed.
        if target == .claudeCode {
            let root = home.appendingPathComponent(".claude/backups")
            let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for folder in folders.filter({ $0.lastPathComponent.hasPrefix("neptune-disabled-") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                if let config = try? readConfiguration(folder.appendingPathComponent("settings.json")),
                   let scripts = try? readScripts(folder.appendingPathComponent("original-neptune-scripts")),
                   let snapshot = try? makeSnapshot(target, config: config, scripts: scripts) { return snapshot }
            }
        }
        throw HookControlError.unavailable("No original hooks were saved for \(target.title).")
    }

    private func validate(_ snapshot: HookSnapshot, target: HookTarget) throws {
        guard snapshot.version == 1, snapshot.target == target else { throw HookControlError.invalid("The backup belongs to another application or version.") }
        let groups = try decodeDictionary(snapshot.groups)
        guard count(groups, target: target) > 0 else { throw HookControlError.invalid("The backup contains no Neptune hooks.") }
        let names = Set(snapshot.scripts.map(\.path))
        guard names.count == snapshot.scripts.count else { throw HookControlError.invalid("The backup contains a duplicate path.") }
        for file in snapshot.scripts { _ = try safeChild(file.path, in: scriptsURL(target)) }
        for value in groups.values {
            guard let entries = value as? [[String: Any]] else { throw HookControlError.invalid("The hook backup is invalid.") }
            for entry in entries {
                let handlers = target == .cursor ? [entry] : (entry["hooks"] as? [[String: Any]] ?? [])
                for handler in handlers {
                    guard isNeptune(handler, target: target), let command = handler["command"] as? String else { throw HookControlError.invalid("The backup contains a hook that does not belong to Neptune.") }
                    // Existing Neptune installers use an absolute, unadorned script path.
                    let url = URL(fileURLWithPath: command)
                    guard url.deletingLastPathComponent().standardizedFileURL == scriptsURL(target).standardizedFileURL,
                          let script = snapshot.scripts.first(where: { $0.path == url.lastPathComponent }),
                          !isDisabled(script.bytes), !isGuarded(script.bytes), names.contains(url.lastPathComponent) else {
                        throw HookControlError.invalid("An original Neptune script is missing or has an unexpected path.")
                    }
                }
            }
        }
    }

    private func isDisabled(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.contains(marker) || text.contains("Neptune collection disabled for Claude Code at the user's request.")
    }

    private func isGuarded(_ data: Data) -> Bool { String(decoding: data, as: UTF8.self).contains(guardMarker) }

    private func originalsURL(_ target: HookTarget) -> URL { storage.appendingPathComponent("Originals/\(target.rawValue)") }

    private func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    private func guardedScript(target: HookTarget, file: ScriptRecord) -> Data {
        Data("#!/bin/bash\n# \(guardMarker): fail closed unless this event identifies a SpaceInch account.\nexec \(shellQuote(runnerExecutable.path)) --run-hook \(shellQuote(target.rawValue)) \(shellQuote(file.path))\n".utf8)
    }

    public func isArmed(_ target: HookTarget) -> Bool {
        guard let data = try? Data(contentsOf: storage.appendingPathComponent("Policy.json")),
              let policy = try? JSONDecoder().decode([String: Bool].self, from: data) else { return false }
        return policy[target.rawValue] == true
    }

    private func setArmed(_ enabled: Bool, target: HookTarget) throws {
        let url = storage.appendingPathComponent("Policy.json")
        var policy: [String: Bool] = [:]
        if let data = try dataIfPresent(url) {
            guard let parsed = try? JSONDecoder().decode([String: Bool].self, from: data) else {
                if enabled { throw HookControlError.invalid("The account policy is invalid. Collection remains blocked.") }
                try write(try JSONEncoder().encode([target.rawValue: false]), to: url, permissions: 0o600)
                return
            }
            policy = parsed
        }
        policy[target.rawValue] = enabled
        try write(try JSONEncoder().encode(policy), to: url, permissions: 0o600)
    }

    /// Install automatic account guards once, including for currently personal accounts.
    /// Arming an automatic guard never authorizes a personal event. Each event still needs
    /// its own matching company identity. Later manual OFF choices survive app restarts.
    public func prepareProtection() throws {
        if competingInstallerPresent {
            for target in HookTarget.allCases { try setEnabled(false, for: target) }
            throw HookControlError.unavailable("The Neptune Hooks extension can overwrite account protection. Collection is off. Remove the extension from Cursor before enabling collection.")
        }
        let migration = storage.appendingPathComponent("AutomaticAccounts-v2.json")
        let migrate = !fm.fileExists(atPath: migration.path)
        for target in HookTarget.allCases {
            let state = status(target)
            if let issue = state.issue { throw HookControlError.invalid(issue) }
            if migrate && state.canEnable {
                try configure(true, for: target, requireCompanyAccount: false)
            } else if state.originalScripts > 0 {
                if state.armed { try configure(true, for: target, requireCompanyAccount: false) }
                else { try setEnabled(false, for: target) }
            }
        }
        if migrate { try write(Data("{\"version\":2}\n".utf8), to: migration, permissions: 0o600) }
    }

    /// Entry point for the tiny wrappers. It works even when the control window/app is closed.
    /// Only the original, locally saved script for a company-identified event can be executed.
    public func runGuardedHook(target: HookTarget, script: String, payload: Data, environment: [String: String]) -> Int32 {
        let neutral: () -> Int32 = {
            if target == .cursor {
                let response = ["beforeSubmitPrompt.sh", "sessionStart.sh"].contains(script) ? "{\"continue\":true}\n" : "{}\n"
                FileHandle.standardOutput.write(Data(response.utf8))
            }
            return 0
        }
        let activity = ActivityLog(storage: storage)
        let blocked: (BlockReason) -> Int32 = { reason in
            activity.record(target, .blocked(reason))
            return neutral()
        }
        let denial = { () -> BlockReason? in
            guard self.isArmed(target) else { return .collectionOff }
            return AccountPolicy.denial(target, payload: payload, environment: environment)
        }
        if let reason = denial() { return blocked(reason) }
        do {
            guard script == URL(fileURLWithPath: script).lastPathComponent, script.hasSuffix(".sh") else { return blocked(.integrity) }
            let snapshotData = try Data(contentsOf: storage.appendingPathComponent("Snapshots/\(target.rawValue).json"))
            let snapshot = try JSONDecoder().decode(HookSnapshot.self, from: snapshotData)
            try validate(snapshot, target: target)
            guard let record = snapshot.scripts.first(where: { $0.path == script }) else { return blocked(.integrity) }
            let path = try safeChild(script, in: originalsURL(target))
            try ensureNotSymlink(path)
            guard try Data(contentsOf: path) == record.bytes else { return blocked(.integrity) }
            // Recheck after all IO, immediately before granting the original script any input.
            if let reason = denial() { return blocked(reason) }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [path.path]
            task.environment = environment
            let pipe = Pipe()
            task.standardInput = pipe
            task.standardOutput = FileHandle.standardOutput
            task.standardError = FileHandle.nullDevice
            try task.run()
            pipe.fileHandleForWriting.write(payload)
            try pipe.fileHandleForWriting.close()
            task.waitUntilExit()
            activity.record(target, task.terminationStatus == 0 ? .sent : .failed)
            return task.terminationStatus
        } catch { return blocked(.integrity) }
    }

    private func disabledScript(for target: HookTarget, original: ScriptRecord) -> Data {
        var text = "#!/bin/bash\n# \(marker): collection disabled by Neptune Control.\n/bin/cat >/dev/null\n"
        if target == .cursor {
            let source = String(decoding: original.bytes, as: UTF8.self)
            let last = source.split(separator: "\n").last.map(String.init) ?? ""
            var response = "{}"
            if last.hasPrefix("printf '"), last.hasSuffix("\\n'") {
                let candidate = String(last.dropFirst(8).dropLast(3))
                if let bytes = candidate.data(using: .utf8), (try? JSONSerialization.jsonObject(with: bytes)) != nil { response = candidate }
            }
            let quoted = "'" + response.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            text += "/usr/bin/printf '%s\\n' \(quoted)\n"
        }
        text += "exit 0\n"
        return Data(text.utf8)
    }

    private func readScripts(_ root: URL) throws -> [ScriptRecord] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        try ensureNotSymlink(root)
        let canonicalRoot = root.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: canonicalRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]) else { throw HookControlError.invalid("Cannot read the Neptune scripts.") }
        var records: [ScriptRecord] = []
        var total = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw HookControlError.invalid("The Neptune folder contains a symbolic link. The update was stopped.") }
            guard values.isRegularFile == true else { continue }
            let canonicalFile = file.resolvingSymlinksInPath()
            guard canonicalFile.path.hasPrefix(canonicalRoot.path + "/") else { throw HookControlError.invalid("Unexpected script path.") }
            let relative = String(canonicalFile.path.dropFirst(canonicalRoot.path.count + 1))
            let attrs = try fm.attributesOfItem(atPath: file.path)
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            total += size
            guard total <= 20_000_000 else { throw HookControlError.invalid("The scripts folder is unexpectedly large. The update was stopped.") }
            records.append(ScriptRecord(path: relative, bytes: try Data(contentsOf: file), permissions: (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o700))
        }
        return records.sorted { $0.path < $1.path }
    }

    private func saveSnapshot(_ snapshot: HookSnapshot) throws {
        let path = storage.appendingPathComponent("Snapshots/\(snapshot.target.rawValue).json")
        try write(try JSONEncoder().encode(snapshot), to: path, permissions: 0o600)
    }

    private func makeBackup(target: HookTarget, config: Data?, scripts: [ScriptRecord]) throws -> URL {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + "-" + target.rawValue + "-" + UUID().uuidString.prefix(6)
        let root = backupsURL.appendingPathComponent(name)
        try createPrivateDirectory(root)
        if let config = config { try write(config, to: root.appendingPathComponent("configuration.json"), permissions: 0o600) }
        for file in scripts { try write(file.bytes, to: safeChild(file.path, in: root.appendingPathComponent("scripts")), permissions: 0o600) }
        return root
    }

    private func readConfiguration(_ url: URL) throws -> [String: Any] {
        try ensureNotSymlink(url)
        guard let data = try dataIfPresent(url) else { return [:] }
        do { return try decodeDictionary(data) }
        catch { throw HookControlError.invalid("\(url.lastPathComponent) is not valid JSON. The file was not changed.") }
    }

    private func decodeDictionary(_ data: Data) throws -> [String: Any] {
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HookControlError.invalid("Settings must be a JSON object.") }
        return dictionary
    }

    private func encodeDictionary(_ dictionary: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func writeConfiguration(_ config: [String: Any], to url: URL) throws {
        let permissions = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0o600
        var bytes = try encodeDictionary(config)
        bytes.append(0x0A)
        try write(bytes, to: url, permissions: permissions)
    }

    private func dataIfPresent(_ url: URL) throws -> Data? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func safeChild(_ relative: String, in root: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw HookControlError.invalid("The backup contains an invalid path.") }
        let child = root.appendingPathComponent(relative).standardizedFileURL
        guard child.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw HookControlError.invalid("The path is outside the scripts folder.") }
        return child
    }

    private func ensureNotSymlink(_ url: URL) throws {
        var cursor = url.standardizedFileURL
        while cursor.path != "/" {
            if let values = try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw HookControlError.invalid("The path contains a symbolic link. The update was stopped: \(cursor.lastPathComponent)")
            }
            // The selected home is the trust boundary. macOS system aliases above it
            // (notably /var -> /private/var for temporary test homes) are unrelated
            // to a redirected settings file or script inside that home.
            if cursor.standardizedFileURL == home.standardizedFileURL { break }
            cursor.deleteLastPathComponent()
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try ensureNotSymlink(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func write(_ data: Data, to url: URL, permissions: Int) throws {
        try ensureNotSymlink(url)
        try createPrivateDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
