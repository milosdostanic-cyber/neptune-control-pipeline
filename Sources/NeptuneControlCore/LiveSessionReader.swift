import Foundation
import Darwin

struct LiveClaudeSession {
    let email: String?
}

/// Reads identity metadata from local Claude Code processes. Arguments, prompts and tokens
/// are never returned, logged or persisted. This is a UI hint, never a hook authorization.
enum LiveSessionReader {
    static func claudeSessions(home: URL) -> [LiveClaudeSession] {
        processes().compactMap { process in
            let path = process.path
            let cliRoot = home.appendingPathComponent(".local/share/claude/versions").path + "/"
            let desktopRoot = home.appendingPathComponent("Library/Application Support/Claude").path + "/"
            let isClaude = path.hasPrefix(cliRoot) ||
                (path.hasSuffix("/claude") && (path.hasPrefix(desktopRoot) || path.contains("/Claude.app/")))
            guard isClaude else { return nil }
            let identity = environmentIdentity(pid: process.pid)
            let email = identity["CLAUDE_CODE_USER_EMAIL"]
            let verified = !(identity["CLAUDE_CODE_ACCOUNT_UUID"] ?? "").isEmpty && email?.contains("@") == true
            return LiveClaudeSession(email: verified ? email : nil)
        }
    }

    static func cursorIsRunning() -> Bool {
        processes().contains { $0.path.hasSuffix("/Cursor.app/Contents/MacOS/Cursor") }
    }

    static func claudeDesktopIsRunning() -> Bool {
        processes().contains { $0.path.hasSuffix("/Claude.app/Contents/MacOS/Claude") }
    }

    private static func processes() -> [(pid: pid_t, path: String)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard actual > 0 else { return [] }
        return pids.prefix(Int(actual)).compactMap { pid in
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let result = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            return result > 0 ? (pid, String(cString: path)) : nil
        }
    }

    private static func environmentIdentity(pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&mib, 3, nil, &length, nil, 0) == 0, length > 4, length <= 2_000_000 else { return [:] }
        var bytes = [UInt8](repeating: 0, count: length)
        let result = bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &length, nil, 0) }
        guard result == 0 else { return [:] }
        return identity(fromProcessArguments: Data(bytes.prefix(length)))
    }

    static func identity(fromProcessArguments data: Data) -> [String: String] {
        guard data.count >= 5 else { return [:] }
        let bytes = [UInt8](data)
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard argc > 0, argc < 100_000 else { return [:] }
        var index = 4
        func consume() -> String? {
            guard index < bytes.count, let end = bytes[index...].firstIndex(of: 0) else { return nil }
            let string = String(bytes: bytes[index..<end], encoding: .utf8)
            index = end + 1
            return string
        }
        guard consume() != nil else { return [:] } // Executable path.
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        for _ in 0..<argc { guard consume() != nil else { return [:] } }
        var identity: [String: String] = [:]
        while index < bytes.count, let entry = consume(), !entry.isEmpty {
            guard let split = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<split])
            if ["CLAUDE_CODE_USER_EMAIL", "CLAUDE_CODE_ACCOUNT_UUID"].contains(key) {
                identity[key] = String(entry[entry.index(after: split)...])
            }
        }
        return identity
    }
}
