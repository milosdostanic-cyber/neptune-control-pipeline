import SwiftUI
import AppKit
import WidgetKit
import NeptuneControlCore

private enum Palette {
    static let ink = Color.primary
    static let muted = Color.secondary
    static let background = Color(nsColor: .windowBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let blue = Color.accentColor
    static let safe = Color.secondary
    static let amber = Color.orange
}

@MainActor
final class ControlModel: ObservableObject {
    @Published var statuses: [HookStatus] = []
    @Published var busy = false
    @Published var message: String?
    @Published var error: String?
    @Published var updated = Date()
    let controller: HookController
    let preview: Bool
    let statsClient: NeptuneStatsClient?
    @Published var showStatsConnection = false
    @Published private var statsRevision = 0
    private var lastStatsUpdate: Date?
    var freshStats: NeptuneMonthlyStats? {
        guard let stats = statsClient?.stats, stats.isFresh(), stats.coversUsagePeriod() else { return nil }
        return stats
    }
    private var timer: Timer?
    private var lastWidgetApps: [WidgetAppStatus] = []
    private var lastWidgetWrite = Date.distantPast

    init() {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if bundleID.hasSuffix(".preview"), let path = Bundle.main.object(forInfoDictionaryKey: "NeptuneControlFixtureHome") as? String {
            preview = true
            let fixture = URL(fileURLWithPath: path)
            controller = HookController(home: fixture, identityProvider: { target in
                let data = try? Data(contentsOf: fixture.appendingPathComponent("preview-accounts.json"))
                let all = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String: Any]] }
                let account = all?[target.rawValue] ?? [:]
                return AccountIdentity(email: account["email"] as? String,
                                       connection: account["connected"] as? Bool == true ? .connected : .disconnected)
            })
        } else {
            preview = false
            controller = HookController()
        }
        statsClient = preview ? nil : NeptuneStatsClient()
        statsClient?.onChange = { [weak self] in
            self?.statsRevision += 1
            self?.refresh()
        }
        do { try controller.prepareProtection() }
        catch { self.error = error.localizedDescription }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.busy == false { self?.refresh() } }
        }
    }

    var enabledCount: Int { statuses.filter(\.enabled).count }
    var configuredCount: Int { statuses.filter(\.configured).count }
    var hasErrors: Bool { statuses.contains { $0.issue != nil } }

    func refresh() {
        if controller.competingInstallerPresent {
            do { try controller.prepareProtection() }
            catch { self.error = error.localizedDescription }
        }
        let fresh = controller.statuses()
        if statuses.map({ $0.account.email }) != fresh.map({ $0.account.email }) { message = nil }
        statuses = fresh
        updated = Date()
        publishWidgetStatus()
    }

    private func publishWidgetStatus() {
        guard !preview else { return }
        let apps = statuses.map(\.widgetStatus)
        let changed = apps != lastWidgetApps || freshStats?.updated != lastStatsUpdate
        guard changed || Date().timeIntervalSince(lastWidgetWrite) > 60 else { return }
        do {
            let url = WidgetSnapshot.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(WidgetSnapshot(apps: apps, stats: freshStats)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastWidgetApps = apps
            lastStatsUpdate = freshStats?.updated
            lastWidgetWrite = Date()
            if changed { WidgetCenter.shared.reloadTimelines(ofKind: "NeptuneStatus") }
        } catch { self.error = "Widget status could not be updated. \(error.localizedDescription)" }
    }

    func setEnabled(_ enabled: Bool, target: HookTarget) {
        guard !busy else { return }
        busy = true
        error = nil
        message = nil
        Task { @MainActor in
            await Task.yield()
            do {
                try controller.setEnabled(enabled, for: target)
                message = nil
            } catch { self.error = error.localizedDescription }
            refresh()
            busy = false
        }
    }

    func disableAll() {
        guard !busy else { return }
        busy = true
        error = nil
        message = nil
        Task { @MainActor in
            await Task.yield()
            var failed: [String] = []
            for target in HookTarget.allCases {
                do { try controller.setEnabled(false, for: target) }
                catch { failed.append("\(target.title): \(error.localizedDescription)") }
            }
            refresh()
            if failed.isEmpty { message = "Collection is off in both apps." }
            else { error = failed.joined(separator: "\n") }
            busy = false
        }
    }

    func openBackups() {
        let path = controller.backupsURL
        if FileManager.default.fileExists(atPath: path.path) {
            NSWorkspace.shared.open(path)
        } else {
            message = "A backup is created when settings change."
        }
    }
}

struct NeptuneControlApp: App {
    @StateObject private var model = ControlModel()

