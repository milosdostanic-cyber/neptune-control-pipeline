import SwiftUI
import WebKit
import OSLog
import NeptuneControlCore

@MainActor
final class NeptuneStatsClient: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    @Published var stats: NeptuneMonthlyStats?
    @Published var connection = "Connect stats"
    @Published var loading = false
    @Published var accountEmail: String?
    let webView: WKWebView
    private var refreshTimer: Timer?
    private var requestTimeout: Task<Void, Never>?
    private let cacheURL: URL
    var onChange: (() -> Void)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 680), configuration: configuration)
        cacheURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Neptune Control/MonthlyStats.json")
        super.init()
        if let data = try? Data(contentsOf: cacheURL), let cached = try? JSONDecoder().decode(NeptuneMonthlyStats.self, from: data), cached.isValid {
            stats = cached
        }
        webView.configuration.userContentController.add(self, name: "neptuneStats")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !loading else { return }
        guard let url = Bundle.main.url(forResource: "StatsBridge", withExtension: "js"), let script = try? String(contentsOf: url) else {
            connection = "Stats unavailable"; return
        }
        let content = webView.configuration.userContentController
        content.removeAllUserScripts()
        let range = NeptuneMonthlyStats.usageRange()
        let source = script.replacingOccurrences(of: "__NEPTUNE_MONTH__", with: range.month)
            .replacingOccurrences(of: "__NEPTUNE_START__", with: range.start)
            .replacingOccurrences(of: "__NEPTUNE_END__", with: range.end)
        content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        loading = true
        requestTimeout?.cancel()
        requestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.loading else { return }
            self.loading = false; self.connection = "Stats unavailable"; self.onChange?()
        }
        webView.load(URLRequest(url: URL(string: "https://app.neptune.spaceinch.tech/stats?date_from=\(range.start)&date_to=\(range.end)")!))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "app.neptune.spaceinch.tech",
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        Logger(subsystem: "local.milos.neptune-control", category: "stats").info("Stats response: \(kind, privacy: .public)")
        switch kind {
        case "stats":
            guard let month = body["month"] as? String, month == NeptuneMonthlyStats.dateRange().month,
                  let apps = body["apps"] as? [[String: Any]],
                  body["periodStart"] as? String == NeptuneMonthlyStats.usageRange().start,
                  body["periodEnd"] as? String == NeptuneMonthlyStats.usageRange().end else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: apps)
                let rows = try JSONDecoder().decode([NeptuneSourceStats].self, from: data)
                let fresh = NeptuneMonthlyStats(month: month, apps: rows, periodStart: body["periodStart"] as? String, periodEnd: body["periodEnd"] as? String)
                guard fresh.isValid else { return }
                stats = fresh
                connection = "Synced with Neptune"
                loading = false
                try JSONEncoder().encode(fresh).write(to: cacheURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            } catch { connection = "Stats unavailable" }
        case "connected":
            connection = "Loading usage…"
            if let email = body["email"] as? String, AccountPolicy.isAllowed(email) { accountEmail = email }
        case "signIn": accountEmail = nil; stats = nil; connection = "Connect stats"; loading = false; try? FileManager.default.removeItem(at: cacheURL)
        case "wrongAccount": accountEmail = nil; stats = nil; connection = "Use your SpaceInch account"; loading = false; try? FileManager.default.removeItem(at: cacheURL)
        case "unavailable":
            connection = "Stats unavailable"; loading = false
            if let reason = body["reason"] as? String, ["auth", "unavailable", "format", "changed", "duplicate", "overflow", "cursor", "incomplete"].contains(reason) {
                Logger(subsystem: "local.milos.neptune-control", category: "stats").info("Stats failure: \(reason, privacy: .public)")
            }
        case "loading": break
        default: return
        }
        if !loading { requestTimeout?.cancel() }
        onChange?()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.path.contains("sign-in") == true { loading = false; requestTimeout?.cancel(); accountEmail = nil; connection = "Connect stats"; stats = nil; try? FileManager.default.removeItem(at: cacheURL); onChange?() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false; connection = "Stats unavailable"; onChange?()
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}

struct NeptuneStatsBrowser: NSViewRepresentable {
    let client: NeptuneStatsClient
    func makeNSView(context: Context) -> WKWebView { client.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct NeptuneStatsConnectionView: View {
    @ObservedObject var client: NeptuneStatsClient
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Neptune stats").font(.headline)
                Text(client.connection).font(.system(size: 12)).foregroundStyle(.secondary)
                if client.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Refresh") { client.refresh() }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            NeptuneStatsBrowser(client: client)
        }.frame(width: 900, height: 680)
    }
}
