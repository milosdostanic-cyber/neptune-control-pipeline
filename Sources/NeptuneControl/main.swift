import Foundation
import SwiftUI
import NeptuneControlCore

// The same installed binary acts as a short-lived, account-checking hook runner.
// This branch never initializes SwiftUI or opens a window.
let args = CommandLine.arguments
if args.count == 4, args[1] == "--run-hook", let target = HookTarget(rawValue: args[2]) {
    let home: URL
    if (Bundle.main.bundleIdentifier ?? "").hasSuffix(".preview"),
       let fixture = Bundle.main.object(forInfoDictionaryKey: "NeptuneControlFixtureHome") as? String {
        home = URL(fileURLWithPath: fixture)
    } else { home = FileManager.default.homeDirectoryForCurrentUser }
    let controller = HookController(home: home)
    let input = FileHandle.standardInput.readDataToEndOfFile()
    exit(controller.runGuardedHook(target: target, script: args[3], payload: input,
                                   environment: ProcessInfo.processInfo.environment))
} else if args == [args[0], "--status"] {
    let states = HookController().statuses().map { status -> [String: Any] in
        ["app": status.target.title, "connection": status.account.connection.label,
         "accounts": status.account.emails, "sessions": status.account.sessionCount,
         "unverifiedSessions": status.account.hasUnverifiedSessions,
         "collection": status.title, "automatic": status.armed,
         "registeredHooks": status.registeredHooks, "guardedScripts": status.protectedScripts]
    }
    if let data = try? JSONSerialization.data(withJSONObject: states, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
} else if args.count > 1 {
    // Unrecognized runner arguments cannot accidentally open a GUI or start collection.
    exit(0)
} else {
    NeptuneControlApp.main()
}