    var body: some Scene {
        Window("Neptune Control", id: "control") {
            ControlView(model: model)
                .environment(\.locale, Locale(identifier: "en_US"))
                .onOpenURL { url in
                    guard url.scheme == "neptune-control", ["control", "stats"].contains(url.host ?? "") else { return }
                    if url.host == "stats" {
                        NSWorkspace.shared.open(URL(string: "https://app.neptune.spaceinch.tech/stats")!)
                        return
                    }
                    model.refresh()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 380, height: 340)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Button("Refresh status") { model.refresh() }.keyboardShortcut("r", modifiers: .command)
            }
        }
        MenuBarExtra {
            MenuControls(model: model)
        } label: {
            NeptuneLogo().frame(width: 14, height: 17)
                .accessibilityLabel("Neptune Control")
        }
    }
}

private struct ControlView: View {
    @ObservedObject var model: ControlModel
    @State private var showingInfo = false
    @State private var showingWidgetGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                NeptuneLogo().frame(width: 22, height: 26).accessibilityHidden(true)
                Text("Neptune").font(.system(size: 21, weight: .semibold))
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { showingWidgetGuide = true } label: {
                    Label("Add widget", systemImage: "square.grid.2x2")
                }.buttonStyle(.borderless).font(.system(size: 11))
                Menu {
                    Button("Refresh") { model.refresh(); model.statsClient?.refresh() }
                    Button("Connect Neptune account…") { model.showStatsConnection = true }
                    Divider()
                    Button("Turn off all") { model.disableAll() }
                    Button("Backups…") { model.openBackups() }
                    Button("About account protection…") { showingInfo = true }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 18)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More options")
            }
            VStack(spacing: 0) {
                ForEach(Array(model.statuses.enumerated()), id: \.element.id) { index, status in
                    if index > 0 { Divider().padding(.leading, 58) }
                    TargetCard(status: status, stats: model.freshStats?.app(status.target.rawValue), busy: model.busy) { model.setEnabled($0, target: status.target) }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.opacity(0.45)))

            UsagePanel(model: model)

            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = model.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 7) {
                Label("Spaceinch accounts only", systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { NSWorkspace.shared.open(URL(string: "https://app.neptune.spaceinch.tech/stats")!) } label: {
                    Label("My stats", systemImage: "arrow.up.right")
                }.buttonStyle(.link).font(.system(size: 11)).help("Open my Neptune statistics in your browser")
            }
        }
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 18)
        .frame(width: 540)
        .background(Palette.background)
        .sheet(isPresented: $showingWidgetGuide) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Add Neptune widget", systemImage: "square.grid.2x2").font(.headline)
                Text("The widget is included with Neptune Control.")
                Text("1. Right-click your desktop and choose Edit Widgets.\n\n2. Search for Neptune Control.\n\n3. Choose a size and drag it onto your desktop or into Notification Center.")
                Text("The widget shows your app connections. View usage in Neptune Control or choose My stats to open Neptune in your browser.").foregroundStyle(.secondary)
                Button("Done") { showingWidgetGuide = false }.keyboardShortcut(.defaultAction)
            }.font(.system(size: 13)).padding(24).frame(width: 350)
        }
        .sheet(isPresented: $model.showStatsConnection) {
            if let client = model.statsClient { NeptuneStatsConnectionView(client: client) }
        }
        .sheet(isPresented: $showingInfo) {
            VStack(alignment: .leading, spacing: 16) {
                Label("Account protection", systemImage: "lock.shield").font(.headline)
                Text("Stats and the widget work after you connect your own SpaceInch Neptune account. Collection controls require the existing Neptune hooks installed on this Mac.")
                Text("Personal and unverified sessions are blocked. Each session is checked before data can be sent, even when Neptune Control is closed.")
                Text("The desktop widget shows the last checked status. Open Neptune Control for current accounts and collection controls.")
                Button("Done") { showingInfo = false }.keyboardShortcut(.defaultAction)
            }.font(.system(size: 13)).padding(24).frame(width: 340)
        }
    }
}

private struct UsagePanel: View {
    @ObservedObject var model: ControlModel

    private var periodLabel: String {
        let range = NeptuneMonthlyStats.usageRange()
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX"); input.dateFormat = "yyyy-MM-dd"
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US"); output.dateFormat = "MMM d"
        guard let first = input.date(from: range.start), let last = input.date(from: range.end) else { return "Last 30 days" }
        return "Last 30 days · \(output.string(from: first)) – \(output.string(from: last))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token usage").font(.system(size: 16, weight: .semibold))
                    Text(periodLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.statsClient?.loading == true {
                    ProgressView().controlSize(.small).accessibilityLabel("Refreshing usage")
                } else {
                    Button { model.statsClient?.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Refresh usage").accessibilityLabel("Refresh usage")
                }
            }
            if let stats = model.freshStats {
                let peak = max(stats.apps.map(\.tokens).max() ?? 0, 1)
                VStack(spacing: 18) {
                    ForEach(HookTarget.allCases, id: \.rawValue) { target in
                        if let app = stats.app(target.rawValue) {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(target.title).font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(app.tokenLabel).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                                }
                                GeometryReader { proxy in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.06))
                                        Capsule().fill(target == .claudeCode ? Color(red: 0.82, green: 0.48, blue: 0.36) : Color(red: 0.24, green: 0.62, blue: 0.75))
                                            .frame(width: proxy.size.width * CGFloat(app.tokens) / CGFloat(peak))
                                    }
                                }.frame(height: 10)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(target.title), \(app.tokens.formatted()) tokens in the last 30 days")
                            .help("\(app.tokens.formatted()) tokens · \(app.sessions) sessions recorded in Neptune")
                        }
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    if let email = model.statsClient?.accountEmail {
                        Text(email).lineLimit(1).truncationMode(.middle)
                    } else { Text("From Neptune") }
                    Spacer(minLength: 8)
                    Text("Input, output & cache")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.statsClient?.loading == true ? "Loading your Neptune usage…" : "Connect Neptune to see your usage.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if model.statsClient?.loading != true {
                        Button("Connect Neptune") { model.showStatsConnection = true }.controlSize(.small)
                    }
                }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line.opacity(0.45)))
    }
}

private struct TargetCard: View {
    let status: HookStatus
    let stats: NeptuneSourceStats?
    let busy: Bool
    let change: (Bool) -> Void

    private var stateColor: Color { status.widgetStatus.needsAttention ? .orange : (status.enabled ? .accentColor : .secondary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AppIcon(target: status.target).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.target.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        if status.enabled { ActiveDot() }
                        Text(status.enabled && stats != nil ? "Synced with Neptune" : status.compactState).font(.system(size: 11, weight: .medium)).foregroundStyle(status.enabled ? .green : stateColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Toggle("Collection in \(status.target.title)", isOn: Binding(get: { status.armed && status.account.isSpaceInch }, set: change))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(busy || status.issue != nil || !status.account.isSpaceInch || (!status.enabled && !status.canEnable))
                    .help("Allow collection for verified SpaceInch sessions")
            }
            if let issue = status.issue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(status.account.emails, id: \.self) { email in
                    HStack(spacing: 5) {
                        if !AccountPolicy.isAllowed(email) { Image(systemName: "lock.fill") }
                        Text(email).lineLimit(1).truncationMode(.middle).help(email)
                        if !AccountPolicy.isAllowed(email) { Text("· blocked") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.leading, 46)
                }
                if !status.account.isSpaceInch && status.armed {
                    Button("Turn off for work accounts too") { change(false) }
                        .font(.system(size: 10)).buttonStyle(.link).padding(.leading, 46).disabled(busy)
                }
            }
        }.padding(14)
    }
}

private struct AppIcon: View {
    let target: HookTarget
    var body: some View {
        let name = target == .claudeCode ? "Claude" : "Cursor"
        if let url = Bundle.main.url(forResource: name, withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            Image(nsImage: icon).resizable().interpolation(.high).accessibilityHidden(true)
        } else {
            Image(systemName: "app").resizable().accessibilityHidden(true)
        }
    }
}

private struct ActiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6)).foregroundStyle(.green)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
            .accessibilityHidden(true)
    }
}

private struct NeptuneLogo: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "NeptuneLogo", withExtension: "png"), let logo = NSImage(contentsOf: url) {
            Image(nsImage: logo).resizable().scaledToFit()
        }
    }
}

private struct MenuControls: View {
    @ObservedObject var model: ControlModel
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Text("Neptune Control")
        ForEach(model.statuses) { status in
            Toggle(status.target.title, isOn: Binding(get: { status.armed && status.account.isSpaceInch }, set: { model.setEnabled($0, target: status.target) }))
                .disabled(model.busy || status.issue != nil || !status.account.isSpaceInch || (!status.enabled && !status.canEnable))
        }
        Divider()
        Button("Turn off all") { model.disableAll() }.disabled(model.busy || model.configuredCount == 0)
        Button("Open Neptune Control") {
            openWindow(id: "control")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("Refresh status") { model.refresh() }
        Link("My stats ↗", destination: URL(string: "https://app.neptune.spaceinch.tech/stats")!)
        Divider()
        Button("Quit Neptune Control") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
